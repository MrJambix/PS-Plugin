-- Jambix AIO / react / rules / hunter -- what only a hunter reacts with.
--
-- A Classic Era hunter has no interrupt (Silencing Shot is TBC) and half its
-- defence is the pet, so the generic reactions leave two gaps:
--
--   * A dangerous cast -- a heal, a fear, a big bolt -- can still be stopped
--     with crowd control: Scatter Shot disorients the caster, and the pet's
--     Intimidation stuns whatever the pet is hitting. Both break a cast. They
--     share the interrupt's event key, so a cast is answered once, by
--     whichever goes out first.
--
--   * A pet about to die is not only a heal problem. Intimidation stops the
--     mob hitting it for three seconds and hands the pet the threat back --
--     the time a Mend Pet needs to catch up.
--
--   * Cheetah dazes you when you are hit, and Pack dazes every party member
--     who is. Before a hit lands, the switch is moved out of it -- not by
--     casting an aspect here (the Aspects window owns them, 1.49.0) but by an
--     "aspect" action the engine hands to the window's module.
--
--   * The pet's mob turned on you, and Growl cannot bring it back (1.68.0):
--     not ready within a second, or it went out at that mob and the mob
--     stayed on you. Intimidation stuns it and hands the pet a large amount
--     of threat. Only for the mob the pet is on, within the pet's reach.
--
--   * An add hitting you in melee that is not the target (1.58.0). Shots
--     cannot land on it -- it is inside the dead zone -- and every swing it
--     takes is one the pet should be taking. When the pet is not going to
--     take it (no pet, the pet low, or the mob the pet holds would turn on
--     you: the plan says so), Wing Clip it; the kite then walks you out of
--     its reach while the shots stay on the target.
--
--   * The AOE melee weave (1.7.6, ALPHA/TEST): out of melee, once the
--     target carries its Serpent Sting, the target moves on to the next mob
--     fighting you or your pet whose sting is missing or running out, so the
--     rotation renews them all (classes/hunter.lua, the aoe_weave profile).
--
-- Hunter's Mark is one per hunter: marking a second mob takes it off the
-- first. It is registered as a one-per-caster debuff, which is what lets the
-- memory hold it while the target is flapping between two mobs.

return function(R, P, lib)
    local book = P.spellbook
    local detect = lib.detect
    local floor, min = math.floor, math.min

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    R.unique("Hunter's Mark")

    local function H() return (P.rotation and P.rotation.helpers) or {} end
    -- Our slows and roots, any of which keeps a mob from following.
    local HELD = { "Wing Clip", "Improved Wing Clip", "Concussive Shot", "Entrapment", "Frost Trap Aura" }
    local function held(unit)
        local h = H()
        if not h.debuff_up then return false end
        for i = 1, #HELD do
            if h.debuff_up(unit, HELD[i]) then return true end
        end
        return false
    end

    R.add_rule({
        name = "Clip the add",
        category = "cc", priority = 72,
        needs = { "combat" },
        every = 0.2,
        retry = { hold = 3 },
        propose = function(W, offer)
            if not (book.known("Wing Clip") and book.ready("Wing Clip")) then return end
            local plan = W.plan
            local list, n = W.enemies.list or {}, W.enemies.count or 0
            for i = 1, n do
                local r = list[i]
                local h = H()
                local close = r and r.obj and ((h.in_melee and h.in_melee(r.obj, r.dist)) or (r.dist or 99) <= 5)
                if close and r.engaged and r.targeting_me
                    and r.guid ~= W.target.guid and not r.control and not held(r.obj) then
                    -- The pet is about to take it: let it.
                    if plan and plan.live and plan.pet_add and plan.pet_add.guid == r.guid and plan.pet_ok then
                        return
                    end
                    local c = offer({
                        name = "Wing Clip", target = r.obj, target_kind = "enemy",
                        event_key = "clip_add:" .. tostring(r.guid), handled_for = 8,
                        why = P.units.name and P.units.name(r.obj) or "the add",
                    })
                    c.pet_why = plan and plan.live and plan.pet_add and plan.pet_add.guid == r.guid
                        and plan.pet_why or nil
                    return
                end
            end
        end,
        score = function(W, c)
            c:add(4, "in the dead zone, not the target: it cannot be shot")
            if c.pet_why then c:add(2, "the pet stays: " .. c.pet_why) end
            if W.player.hp < 0.6 then c:add(6, string.format("you are at %d%%", floor(W.player.hp * 100 + 0.5))) end
        end,
    })

    local CONTROL = { "Scatter Shot", "Intimidation" }

    R.add_rule({
        name = "Stop the cast with crowd control",
        category = "interrupt", priority = 86,
        needs = { "casting", "combat" },
        wake = { "jcore.enemy.casting" },
        propose = function(W, offer)
            local function consider(cast, unit, guid, current)
                if not unit or cast.remaining <= 0.15 then return end
                if cast.danger < detect.DANGEROUS then return end
                local key = lib.cast_key(guid, cast)
                for i = 1, #CONTROL do
                    local name = CONTROL[i]
                    if book.known(name) and book.ready(name) then
                        -- Intimidation is cast on ourselves and lands on what the
                        -- PET is hitting: only for the mob the pet is on.
                        local on_pet = W.pet.alive and W.pet.target_guid == guid
                        if name == "Scatter Shot" or on_pet then
                            local c = offer({
                                name = name,
                                target = name == "Intimidation" and W.player.unit or unit,
                                target_kind = name == "Intimidation" and "self" or "enemy",
                                event_key = key, handled_for = cast.remaining + 0.5, why = cast.name,
                                offensive = not cast.at_me,
                            })
                            c.cast, c.current = cast, current
                            return
                        end
                    end
                end
            end

            local tg = W.target
            if tg.casting and tg.unit and tg.cast.interruptible ~= false and not tg.others_fight then
                tg.cast.at_me = tg.targets_me
                consider(tg.cast, tg.unit, tg.guid, true)
            end
            -- An enemy healer's heal too, in a PvP hunter's fight (1.7.6):
            -- "Scatter interrupts casts too" (the Classic guides), and a heal
            -- on its friend is not a cast at us.
            local ph = P.pvphunter
            local pvp_on = ph ~= nil and ph.mode ~= nil and ph.mode() == true
            local en = W.enemies
            for i = 1, en.casting_n do
                local cast = en.casting[i]
                if not cast.current and (cast.engaged or (pvp_on and cast.player and cast.kind == "heal")) then
                    consider(cast, cast.unit, cast.guid, false)
                end
            end
        end,
        score = function(W, c)
            local cast = c.cast
            c:add(cast.danger, string.format("dangerous cast (%s)", cast.name ~= "" and cast.name or "?"))
            if cast.remaining <= 1.0 then
                c:add(25, string.format("cast ends in %.1fs", cast.remaining))
            elseif cast.remaining <= 2.0 then
                c:add(12, string.format("cast ends in %.1fs", cast.remaining))
            end
            if cast.at_me then c:add(8, "aimed at you") end
            -- Spending a thirty-second control on a cast is worth it; on a
            -- cast a real interrupt could have taken, less so.
            c:add(-6, "crowd control used as an interrupt")
        end,
    })

    R.add_rule({
        name = "Intimidation: save the pet",
        category = "pet", priority = 74, target = "self",
        needs = { "pet", "combat", "target" },
        retry = { hold = 3 },
        propose = function(W, offer)
            local pet = W.pet
            if not (W.sit.pet_critical or (W.sit.pet_low and pet.hp_rate < -0.05)) then return end
            if pet.target_guid == nil or pet.target_guid ~= W.target.guid then return end
            if not W.target.targets_pet then return end
            if not (book.known("Intimidation") and book.ready("Intimidation")) then return end
            offer({ name = "Intimidation", why = string.format("pet at %d%%", floor(pet.hp * 100 + 0.5)),
                    event_key = "save_pet:" .. tostring(pet.guid), handled_for = 4 })
        end,
        score = function(W, c)
            local pet = W.pet
            c:add(min(20, (W.thresholds.pet_heal_hp - pet.hp) * 100), "the pet is the tank and it is dying")
            if pet.hp_rate < -0.05 then c:add(8, string.format("pet falling %.0f%%/s", -pet.hp_rate * 100)) end
        end,
    })

    R.add_rule({
        name = "Intimidation: give the pet its mob back",
        category = "threat", priority = 73, target = "self",
        needs = { "pet", "combat" },
        every = 0.2,
        retry = { hold = 3 },
        propose = function(W, offer)
            if not (book.known("Intimidation") and book.ready("Intimidation")) then return end
            local S = W.petthreat
            if not S or not S.live then return end
            local e = nil
            for i = 1, #S.list do
                if S.list[i].held then e = S.list[i] break end
            end
            if not e or e.reach ~= true then return end
            if e.kind ~= "on you" and not (e.kind == "turning" and (e.threat or 0) >= 95) then return end
            -- Growl first, when it is about to be ready: unless it already went
            -- out at this mob and the mob stayed on you.
            local last = S.last
            local growled = last ~= nil and last.guid == e.guid and (W.now - last.at) >= 1.0 and (W.now - last.at) <= 4.0
            local growl_soon = S.name ~= nil and not S.short and (S.ready_in or 0) <= 1.0
            if growl_soon and not growled then return end
            local c = offer({
                name = "Intimidation", event_key = "pet_back:" .. tostring(e.guid), handled_for = 8,
                why = (P.units.name and P.units.name(e.obj)) or "the pet's mob",
            })
            c.e, c.growled = e, growled
        end,
        score = function(W, c)
            local e = c.e
            if e.kind == "on you" then
                c:add(10, "it left the pet for you")
            else
                c:add(6, string.format("your threat %d%%: it is about to leave the pet", floor(e.threat or 0)))
            end
            if c.growled then c:add(6, "a Growl did not bring it back") end
            if W.player.hp < 0.5 then c:add(6, string.format("you are at %d%%", floor(W.player.hp * 100 + 0.5))) end
        end,
    })

    -- OUT OF CHEETAH BEFORE THE HIT (1.50.0). What counts as a hit about to
    -- land is aspects.lua's M.incoming, read from the rows this world already
    -- carries: a mob on you in melee or reaching you before a swap could, a
    -- cast at you, a missile in flight at you, a mob attacking from where it
    -- stands; in Pack, a mob on a party member too. A mob you are outrunning
    -- is not one. The swap goes to the aspect you last fought in (Hawk, else
    -- Monkey). Out of combat as well: the mob that just turned on you is the
    -- one that dazes you. Only with Auto swap aspects on (1.7.6): off, no
    -- aspect is swapped for you at all.
    R.add_rule({
        name = "Out of Cheetah before the hit",
        category = "defensive", priority = 84, kind = "aspect", target = "self",
        band = (P.ctx and P.ctx.PRIORITY and P.ctx.PRIORITY.DEFENSIVE) or 200,
        retry = { hold = 1 },
        propose = function(W, offer)
            local A = P.aspects
            if not (A and A.incoming and A.travel_up and A.fight_aspect) then return end
            if not (A.auto_swap_on and A.auto_swap_on()) then return end
            -- The keeper's own guard stands aside while this is asked.
            if A.react_watching then A.react_watching() end
            local travel = A.travel_up()
            if not travel then return end
            local eta, why = A.incoming(travel, W.enemies.list, W.enemies.count, W.player.gcd)
            if not eta then return end
            local to = A.fight_aspect()
            if not to then return end
            local c = offer({ name = to, why = why, event_key = "daze:" .. travel, handled_for = 1.5 })
            c.eta, c.travel = eta, travel
        end,
        score = function(W, c)
            c:add(math.max(0, 12 - (c.eta or 0) * 8), string.format("the hit lands in %.1fs", c.eta or 0))
            if W.player.hp < 0.5 then c:add(6, "and you are hurt") end
        end,
    })

    -- THE AOE MELEE WEAVE'S STINGS (1.7.6, ALPHA/TEST). The user: "renew as
    -- many Serpent stings on Multiple target in combat with US!!! it can Swap
    -- through target automatically Aslong as its in combat with us and Renew
    -- while we mvoe back in". The rotation stings the target; this moves the
    -- target on once the sting is up there. Only out of melee (the way out
    -- and the way back in), only a mob fighting you or your pet, in a shot's
    -- reach and outside the dead zone, not held by control that damage
    -- breaks, and with time to live for the sting. The one with the least
    -- sting left goes first, the nearest of equals.
    local STING = "Serpent Sting"
    local RENEW_AT = 2              -- seconds of sting left: renewed (H.dot_worth_it's line)
    local STING_REACH = 35          -- yards
    local MIN_RANGE = 8             -- the dead zone, edge to edge
    local STING_LIVES = 8           -- seconds a mob has to live for a sting (the fillers' line)
    local STING_MANA = 0.15         -- under this the rotation stings nothing

    local function aoe_weave_running()
        local class_module = P.rotation and P.rotation.active_class and P.rotation.active_class()
        local fn = class_module and class_module.aoe_running
        return type(fn) == "function" and fn() == true
    end

    local function sting_left(h, unit)
        local ok, left = pcall(h.debuff_remaining, unit, STING)
        return ok and type(left) == "number" and left or 0
    end

    R.add_rule({
        name = "AOE weave: sting the next mob",
        category = "utility", priority = 64, kind = "set_target", lane = "fast",
        needs = { "combat", "target" },
        every = 0.25,
        retry = { hold = 1.5 },
        propose = function(W, offer)
            if not aoe_weave_running() then return end
            if not (book.known(STING) and book.ready(STING)) then return end
            if (W.player.power_pct or 0) < STING_MANA then return end
            local h = H()
            local tg = W.target
            if not (tg.unit and h.debuff_remaining) then return end
            -- In melee it is the burst's turn.
            if h.in_melee and h.in_melee(tg.unit, tg.distance) then return end
            -- The target's own sting first: the rotation puts it there.
            if sting_left(h, tg.unit) <= RENEW_AT then return end

            local list, n = W.enemies.list or {}, W.enemies.count or 0
            local best, best_left = nil, math.huge
            for i = 1, n do
                local r = list[i]
                if r and r.obj and r.guid ~= tg.guid and not r.dead and (r.hp or 1) > 0
                    and (r.engaged or r.targeting_me or r.targeting_pet)
                    and not (r.control and r.control.breaks)
                    and (r.dist or math.huge) <= STING_REACH
                    and not (P.react and P.react.out_of_fight and P.react.out_of_fight(r.obj) == true) then
                    local edge = h.gap and h.gap(r.obj, r.dist) or r.dist
                    local left = sting_left(h, r.obj)
                    if (edge or 0) > MIN_RANGE and left <= RENEW_AT then
                        local ttd = P.combat and P.combat.time_to_die and P.combat.time_to_die(r.obj) or nil
                        local lives = type(ttd) ~= "number" or ttd <= 0 or ttd >= STING_LIVES
                        if lives and (left < best_left
                            or (left == best_left and (r.dist or math.huge) < (best.dist or math.huge))) then
                            best, best_left = r, left
                        end
                    end
                end
            end
            if not best then return end
            local who = (P.units and P.units.name and P.units.name(best.obj)) or "the next mob"
            local c = offer({
                name = "Target " .. who, kind = "set_target", target = best.obj, target_kind = "enemy",
                event_key = "aoe_sting:" .. tostring(best.guid), handled_for = 3,
                why = best_left > 0 and string.format("%s: its sting runs out in %.0fs", who, best_left)
                    or (who .. " has no sting"),
            })
            c.who = who
        end,
        score = function(W, c) c:add(6, c.why or "the next mob for a sting") end,
    })
end

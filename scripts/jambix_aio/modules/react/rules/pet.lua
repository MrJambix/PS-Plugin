-- Jambix AIO / react / rules / pet -- the pet's own skills: when, and on what.
--
-- WHAT IS LEFT TO THE PET (1.71.0)
-- Claw, Bite, Screech, Lightning Breath, Scorpid Poison, Firebolt, Lash of
-- Pain: damage on cooldown is what they are for, and the pet's autocast spends
-- them that way already. Prowl stays as you set it. Growl and Torment are the
-- taunt's (react/petthreat.lua, "Pet: taunt" in rules/core.lua).
--
-- WHAT THE ENGINE PRESSES, everything else a pet knows. Each is taken off
-- autocast while the engine runs (modules/pet.lua, M.aim: once per pet, not
-- on the client's word, and given back when the engine stops) and pressed
-- only when it changes something. The numbers are the client's spell tables
-- (modules/beasts_data.lua):
--
--   Furious Howl   60 focus, a 10 s buff on the next attack of every party
--                  member within 15 yd of the wolf. Autocast spent it every
--                  10 s with nobody near. Two or more of you in reach (you
--                  count; so does each party member).
--   Dash, Dive     a 15 s sprint, 30 s cooldown: the pet's mob is 15 yd or
--                  more from it (an add on you, a pull from range).
--   Charge         the boar's, 8 to 25 yd: on the way to its mob.
--   Thunderstomp   60 focus, 60 s, everything within 8 yd of the gorilla:
--                  two or more there, or a mob on you beside it (the threat
--                  takes it off you).
--   Shell Shield   half the damage for 12 s, 3 min: the turtle is tanking
--                  and losing health fast, or three are on it.
--   Cower          sheds the pet's threat: only in a group with a tank, when
--                  the pet is about to pull its mob (90% of the client's
--                  percent) or already has.
--   Sacrifice      the Voidwalker's shield for you, at the cost of the
--                  Voidwalker: you are about to die.
--   Seduction      a humanoid add on you that is not your target. One answer
--                  per add with the class's own crowd control (the same event).
--   Consume Shadows  out of combat, the Voidwalker hurt: it heals itself.
--
-- FOCUS: a skill that costs focus keeps 15 back for Growl while the pet is
-- the tank and Growl is aimed and coming ready. Where the client does not say
-- what the pet has, nothing is held back -- the client refuses a short press.

return function(R, P, lib)
    local units = P.units
    local book = P.spellbook
    local petthreat = lib.petthreat
    local floor, min, huge = math.floor, math.min, math.huge
    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    local function pets() return P.pet end

    -- Why a held skill waits, for the log (react/init.lua, every 20 s of a
    -- fight; 1.73.1).
    local function note(name, text)
        if petthreat and petthreat.note then petthreat.note(name, text) end
    end

    local function knows(name)
        local p = pets()
        return p ~= nil and p.knows ~= nil and p.knows(name) == true
    end

    local function skill(name)
        local p = pets()
        return p and p.skill and p.skill(name) or nil
    end

    local function ready(name)
        local p = pets()
        return not (p and p.ready_in) or (p.ready_in(name) or 0) <= 0
    end

    --- Growl's 15 kept back while the pet is the tank and Growl is coming.
    local function reserve(W)
        local S = W.petthreat
        if not (S and S.live and S.name == "Growl" and S.mode == "solo") then return 0 end
        local p = pets()
        if not (p and p.taunt_aimed and p.taunt_aimed()) then return 0 end
        if (S.ready_in or 0) > 3 then return 0 end
        return 15
    end

    --- Can the pet pay for it now? nil, or why not.
    local function short_of(W, name)
        local s = skill(name)
        if not s or s.power ~= "focus" then return nil end
        local p = pets()
        local current = p and p.focus_power and p.focus_power() or nil
        if not current then return nil end
        local need = (s.cost or 0) + reserve(W)
        if current >= need then return nil end
        return string.format("the pet has %d focus, %s needs %d%s", floor(current), name, need,
            need > (s.cost or 0) and " (15 kept for Growl)" or "")
    end

    --- Takes the skill off autocast for this pass (the engine's lease). false
    --- when it will not stay off here: then autocast has it, as before.
    local function own(name, restore)
        local p = pets()
        return p ~= nil and p.aim ~= nil and p.aim(name, restore) == true
    end

    --- The managed pet modes: not Off, not Focus.
    local function managed(W)
        local p = pets()
        local mode = W.pet.mode
        return not (p and mode and (mode == p.OFF or mode == p.FOCUS))
    end

    --- Where the pet's own target stands from the pet: its row, the centre
    --- distance, and the gap between the two hitboxes (spell range is
    --- measured hitbox to hitbox).
    local function pet_target_from_pet(W)
        local pet = W.pet
        if not pet.target or not pet.target_guid then return nil end
        local row = nil
        local list, n = W.enemies.list or {}, W.enemies.count or 0
        for i = 1, n do
            if list[i] and list[i].guid == pet.target_guid then row = list[i] break end
        end
        local d = nil
        if row and petthreat and petthreat.from_pet then
            local _, dd = petthreat.from_pet(row)
            d = dd
        end
        if not d and units.distance_between then
            local ok, v = pcall(units.distance_between, pet.unit, pet.target)
            if ok and type(v) == "number" and v < huge then d = v end
        end
        if not d then return row, nil, nil end
        local function reach(u)
            local r = units.combat_reach and units.combat_reach(u) or nil
            return (type(r) == "number" and r > 0) and r or 1.5
        end
        return row, d, d - reach(pet.unit) - reach(pet.target)
    end

    local function offer_skill(offer, W, name, target, kind, why)
        local short = short_of(W, name)
        local c = offer({ name = name, kind = "pet_spell", target = target, target_kind = kind, why = why })
        if short then c:wait(short) end
        return c
    end

    -- ==========================================================================
    -- THE HUNTER'S PET
    -- ==========================================================================

    -- Furious Howl: the next attack of everyone within 15 yd of the wolf.
    R.add_rule({
        name = "Pet: Furious Howl",
        category = "pet", priority = 50, kind = "pet_spell",
        needs = { "pet" },
        every = 0.25,
        retry = { hold = 2 },
        propose = function(W, offer)
            if not knows("Furious Howl") or not managed(W) or not own("Furious Howl") then return end
            if not W.player.in_combat then return end
            if not ready("Furious Howl") then note("Furious Howl", "on its cooldown") return end
            if not W.pet.target then note("Furious Howl", "the pet is on nothing") return end
            local s = skill("Furious Howl")
            local radius = (s and s.radius) or 15
            local near, who = 0, {}
            local mine = units.distance and units.distance(W.pet.unit) or huge
            if mine <= radius then near, who[1] = 1, "you" end
            local g = P.ctx and P.ctx.group
            if W.group.in_group and g and g.objects then
                local ok, members = pcall(g.objects)
                if ok and type(members) == "table" then
                    for i = 1, min(#members, 40) do
                        local m = members[i]
                        if m and not rawequal(m, W.player.unit) and units.distance_between then
                            local okd, d = pcall(units.distance_between, W.pet.unit, m)
                            if okd and type(d) == "number" and d <= radius then near = near + 1 end
                        end
                    end
                end
            end
            if near < 2 then
                note("Furious Howl", string.format("%d of your group within %d yd of the wolf (it needs 2: you are %.0f yd away)",
                    near, radius, mine))
                return
            end
            note("Furious Howl", "offered")
            local c = offer_skill(offer, W, "Furious Howl", W.pet.unit, "pet",
                string.format("%d within %d yd of the wolf", near, radius))
            c.near = near
        end,
        score = function(W, c)
            c:add(min(15, (c.near - 1) * 5), string.format("%d attacks each hit harder", c.near))
        end,
    })

    -- Dash, Dive: the pet's mob is far from it.
    local SPRINTS = { "Dash", "Dive" }
    R.add_rule({
        name = "Pet: sprint to its mob",
        category = "pet", priority = 60, kind = "pet_spell",
        needs = { "pet" },
        every = 0.25,
        retry = { hold = 2 },
        propose = function(W, offer)
            if not managed(W) then return end
            local name = nil
            for i = 1, #SPRINTS do
                if knows(SPRINTS[i]) and own(SPRINTS[i]) then name = SPRINTS[i] end
            end
            if not name then return end
            if not ready(name) then note(name, "on its cooldown") return end
            local row, d, gap = pet_target_from_pet(W)
            if not gap then note(name, "the pet is on nothing") return end
            if gap < 15 then note(name, string.format("its mob is %.0f yd away (it needs 15)", gap)) return end
            -- Only on the way to a fight: a mob in it, or the one the pet was sent to.
            local fighting = (row and (row.engaged or row.in_combat)) or W.player.in_combat
                or (P.pet.sent_for and P.pet.sent_for(W.pet.target) ~= nil)
            if not fighting then note(name, "its mob is not in a fight") return end
            note(name, "offered")
            local c = offer_skill(offer, W, name, W.pet.unit, "pet",
                string.format("its mob is %.0f yd away", gap))
            c.gap, c.on_me = gap, row and row.targeting_me
        end,
        score = function(W, c)
            c:add(min(10, floor((c.gap - 15) / 3)), string.format("%.0f yd to cover", c.gap))
            if c.on_me then c:add(10, "it is on you") end
        end,
    })

    -- Charge: the boar's way in, 8 to 25 yd from its mob.
    R.add_rule({
        name = "Pet: Charge",
        category = "pet", priority = 62, kind = "pet_spell",
        needs = { "pet" },
        every = 0.2,
        retry = { hold = 2 },
        propose = function(W, offer)
            if not knows("Charge") or not managed(W) or not own("Charge") then return end
            if not ready("Charge") then note("Charge", "on its cooldown") return end
            local row, _, gap = pet_target_from_pet(W)
            local s = skill("Charge")
            local lo, hi = (s and s.min) or 8, (s and s.range) or 25
            if not gap then note("Charge", "the pet is on nothing") return end
            if gap < lo + 0.5 or gap > hi - 0.5 then
                note("Charge", string.format("its mob is %.0f yd away (it needs %d to %d)", gap, lo, hi))
                return
            end
            local fighting = (row and (row.engaged or row.in_combat)) or W.player.in_combat
                or (P.pet.sent_for and P.pet.sent_for(W.pet.target) ~= nil)
            if not fighting then note("Charge", "its mob is not in a fight") return end
            note("Charge", "offered")
            local c = offer_skill(offer, W, "Charge", W.pet.target, "enemy",
                string.format("%.0f yd from its mob", gap))
            c.on_me = row and row.targeting_me
        end,
        score = function(W, c)
            if c.on_me then c:add(10, "it is on you") end
        end,
    })

    -- Thunderstomp: everything within 8 yd of the gorilla.
    R.add_rule({
        name = "Pet: Thunderstomp",
        category = "pet", priority = 56, kind = "pet_spell",
        needs = { "pet" },
        every = 0.25,
        retry = { hold = 2 },
        propose = function(W, offer)
            if not knows("Thunderstomp") or not managed(W) or not own("Thunderstomp") then return end
            if not W.player.in_combat or not (petthreat and petthreat.from_pet) then return end
            if not ready("Thunderstomp") then note("Thunderstomp", "on its cooldown") return end
            local s = skill("Thunderstomp")
            local radius = (s and s.radius) or 8
            local n_in, on_me = 0, false
            local list, n = W.enemies.list or {}, W.enemies.count or 0
            for i = 1, n do
                local r = list[i]
                if r and r.engaged and (r.hp or 1) > 0 and not (R.tactics and R.tactics.out_of_fight(r)) then
                    local _, d = petthreat.from_pet(r)
                    if d and d <= radius then
                        n_in = n_in + 1
                        if r.targeting_me then on_me = true end
                    end
                end
            end
            if n_in < 2 and not on_me then
                note("Thunderstomp", string.format("%d within %d yd of the pet (it needs 2, or the one on you)", n_in, radius))
                return
            end
            note("Thunderstomp", "offered")
            local c = offer_skill(offer, W, "Thunderstomp", W.pet.unit, "pet",
                string.format("%d within %d yd of the pet", n_in, radius))
            c.n_in, c.on_me = n_in, on_me
        end,
        score = function(W, c)
            if c.n_in >= 2 then c:add(min(15, (c.n_in - 1) * 6), string.format("%d hit", c.n_in)) end
            if c.on_me then c:add(8, "the one on you comes to the pet") end
        end,
    })

    -- Shell Shield: the turtle tanking and going down.
    R.add_rule({
        name = "Pet: Shell Shield",
        category = "pet", priority = 70, kind = "pet_spell",
        needs = { "pet" },
        every = 0.2,
        retry = { hold = 3 },
        propose = function(W, offer)
            if not knows("Shell Shield") or not managed(W) or not own("Shell Shield") then return end
            if not W.player.in_combat then return end
            if not ready("Shell Shield") then note("Shell Shield", "on its cooldown") return end
            local pet = W.pet
            if (pet.attackers or 0) < 1 then note("Shell Shield", "nothing is hitting the pet") return end
            local falling = pet.hp < 0.5 and (pet.hp_rate or 0) < -0.03
            local crowd = (pet.attackers or 0) >= 3
            if not (falling or crowd or W.sit.pet_critical) then
                note("Shell Shield", string.format("the pet is at %d%% with %d on it: fine", pct(pet.hp), pet.attackers))
                return
            end
            note("Shell Shield", "offered")
            local c = offer_skill(offer, W, "Shell Shield", pet.unit, "pet",
                crowd and string.format("%d on the pet", pet.attackers) or string.format("pet at %d%%", pct(pet.hp)))
            c.falling, c.crowd = falling, crowd
        end,
        score = function(W, c)
            local pet = W.pet
            if c.falling then c:add(min(15, floor(-(pet.hp_rate or 0) * 200)), string.format("pet falling %.0f%%/s", -(pet.hp_rate or 0) * 100)) end
            if c.crowd then c:add(8, string.format("%d on the pet", pet.attackers)) end
            if W.sit.pet_critical then c:add(10, "pet critical") end
        end,
    })

    -- Cower: in a group, the pet about to pull its mob off the tank.
    R.add_rule({
        name = "Pet: Cower",
        category = "threat", priority = 66, kind = "pet_spell",
        needs = { "pet" },
        every = 0.25,
        retry = { hold = 2 },
        propose = function(W, offer)
            -- Never on autocast while the engine runs: solo the pet is the tank.
            if not knows("Cower") or not managed(W) or not own("Cower", false) then return end
            if not W.player.in_combat then return end
            local G = W.group
            if not (G.in_group and G.tank_alive) or W.player.is_tank then
                note("Cower", "solo the pet is the tank: never")
                return
            end
            local p = pets()
            if p and W.pet.mode == p.TANK then return end
            if not ready("Cower") or not W.pet.target then return end
            local th = P.ctx and P.ctx.threat
            local board = th and th.get and th.get(W.pet.target) or nil
            local entry = board and board.pet or nil
            local percent = entry and tonumber(entry.percent) or nil
            local holding = (entry and (entry.tanking or (entry.status or 0) >= 2)) or W.target.targets_pet
                and W.pet.target_guid == W.target.guid
            if not holding and not (percent and percent >= 90) then
                note("Cower", percent and string.format("the pet's threat is %d%% of the tank's", floor(percent))
                    or "the pet's threat is not read")
                return
            end
            note("Cower", "offered")
            local c = offer_skill(offer, W, "Cower", W.pet.target, "enemy",
                holding and "the pet has pulled it off the tank" or string.format("the pet's threat %d%%", floor(percent)))
            c.holding, c.percent = holding, percent
        end,
        score = function(W, c)
            if c.holding then c:add(14, "it is on the pet, not the tank") end
            if c.percent then c:add(min(8, floor((c.percent - 90) / 2)), string.format("the pet at %d%% of the tank's", floor(c.percent))) end
        end,
    })

    -- ==========================================================================
    -- THE WARLOCK'S PET
    -- ==========================================================================

    -- Sacrifice: the Voidwalker for your life.
    R.add_rule({
        name = "Pet: Sacrifice",
        category = "defensive", priority = 82, kind = "pet_spell",
        needs = { "pet" },
        every = 0.1,
        retry = { hold = 3 },
        propose = function(W, offer)
            if not knows("Sacrifice") or not own("Sacrifice") then return end
            local pl = W.player
            if not pl.in_combat then return end
            local dying = pl.hp <= 0.25 and ((pl.hp_rate or 0) < -0.02 or (W.enemies.on_me or 0) > 0)
            local soon = pl.hp <= 0.35 and (pl.projected or 1) <= 0.1
            if not (dying or soon) then note("Sacrifice", string.format("you are at %d%%", pct(pl.hp))) return end
            note("Sacrifice", "offered")
            offer({ name = "Sacrifice", kind = "pet_spell", target = W.pet.unit, target_kind = "pet",
                    event_key = "sacrifice", handled_for = 30,
                    why = string.format("you at %d%%", pct(pl.hp)) })
        end,
        score = function(W, c)
            local pl = W.player
            c:add(min(20, floor((0.3 - pl.hp) * 100)), string.format("you at %d%%", pct(pl.hp)))
            if (pl.hp_rate or 0) < -0.05 then c:add(8, "falling fast") end
        end,
    })

    -- Seduction: a humanoid add on you that is not your target.
    local HUMANOID = 7
    R.add_rule({
        name = "Pet: Seduction",
        category = "cc", priority = 84, kind = "pet_spell",
        needs = { "pet" },
        every = 0.2,
        retry = { hold = 4 },
        propose = function(W, offer)
            if not knows("Seduction") or not own("Seduction") then return end
            if not W.player.in_combat or not ready("Seduction") then return end
            -- As the class's own crowd control (rules/core.lua): solo, or the key held.
            local armed = P.key_armed and P.key_armed("rot_fear_key") or false
            if not W.env.solo and not armed then return end
            local memory = lib.memory
            local list, n = W.enemies.list or {}, W.enemies.count or 0
            for i = 1, n do
                local r = list[i]
                if r and r.obj and r.engaged and r.targeting_me and not r.control and r.guid ~= W.target.guid then
                    local f = lib.world and lib.world.facts and lib.world.facts(r.obj, r.guid) or nil
                    if f and f.creature == HUMANOID and not f.player
                        and not (memory and memory.handled("cc:" .. tostring(r.guid))) then
                        note("Seduction", "offered")
                        offer({ name = "Seduction", kind = "pet_spell", target = r.obj, target_kind = "enemy",
                                event_key = "cc:" .. tostring(r.guid), handled_for = 15,
                                why = units.name and units.name(r.obj) or "the add" })
                        return
                    end
                end
            end
            note("Seduction", "no humanoid add on you")
        end,
        score = function(W, c)
            local on = W.enemies.on_me or 0
            if on > 1 then c:add(min(24, (on - 1) * 8), string.format("%d on you", on)) end
            if W.player.hp > 0.6 then c:add(-20, "healthy: control is optional") end
        end,
    })

    -- Consume Shadows: the Voidwalker heals itself between fights.
    R.add_rule({
        name = "Pet: Consume Shadows",
        category = "pet", priority = 45, kind = "pet_spell",
        every = 0.5,
        retry = { hold = 12 },
        needs = { "pet" },
        propose = function(W, offer)
            if not knows("Consume Shadows") or not own("Consume Shadows") then return end
            if W.player.in_combat or (W.enemies.engaged or 0) > 0 or W.pet.hp >= 0.8 then return end
            if not ready("Consume Shadows") then return end
            offer({ name = "Consume Shadows", kind = "pet_spell", target = W.pet.unit, target_kind = "pet",
                    why = string.format("Voidwalker at %d%%", pct(W.pet.hp)) })
        end,
    })
end

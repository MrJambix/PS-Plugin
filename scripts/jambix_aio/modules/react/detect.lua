-- Jambix AIO / react / detect -- naming what is happening.
--
-- The world state says what the numbers are. This says what they MEAN: "health
-- is low", "that cast is dangerous", "we are about to pull this off the tank".
-- Each of those is a situation with two lines (latch.lua), so a reading that
-- sits on a threshold does not flip the answer every frame.
--
-- Nothing here decides what to do about any of it. The rules read these
-- flags; the behaviour state reads these flags; the readout shows them.

return function(P, L)
    local M = {}

    local floor, huge = math.floor, math.huge

    -- --- dangerous casts ------------------------------------------------------
    --
    -- There is no spell database to ask "is this dangerous", and an id table
    -- would have to cover every mob in two expansions. The NAME carries most of
    -- the answer: a heal undoes our damage, a fear or a polymorph takes us out
    -- of the fight, a volley or a pyroblast is the hit that ends a pull. A
    -- weight per pattern, the highest match wins; the caster's rank and whom
    -- the cast is aimed at are added by the interrupt rule's score, not here.

    local DANGER = {
        -- undoes our work
        { "heal", 40, "heal" }, { "renew", 35, "heal" }, { "rejuvenation", 35, "heal" },
        { "regrowth", 35, "heal" }, { "mend", 30, "heal" }, { "prayer of", 40, "heal" },
        { "dark mending", 40, "heal" }, { "chain heal", 40, "heal" },
        -- takes someone out of the fight
        { "fear", 40, "cc" }, { "polymorph", 40, "cc" }, { "sleep", 40, "cc" },
        { "hex", 40, "cc" }, { "charm", 40, "cc" }, { "mind control", 45, "cc" },
        { "seduction", 40, "cc" }, { "banish", 35, "cc" }, { "terrify", 40, "cc" },
        { "howl", 35, "cc" }, { "scream", 35, "cc" }, { "paraly", 40, "cc" },
        { "entangling", 30, "cc" }, { "hibernate", 35, "cc" }, { "silence", 30, "cc" },
        -- the big hits
        { "volley", 35, "damage" }, { "chain lightning", 35, "damage" },
        { "pyroblast", 35, "damage" }, { "flamestrike", 30, "damage" },
        { "blizzard", 30, "damage" }, { "rain of fire", 30, "damage" },
        { "fireball", 25, "damage" }, { "frostbolt", 25, "damage" },
        { "shadow bolt", 25, "damage" }, { "lightning bolt", 25, "damage" },
        { "mind blast", 25, "damage" }, { "holy fire", 25, "damage" },
        { "starfire", 25, "damage" }, { "drain life", 25, "damage" },
        { "blast", 20, "damage" }, { "bolt", 15, "damage" }, { "nova", 20, "damage" },
        -- the fight is about to change shape
        { "summon", 30, "summon" }, { "enrage", 25, "buff" }, { "frenzy", 25, "buff" },
        { "bloodlust", 25, "buff" }, { "shield", 15, "buff" },
        -- what players cast (1.81.0): the mana a caster lives on, the
        -- hunter's big shot, and a player leaving the fight by hearthstone
        { "mana burn", 30, "damage" }, { "drain mana", 25, "damage" }, { "aimed shot", 30, "damage" },
        { "soul fire", 30, "damage" }, { "hearthstone", 25, "escape" },
    }

    local danger_cache = {}       -- lowercased name -> { weight, kind }

    --- How dangerous a cast is, from its name.
    ---@param name string|nil
    ---@return number weight 0..45
    ---@return string|nil kind heal | cc | damage | summon | buff
    function M.cast_danger(name)
        if type(name) ~= "string" or name == "" then return 0, nil end
        local hit = danger_cache[name]
        if hit then return hit[1], hit[2] end
        local lowered = name:lower()
        local best, kind = 0, nil
        for i = 1, #DANGER do
            local row = DANGER[i]
            if row[2] > best and lowered:find(row[1], 1, true) then
                best, kind = row[2], row[3]
            end
        end
        danger_cache[name] = { best, kind }
        return best, kind
    end

    --- A cast worth stopping whatever it costs: a heal, a crowd control, a
    --- big hit, or anything a boss is channelling.
    M.DANGEROUS = 25

    -- --- the situations ---------------------------------------------------------

    local latches = {
        hp_low = L.new({ name = "hp_low", below = true, enter = 0.35, exit = 0.50 }),
        hp_critical = L.new({ name = "hp_critical", below = true, enter = 0.25, exit = 0.40 }),
        pet_low = L.new({ name = "pet_low", below = true, enter = 0.20, exit = 0.45 }),
        pet_critical = L.new({ name = "pet_critical", below = true, enter = 0.12, exit = 0.30 }),
        mana_low = L.new({ name = "mana_low", below = true, enter = 0.15, exit = 0.30 }),
        -- Threat as the client scales it: 100 is where you become the target.
        threat_warning = L.new({ name = "threat_warning", below = false, enter = 70, exit = 60 }),
        threat_critical = L.new({ name = "threat_critical", below = false, enter = 90, exit = 80 }),
        -- Solo with the pet holding the target: our threat on it, as the same
        -- percent. Damage specials wait while this is on (react/adapt.lua).
        pet_threat = L.new({ name = "pet_threat", below = false, enter = 85, exit = 70 }),
        danger_high = L.new({ name = "danger_high", below = false, enter = 55, exit = 35 }),
        danger_extreme = L.new({ name = "danger_extreme", below = false, enter = 80, exit = 60 }),
        aoe = L.new({ name = "aoe", below = false, enter = 3, exit = 1, hold = 2.0 }),
    }
    M.latches = latches

    -- The field's FLEE is already a judgement; this only stops a single
    -- frame of it from counting, and keeps it for a moment once it clears.
    local flee = L.debounce({ name = "flee", settle_on = 0.0, settle_off = 2.5 })

    --- The danger level, 0..100, and what it is made of.
    ---@param W table
    ---@return number
    ---@return string[] reasons
    function M.danger(W)
        local pl, en = W.player, W.enemies
        -- The reasons are words for the readout; nobody reading, no words.
        local explain = W.explain == true
        local d, why = 0, {}
        local function add(points, text)
            if points >= 1 then
                d = d + points
                if explain then why[#why + 1] = string.format("%s +%d", text, floor(points + 0.5)) end
            end
        end

        local fmt = explain and string.format or function() return "" end
        add((1 - pl.hp) * 40, fmt("health %d%%", floor(pl.hp * 100 + 0.5)))
        if pl.hp_rate < 0 then
            add(math.min(25, -pl.hp_rate * 250), fmt("falling %.0f%%/s", -pl.hp_rate * 100))
        end
        if pl.ttl < 12 then
            add(math.min(30, (12 - pl.ttl) * 2.5), fmt("%.0fs to live", pl.ttl))
        end
        if en.on_me > 1 then
            add(math.min(24, (en.on_me - 1) * 8), fmt("%d on you", en.on_me))
        end
        if en.elites > 0 then add(math.min(16, en.elites * 8), "elite") end
        if W.env.boss then add(10, "boss") end
        if W.sit and W.sit.incoming then add(10, "big cast at you") end
        if pl.control then add(15, "lost control") end
        if pl.damage_recent >= 0.15 then
            add(10, fmt("lost %.0f%% in 1.5s", pl.damage_recent * 100))
        end

        if not pl.in_combat and en.on_me == 0 then d = d * 0.3 end
        if d > 100 then d = 100 end
        return d, why
    end

    --- Reads the situations off a freshly built world state. Writes W.sit and
    --- W.env.danger; returns the latches that changed this call.
    ---@param W table
    ---@param now number
    ---@return table[] changes { name, on, value }
    function M.update(W, now)
        local pl, pet, en = W.player, W.pet, W.enemies
        local sit = W.sit
        local changes = {}

        local function feed(name, value, enter, exit)
            local latch = latches[name]
            local on, changed = latch.update(value, now, enter, exit)
            if changed then changes[#changes + 1] = { name = name, on = on, value = value } end
            sit[name] = on
            return on
        end

        local function clear(name)
            local latch = latches[name]
            if latch.on then
                latch.set(false, now)
                changes[#changes + 1] = { name = name, on = false, value = nil }
            end
            sit[name] = false
        end

        -- Lines: the tuned ones where the plugin already chooses one, and a
        -- fixed gap above each to leave by.
        local t = W.thresholds
        feed("hp_low", pl.hp, t.defensive_hp, math.min(0.95, t.defensive_hp + 0.15))
        feed("hp_critical", pl.hp, t.critical_hp, math.min(0.95, t.critical_hp + 0.15))

        if pet.alive then
            feed("pet_low", pet.hp, t.pet_heal_hp, math.min(0.95, t.pet_heal_hp + 0.25))
            feed("pet_critical", pet.hp)
        else
            clear("pet_low")
            clear("pet_critical")
        end

        if pl.power_kind == "MANA" and pl.power_max > 0 then
            feed("mana_low", pl.power_pct, t.critical_power, math.min(0.95, t.critical_power + 0.15))
        else
            clear("mana_low")
        end

        if W.group.in_group and pl.threat.max_pct then
            feed("threat_warning", pl.threat.max_pct)
            feed("threat_critical", pl.threat.max_pct)
        else
            clear("threat_warning")
            clear("threat_critical")
        end
        local mine = W.target.threat_pct
        if pet.tanking and type(mine) == "number" then
            feed("pet_threat", mine)
        else
            clear("pet_threat")
        end

        -- The cast aimed at us: dangerous, and landing before a global
        -- cooldown could be spent reacting to it.
        sit.incoming = false
        for i = 1, en.casting_n do
            local c = en.casting[i]
            if c.at_me and c.danger >= M.DANGEROUS and c.remaining <= 2.0 then
                sit.incoming = true
                break
            end
        end

        local danger, reasons = M.danger(W)
        W.env.danger, W.env.danger_reasons = danger, reasons
        feed("danger_high", danger)
        feed("danger_extreme", danger)

        if pl.in_combat then
            feed("aoe", en.engaged)
        else
            clear("aoe")
        end

        local fleeing, flee_changed = flee.update(W.field.plan == "FLEE", now)
        if flee_changed then changes[#changes + 1] = { name = "flee", on = fleeing } end
        sit.flee = fleeing

        sit.losing = W.field.plan == "SURVIVE" or W.field.plan == "FLEE"
        sit.spike = pl.damage_recent >= 0.15
        sit.adds = W.field.escalating == true
        sit.bailout = W.bailout == true
        sit.incapacitated = pl.control ~= nil

        -- Pulled off the tank: something in the fight is on us, in a group
        -- that has a tank who is not us. Solo, everything is on us and that
        -- is not news.
        sit.aggro_pulled = false
        if W.group.in_group and W.group.tank_alive and not pl.is_tank and en.on_me > 0 then
            sit.aggro_pulled = true
        end

        -- The mob the pet was holding has turned on us.
        sit.pet_lost_aggro = pet.alive and W.target.unit ~= nil and W.target.targets_me
            and pet.target_guid ~= nil and pet.target_guid == W.target.guid

        return changes
    end

    --- For a combat reset: every latch back to off.
    ---@param now number
    function M.reset(now)
        for _, latch in pairs(latches) do latch.set(false, now) end
        flee.set(false, now)
    end

    return M
end

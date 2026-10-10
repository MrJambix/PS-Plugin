-- Jambix AIO / react / petthreat -- which mob the pet should taunt, and which
-- one it should go to.
--
-- WHAT A PET'S TAUNT IS (1.68.0)
-- Growl and Torment are THREAT, not a forced taunt. The client's spell tables
-- give each rank a fixed amount (Growl 50 to 415, Torment 45 to 395) at
-- melee range: five yards from the pet, or both combat reaches and 4/3 if
-- that is more. The mob turns to the pet once the pet's threat passes the
-- holder's. Suffering (the Voidwalker's) is the same for everything within
-- ten yards of it. Intimidation, the hunter's, is the big one: a stun and a
-- large amount of threat for the pet (rules/hunter.lua).
--
-- WHO NEEDS IT: every engaged mob, every pass.
--   on you        its target is you, on every client
--   turning       your threat on it (the client's percent; 100 = it turns to
--                 you) is 90 or more, or 75 and climbing to 100 inside two
--                 seconds. Era only: Forever's threat is unread, so there only
--                 "on you" counts
--   the pet's own what the pet is attacking. The taunt goes on it whenever
--                 ready, as the autocast did. Solo, and in Tank mode
--
-- THE TAUNT goes to the neediest mob inside the pet's reach: one on you
-- first (more when it is in melee with you, you are hurt, it is an elite, or
-- you are outnumbered), then one about to turn, then the pet's own. A mob on
-- you OUTSIDE the reach is where the pet should go instead: `go`, which the
-- "Pet: pick up the add" reaction reads. Nothing here casts.
--
-- IN A GROUP with a living tank, the tank holds the mobs. No upkeep and
-- nothing for "turning" (that is Feign Death's job). A mob on you counts
-- only when it is not a boss and the tank is not on it already. Pet mode
-- Tank ignores the group and acts as solo.
--
-- Never taunted: a mob crowd-controlled in a way damage breaks, one going
-- home (evading), and a stranger's.

return function(P, world, tactics, learn, memory)
    local units = P.units

    local T = {}

    local floor, min, max, huge, sqrt = math.floor, math.min, math.max, math.huge, math.sqrt
    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    local SINGLE = { "Growl", "Torment" }
    local AREA = { Suffering = 10 }       -- yards around the pet
    local FOCUS_COST = { Growl = 15 }
    local TURN_AT, TURN_FROM, TURN_WITHIN = 90, 75, 2.0
    local EDGE = 0.5                      -- yards inside the reach: a pet a step out is not asked
    local DYING = 0.08                    -- the pet's own mob this low: no upkeep, the focus is Claw's
    local SAMPLES, KEEP = 8, 2.5          -- threat samples per mob, and how long they count

    -- Why each skill the engine holds waits, by name (1.73.1): the rules say
    -- it, react/init.lua writes it to the log every 20 s of a fight.
    T.status = {}
    function T.note(name, text)
        if type(name) == "string" then T.status[name] = text end
    end

    local S = {
        live = false, name = nil, area = nil, mode = "solo",
        ready_in = 0, short = nil, area_ready = false, area_n = 0,
        list = {}, pick = nil, go = nil,
        last = nil,                       -- { guid, at, name }: the last taunt sent
    }
    T.state = S

    -- --- how fast our threat climbs, per mob ------------------------------------

    local trail = {}                      -- guid -> { { t, p }, ... } oldest first

    local function threat_rate(guid, p, now)
        local list = trail[guid]
        if not list then
            list = {}
            trail[guid] = list
        end
        local newest = list[#list]
        -- Dropped hard (Feign Death, a threat wipe): start again from here.
        if newest and p < newest.p - 20 then
            for i = #list, 1, -1 do list[i] = nil end
            newest = nil
        end
        if not newest or (now - newest.t) >= 0.2 then
            list[#list + 1] = { t = now, p = p }
            if #list > SAMPLES then table.remove(list, 1) end
        end
        while #list > 2 and (now - list[1].t) > KEEP do table.remove(list, 1) end
        local first, last = list[1], list[#list]
        local dt = last.t - first.t
        if dt < 0.4 then return 0 end
        return (last.p - first.p) / dt
    end

    function T.reset()
        for k in pairs(trail) do trail[k] = nil end
        S.last = nil
    end

    -- --- where it stands from the pet -------------------------------------------

    local function reach_of(unit)
        local r = units.combat_reach and units.combat_reach(unit) or nil
        if type(r) ~= "number" or r <= 0 then return 1.5 end
        return r
    end

    --- Inside the taunt's reach from the pet (the client's melee range,
    --- centre to centre), and how far: nil, nil when a position is not known.
    local function from_pet(pet_pos, pet_unit, r)
        if not pet_pos or type(r.x) ~= "number" or type(r.y) ~= "number" then return nil, nil end
        if r.x == 0 and r.y == 0 and (r.z or 0) == 0 then return nil, nil end
        local dx, dy, dz = r.x - pet_pos.x, r.y - pet_pos.y, (r.z or 0) - (pet_pos.z or 0)
        local d = sqrt(dx * dx + dy * dy + dz * dz)
        local range = max(5, reach_of(pet_unit) + reach_of(r.obj) + 4 / 3)
        return d <= range - EDGE, d
    end

    local function evading(guid)
        return learn ~= nil and learn.evading ~= nil and learn.evading(guid) == true
    end

    --- In a fight that is not ours: in combat with somebody who is not us,
    --- the pet or the group, and never hit by us.
    local function strangers(r, W)
        if r.engaged or not r.in_combat or not r.target_guid then return false end
        local g = r.target_guid
        if g == W.player.guid or g == W.pet.guid or (world.in_group and world.in_group(g)) then return false end
        return not (memory and memory.attacked and memory.attacked(r.guid, 20))
    end

    -- --- one pass ---------------------------------------------------------------

    local function add(e, points, why)
        e.need = e.need + points
        e.reasons[#e.reasons + 1] = { points, why }
    end

    --- One look at every engaged mob. Writes W.petthreat (this module's state).
    ---@param W table
    ---@param now number
    ---@return table state
    function T.update(W, now)
        W.petthreat = S
        S.live, S.pick, S.go, S.short, S.area_n = false, nil, nil, nil, 0
        S.name, S.area, S.ready_in, S.area_ready = nil, nil, 0, false
        local list = S.list
        for i = #list, 1, -1 do list[i] = nil end

        local pet, pl = W.pet, W.player
        local pets = P.pet
        S.pet_pos, S.pet_unit = nil, nil
        if not pet.alive or not pets or not pets.knows then return S end
        -- Where the pet stands, for every pet (rules/pet.lua measures from it too).
        local pet_unit = pet.unit
        local pet_pos = (units.position and pet_unit) and units.position(pet_unit) or nil
        S.pet_pos, S.pet_unit = pet_pos, pet_unit
        if pet.mode == pets.OFF or pet.mode == pets.FOCUS then return S end
        for i = 1, #SINGLE do
            if pets.knows(SINGLE[i]) then S.name = SINGLE[i] break end
        end
        for name in pairs(AREA) do
            if pets.knows(name) then S.area = name end
        end
        if not S.name and not S.area then return S end
        S.live = true
        local ready_in = pets.ready_in
        S.ready_in = (S.name and ready_in) and (ready_in(S.name) or 0) or 0
        S.area_ready = S.area ~= nil and (not ready_in or (ready_in(S.area) or 0) <= 0)
        -- Growl's price, where the client says what the pet has.
        local cost = S.name and FOCUS_COST[S.name]
        if cost and pets.focus_power then
            local current = pets.focus_power()
            if current and current < cost then
                S.short = string.format("the pet has %d focus, %s costs %d", floor(current), S.name, cost)
            end
        end

        local G = W.group
        local tank_mode = pets.TANK ~= nil and pet.mode == pets.TANK
        local grouped = G.in_group == true and G.tank_alive == true and not pl.is_tank and not tank_mode
        S.mode = grouped and "group" or "solo"
        local tank_target, tank_read = nil, false

        local Hh = P.rotation and P.rotation.helpers
        local rows, n = W.enemies.list or {}, W.enemies.count or 0
        local seen = {}
        -- The pet's own mob: its target; else the one it was last sent at;
        -- else one hitting it (1.73.1: a client that does not say the pet's
        -- target left the routine Growl with no mob at all).
        local held_guid = pet.target_guid
        if not held_guid and pets.designated then held_guid = pets.designated() end
        S.held_guid = held_guid
        for i = 1, n do
            local r = rows[i]
            local held = r ~= nil and ((held_guid ~= nil and r.guid == held_guid)
                or (held_guid == nil and r.targeting_pet == true))
            if r and r.obj and r.guid and (r.engaged or held) and r.activity ~= "dead" and (r.hp or 1) > 0
                and not tactics.out_of_fight(r) and not strangers(r, W)
                and not (held and pet.target_evading) and not evading(r.guid) then
                seen[r.guid] = true
                local p = type(r.threat) == "table" and tonumber(r.threat.percent) or nil
                local rate = p and threat_rate(r.guid, p, now) or 0
                local reach, d_pet = from_pet(pet_pos, pet_unit, r)
                if held and reach == nil and S.name and pets.in_range then reach = pets.in_range(S.name) end
                -- Its own target, with neither positions nor the client to say:
                -- the pet is on it (pet.cast still refuses an answer of "no").
                if held and reach == nil and not pet_pos then reach = true end
                local e = { row = r, guid = r.guid, obj = r.obj, held = held, reach = reach, d_pet = d_pet,
                            threat = p, rate = rate, need = 0, reasons = {}, kind = nil }
                local f = world.facts and world.facts(r.obj, r.guid) or nil
                if r.targeting_me then
                    local skip = false
                    if grouped then
                        if f and f.boss then skip = true end
                        if not skip and G.tank then
                            if not tank_read then
                                tank_read = true
                                local ok, t = pcall(G.tank.get_target, G.tank)
                                tank_target = ok and t and units.guid and units.guid(t) or nil
                            end
                            if tank_target == r.guid then skip = true end
                        end
                    end
                    if not skip then
                        e.kind = "on you"
                        add(e, 14, "it is on you")
                        local melee = (Hh and Hh.in_melee and Hh.in_melee(r.obj, r.dist)) or (r.dist or huge) <= 5
                        e.melee = melee == true
                        if e.melee then add(e, 6, "in melee with you") end
                        if (pl.hp or 1) < 0.5 then add(e, 8, string.format("you are at %d%%", pct(pl.hp))) end
                        if f and f.elite then add(e, 4, "elite") end
                        if W.sit.outnumbered then add(e, 4, "outnumbered") end
                    end
                elseif not grouped and p and (p >= TURN_AT
                        or (p >= TURN_FROM and rate > 0 and p + rate * TURN_WITHIN >= 100)) then
                    e.kind = "turning"
                    local points = 6 + min(8, floor((p - TURN_FROM) / 3))
                    if p >= TURN_AT then
                        add(e, points, string.format("your threat %d%%: it turns to you at 100", floor(p)))
                    else
                        add(e, points, string.format("your threat %d%%, %+.0f/s: on you in ~%.1fs",
                            floor(p), rate, (100 - p) / rate))
                    end
                elseif held and not grouped and (r.hp or 1) > DYING then
                    e.kind = "the pet's own"
                    add(e, -22, "the pet's own mob: on cooldown, as autocast did")
                end
                if e.kind then list[#list + 1] = e end
            end
        end
        for guid in pairs(trail) do
            if not seen[guid] then trail[guid] = nil end
        end

        table.sort(list, function(a, b)
            if a.need ~= b.need then return a.need > b.need end
            return (a.d_pet or huge) < (b.d_pet or huge)
        end)
        -- The taunt: the neediest in reach. The pet goes: the neediest on you
        -- that it cannot reach from where it stands.
        for i = 1, #list do
            local e = list[i]
            if not S.pick and e.reach == true then S.pick = e end
            if not S.go and e.kind == "on you" and not e.held and e.reach ~= true then S.go = e end
        end
        -- The area taunt: two or more on you or about to be, around the pet.
        if S.area then
            local radius = AREA[S.area]
            for i = 1, #list do
                local e = list[i]
                if (e.kind == "on you" or e.kind == "turning") and e.d_pet and e.d_pet <= radius then
                    S.area_n = S.area_n + 1
                end
            end
        end
        return S
    end

    --- Whether a row is inside the taunt's reach from the pet, and how far
    --- it is (centre to centre), by this pass's pet position: nil, nil when
    --- either position is not known.
    ---@param row table an enemies row
    ---@return boolean|nil
    ---@return number|nil
    function T.from_pet(row)
        if not row then return nil, nil end
        return from_pet(S.pet_pos, S.pet_unit, row)
    end

    --- Remembers a taunt that went out: the readout says it, and Intimidation
    --- asks whether the mob came back after it.
    function T.sent(guid, name, now)
        S.last = { guid = guid, name = name, at = now }
    end

    -- --- the readout --------------------------------------------------------------

    local function where(e)
        local parts = { e.kind }
        if e.reach == true then
            parts[#parts + 1] = e.d_pet and string.format("%.0fy from the pet", e.d_pet) or "in reach"
        elseif e.d_pet then
            parts[#parts + 1] = string.format("%.0fy from the pet: out of reach", e.d_pet)
        end
        if e.threat then parts[#parts + 1] = string.format("your threat %d%%", floor(e.threat)) end
        return table.concat(parts, ", ")
    end

    --- One line: the taunt, what it goes to next, and where the pet should
    --- go. nil when the pet has no taunt, or in a fight with nothing to say.
    ---@param name_of fun(unit): string
    ---@return string|nil
    function T.line(name_of)
        if not S.live then return nil end
        local parts = {}
        local label = S.name or S.area
        local status
        local stuck = P.pet and P.pet.taunt_stuck and P.pet.taunt_stuck() or nil
        if S.short then
            status = S.short
        elseif stuck then
            status = string.format("%s left on autocast (%s): the pet is moved instead", S.name or label, stuck)
        elseif S.name and S.ready_in > 0 then
            status = string.format("%s in %.1fs", S.name, S.ready_in)
        else
            status = string.format("%s ready", label)
        end
        parts[1] = status
        if S.pick then
            parts[#parts + 1] = string.format("next %s (%s)", name_of(S.pick.obj), where(S.pick))
        end
        if S.go then
            parts[#parts + 1] = string.format("the pet goes to %s (%s)", name_of(S.go.obj), where(S.go))
        end
        if S.area and S.area_n >= 2 then
            parts[#parts + 1] = string.format("%d around the pet for %s%s", S.area_n, S.area,
                S.area_ready and "" or " (not ready)")
        end
        if #parts == 1 and not S.pick then return nil end
        return "Pet taunt: " .. table.concat(parts, " | ")
    end

    return T
end

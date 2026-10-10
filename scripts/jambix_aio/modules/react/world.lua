-- Jambix AIO / react / world -- one picture of the fight, built once a tick.
--
-- WHY ONE TABLE
-- Every reaction asks the same few questions -- how much health, is the pet
-- alright, is anything casting, who is the mob looking at -- and if each rule
-- asked the game itself, twelve rules would be twelve sets of native calls a
-- frame for the same answers. So the answers are read ONCE, here, into one
-- table every rule reads from; no rule reads the game.
--
-- WHERE THE ANSWERS COME FROM
-- Nearly all of it is already in hand: the rotation's snapshot (health, power,
-- target, every hostile row from JCore's enemies tracker), the field's race,
-- the resource slopes, the threat boards. The reads this module adds are
-- rationed:
--   * a unit's level and rank are static -- read once per unit, kept 10s
--   * the group roster is re-walked twice a second, not every frame
--   * the pet's handle and target: one read each per tick
--   * a cast's remaining time is worked out from the end time the enemies
--     row already carries, not asked again
-- The current target is the one thing refreshed every tick regardless; the
-- rest of the hostiles hold the enemies tracker's own (budgeted) reads.
--
-- The table is REUSED between ticks: a rule must not keep a reference to it,
-- or to anything in it, beyond the tick it was handed.

return function(P, D, memory)
    local ctx, units, combat = P.ctx, P.units, P.combat
    -- JCore 1.6.0 answers these per client: the rank (units.classification,
    -- the creature cache's on Forever) and whose mob it is (loot.tapped,
    -- false on Era with no read).
    local loot = ctx and ctx.loot
    local book = P.spellbook

    local M = {}

    local huge = math.huge
    local NEAR = 40               -- "nearby" for the enemy count
    local MAX_CASTERS = 8         -- casting rows carried per tick
    local FACT_TTL = 10.0
    local GROUP_EVERY = 0.5

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        if ok then return value end
        return nil
    end

    local function game_ms()
        if type(core.game_time) ~= "function" then return nil end
        local ok, value = pcall(core.game_time)
        return ok and type(value) == "number" and value or nil
    end

    -- --- the table ------------------------------------------------------------

    local W = {
        now = 0,
        player = { threat = {} },
        pet = {},
        target = { cast = {} },
        enemies = { casting = {}, casting_n = 0 },
        group = {},
        env = {},
        sit = {},
        field = {},
        thresholds = {},
    }
    M.W = W

    -- Cast views, reused: one per casting row carried.
    local cast_pool = {}
    for i = 1, MAX_CASTERS do cast_pool[i] = {} end

    -- --- static facts per unit -------------------------------------------------

    local facts, fact_count = {}, 0

    local function facts_of(unit, guid)
        if not unit or not guid then return nil end
        local now = W.now
        local f = facts[guid]
        if f and (now - f.at) < FACT_TTL then return f end
        if not f then
            f = {}
            facts[guid] = f
            fact_count = fact_count + 1
        end
        f.at = now
        f.level = try(unit.get_level, unit) or 0
        if units.classification then
            f.classification = try(units.classification, unit) or 0
        else
            f.classification = try(unit.get_classification, unit) or 0
        end
        f.player = try(unit.is_player, unit) == true
        f.creature = try(unit.get_creature_type, unit)
        -- WoW's creature classification: 1 elite, 2 rare elite, 3 boss, 4 rare.
        f.boss = f.classification == 3 or try(unit.is_boss, unit) == true
        f.elite = f.boss or f.classification == 1 or f.classification == 2
        f.rare = f.classification == 2 or f.classification == 4
        return f
    end

    --- A unit's level and rank, read once and kept ten seconds: the plan's
    --- guess at what an elite it has not measured yet hits for.
    M.facts = facts_of

    --- Drops what was learned about units, between fights.
    function M.forget_units()
        if fact_count > 200 then facts, fact_count = {}, 0 end
    end

    -- --- spell names ------------------------------------------------------------

    local name_cache = {}

    ---@param spell_id integer|nil
    ---@return string
    local function spell_name(spell_id)
        if not spell_id then return "" end
        local hit = name_cache[spell_id]
        if hit then return hit end
        local name = ""
        local spells = ctx and ctx.spells
        if spells and spells.name then name = try(spells.name, spell_id) or "" end
        name_cache[spell_id] = name
        return name
    end
    M.spell_name = spell_name

    --- A cast as the rules want it, from an enemies-row cast.
    local function fill_cast(out, cast, now_ms)
        out.spell_id = cast.spell_id
        out.name = spell_name(cast.spell_id)
        out.channel = cast.channel == true
        out.interruptible = cast.interruptible == true
        out.started = cast.start_at
        local end_ms = type(cast.end_at) == "number" and cast.end_at or 0
        if end_ms > 0 and now_ms then
            out.remaining = math.max(0, (end_ms - now_ms) / 1000.0)
        else
            out.remaining = cast.remaining or 0
        end
        local start_ms = type(cast.start_at) == "number" and cast.start_at or 0
        out.total = (end_ms > start_ms and start_ms > 0) and ((end_ms - start_ms) / 1000.0) or out.remaining
        out.danger, out.kind = D.cast_danger(out.name)
        return out
    end

    -- --- the group, twice a second ------------------------------------------------

    local group_at = -huge
    local group_guids = {}          -- guid -> true for every member and their pets

    local function refresh_group(g, player_guid)
        local G = W.group
        G.in_group = try(g.in_group) == true
        G.in_raid = try(g.in_raid) == true
        G.size = try(g.size) or 0

        if (W.now - group_at) < GROUP_EVERY then return end
        group_at = W.now

        local guids = {}
        local dead, members = 0, 0
        local objects = G.in_group and try(g.objects) or nil
        if type(objects) == "table" then
            for i = 1, math.min(#objects, 40) do
                local unit = objects[i]
                local guid = unit and units.guid(unit)
                if guid and guid ~= player_guid then
                    guids[guid] = true
                    members = members + 1
                    if try(units.is_dead, unit) == true then dead = dead + 1 end
                end
            end
        end
        group_guids = guids
        G.members, G.dead = members, dead

        local function first_alive(list)
            if type(list) ~= "table" then return nil, 0 end
            local alive, n = nil, 0
            for i = 1, #list do
                local unit = list[i]
                if unit and try(unit.is_valid, unit) == true and not (try(unit.is_dead, unit) == true) then
                    n = n + 1
                    alive = alive or unit
                end
            end
            return alive, n
        end

        G.tank, G.tanks = nil, 0
        G.healer, G.healers = nil, 0
        if G.in_group then
            G.tank, G.tanks = first_alive(try(g.tanks))
            G.healer, G.healers = first_alive(try(g.healers))
        end
        G.tank_alive = G.tank ~= nil
        G.healer_alive = G.healer ~= nil

        -- Loss of control is a native per unit; only the two that matter.
        G.healer_controlled = false
        if G.healer then
            local loc = try(G.healer.get_loss_of_control_info, G.healer)
            G.healer_controlled = type(loc) == "table" and loc.valid == true
        end
        G.tank_guid = G.tank and units.guid(G.tank) or nil
        G.healer_guid = G.healer and units.guid(G.healer) or nil
    end

    --- Is this guid one of the group (not us, not our pet)?
    ---@param guid string|nil
    ---@return boolean
    function M.in_group(guid)
        return guid ~= nil and group_guids[guid] == true
    end

    -- --- threat trend --------------------------------------------------------------

    local threat_samples = {}       -- { t, pct } newest last
    local function threat_rate(pct, now)
        if not pct then
            threat_samples = {}
            return 0
        end
        local last = threat_samples[#threat_samples]
        if not last or (now - last.t) >= 0.25 then
            threat_samples[#threat_samples + 1] = { t = now, pct = pct }
            while #threat_samples > 2 and (now - threat_samples[1].t) > 2.0 do
                table.remove(threat_samples, 1)
            end
        end
        local first = threat_samples[1]
        local newest = threat_samples[#threat_samples]
        local dt = newest.t - first.t
        if dt < 0.5 then return 0 end
        return (newest.pct - first.pct) / dt
    end

    -- --- the build -------------------------------------------------------------------

    local player_guid_cache, player_ref = nil, nil
    local pet_hold = { guid = nil, since = 0, seen = -huge }
    local item_usable_cache = {}    -- item id -> { at, usable }

    local function item_ready(kind)
        local hc = P.hardcore
        if not hc or not hc.item then return false end
        local id = hc.item(kind)
        if not id then return false end
        local cached = item_usable_cache[id]
        if cached and (W.now - cached.at) < 1.0 then return cached.usable end
        local usable = true
        local fn = type(core.spell_book) == "table" and core.spell_book.is_item_usable or nil
        if fn then
            local ok, answer = pcall(fn, id)
            if ok and answer == false then usable = false end
        end
        item_usable_cache[id] = { at = W.now, usable = usable }
        return usable
    end

    ---@param class_module table
    ---@param profile table
    ---@param s table the rotation's snapshot for this tick
    ---@param now number
    ---@return table W
    function M.build(class_module, profile, s, now)
        W.now = now
        W.s = s
        W.class = class_module
        W.profile = profile
        W.hold_fire = s.hold_fire == true
        W.can = s.can or {}
        local now_ms = game_ms()

        -- --- thresholds ---------------------------------------------------------
        local t = W.thresholds
        -- The defensive and pet-heal lines are no longer settings (1.32.0):
        -- derived from the fight, never read from a removed slider. The
        -- hardcore lines are the hardcore module's own.
        local function derived(id, fallback_pct)
            if P.derived then return P.derived(id, fallback_pct) end
            return fallback_pct / 100
        end
        local hc_lines = P.hardcore or {}
        t.defensive_hp = derived("rot_defensive_hp", 35)
        t.critical_hp = P.tune and P.tune("res_critical_hp", 25) or 0.25
        t.pet_heal_hp = derived("pet_heal_hp", 20)
        t.critical_power = P.tune and P.tune("res_critical_power", 10) or 0.10
        t.potion_hp = hc_lines.POTION_LINE or 0.35
        t.bail_hp = hc_lines.BAIL_LINE or 0.20
        t.hearth_hp = hc_lines.HEARTH_LINE or 0.15

        -- --- the field -----------------------------------------------------------
        local F = W.field
        local fs = P.field and P.field.state or nil
        F.plan = fs and fs.plan or "BURN"
        F.shape = fs and fs.shape or "IDLE"
        F.reason = fs and fs.reason or ""
        F.count = fs and fs.count or 0
        F.inbound = fs and fs.inbound or 0
        F.elites = fs and fs.elites or 0
        F.escalating = fs and fs.escalating or false
        F.time_to_live = fs and fs.time_to_live or huge
        F.time_to_clear = fs and fs.time_to_clear or huge

        -- --- the player ----------------------------------------------------------
        local player = s.player
        if player ~= player_ref then
            player_ref = player
            player_guid_cache = player and units.guid(player) or nil
        end
        local pl = W.player
        pl.unit, pl.guid = player, player_guid_cache
        pl.hp = s.hp or 1
        local res = P.resources
        pl.hp_rate = res and res.hp_rate and (try(res.hp_rate) or 0) or 0
        pl.ttl = F.time_to_live
        pl.posture = s.posture or "HEALTHY"
        pl.projected = pl.hp + pl.hp_rate * 2.0
        pl.power, pl.power_max = s.power or 0, s.power_max or 0
        pl.power_pct = pl.power_max > 0 and (pl.power / pl.power_max) or 0
        pl.power_kind = (profile and profile.power) or (class_module and class_module.power) or "MANA"
        pl.in_combat = s.in_combat == true
        pl.moving = s.moving == true
        pl.still_for = s.still_for or (pl.moving and 0 or huge)
        pl.dead = false

        memory.sample_hp(pl.hp)
        pl.damage_recent = memory.damage_taken(1.5)

        local cast_left = try(combat.cast_remaining)
        pl.cast_remaining = type(cast_left) == "number" and cast_left or 0
        local cp = ctx and ctx.player
        pl.casting_id = nil
        pl.channelling = false
        if pl.cast_remaining > 0 and cp then
            pl.casting_id = try(cp.casting_spell_id)
            pl.channelling = try(cp.is_channelling) == true
        end
        pl.busy = pl.cast_remaining > 0.25

        local loc = cp and try(cp.loss_of_control) or nil
        if type(loc) == "table" and loc.valid then
            local end_ms = type(loc.end_time) == "number" and loc.end_time or 0
            pl.control = {
                type = loc.type, spell_id = loc.spell_id,
                remaining = (end_ms > 0 and now_ms) and math.max(0, (end_ms - now_ms) / 1000) or 0,
            }
        else
            pl.control = nil
        end
        pl.level = cp and try(cp.level) or 0

        -- What is in the bag for this, and which defensives are up.
        pl.healthstone = item_ready("healthstone")
        pl.potion = item_ready("potion")
        pl.mana_gem = item_ready("mana_gem")
        pl.mana_potion = item_ready("mana_potion")

        -- The mana race: how long the bar lasts at the rate it is going,
        -- against how long the fight has left.
        pl.fight_left = res and res.fight_left and (try(res.fight_left) or huge) or huge
        pl.power_empty = res and res.power_empty and (try(res.power_empty) or huge) or huge
        local ready = 0
        local list = class_module and class_module.defensives or {}
        for i = 1, #list do
            if book.ready(list[i]) then ready = ready + 1 end
        end
        pl.defensives_ready = ready
        local escapes_ready = 0
        local escapes = class_module and class_module.escapes or {}
        local helpers = P.rotation and P.rotation.helpers
        for i = 1, #escapes do
            local name = escapes[i]
            if book.ready(name) and (not helpers or not helpers.key_allows or helpers.key_allows(name)) then
                escapes_ready = escapes_ready + 1
            end
        end
        pl.escapes_ready = escapes_ready
        local spells = ctx and ctx.spells
        pl.gcd = spells and spells.gcd and (try(spells.gcd) or 0) or 0

        -- Our own auras by name, for the procs that change the rotation
        -- (Clearcasting, Shadow Trance, Presence of Mind).
        local names = pl.aura_names or {}
        for k in pairs(names) do names[k] = nil end
        if player and units.aura_index then
            local index = try(units.aura_index, player)
            if type(index) == "table" then
                for _, aura in pairs(index) do
                    local n = type(aura) == "table" and aura.buff_name or nil
                    if type(n) == "string" then names[n] = true end
                end
            end
        end
        pl.aura_names = names
        pl.auto_attacking = player ~= nil and try(player.is_auto_attacking, player) == true
        -- The client's auto-attack flag does not cover Auto Shot or a wand on
        -- every build; a shot of either within a swing does.
        pl.shooting = memory.since_success("Auto Shot") < 4.5 or memory.since_success("Shoot") < 4.5

        -- --- the group -----------------------------------------------------------
        local g = ctx and ctx.group
        if g then
            refresh_group(g, pl.guid)
        else
            local G = W.group
            G.in_group, G.in_raid, G.size, G.members, G.dead = false, false, 0, 0, 0
            G.tank, G.healer, G.tank_alive, G.healer_alive = nil, nil, false, false
            G.tanks, G.healers, G.healer_controlled = 0, 0, false
        end
        local role_tank = g and pl.unit and try(g.is_tank, pl.unit) == true
        local label = profile and profile.label or ""
        pl.is_tank = role_tank or (profile and profile.tank == true)
            or label:find("Tank", 1, true) ~= nil or label:find("Prot", 1, true) ~= nil
        W.group.solo = not W.group.in_group

        -- --- threat ---------------------------------------------------------------
        local th = ctx and ctx.threat
        local T = pl.threat
        T.max_pct, T.max_unit, T.holding, T.rate = nil, nil, 0, 0
        if th then
            local board, pct = nil, 0
            if th.closest_to_pulling then board, pct = th.closest_to_pulling() end
            if board then
                T.max_pct, T.max_unit = pct, board.obj
            end
            T.holding = th.holding and (try(th.holding) or 0) or 0
        end
        T.rate = threat_rate(T.max_pct, now)

        -- --- the pet --------------------------------------------------------------
        local pet = W.pet
        local pet_unit = P.pet and P.pet.pet and try(P.pet.pet) or nil
        pet.unit = pet_unit
        pet.alive = pet_unit ~= nil
        if pet_unit then
            pet.guid = units.guid(pet_unit)
            pet.hp = units.health_fraction(pet_unit)
            pet.hp_rate = P.pet.hp_rate and (try(P.pet.hp_rate) or 0) or 0
            pet.projected = pet.hp + pet.hp_rate * 2.5
            local held = P.pet.pet_target and try(P.pet.pet_target) or nil
            -- A CLIENT THAT DOES NOT SAY WHAT THE PET IS ATTACKING (1.73.1):
            -- the mob the pet was last sent at, while it lives and for 30 s.
            -- Without it every pet rule saw a pet on nothing, and the Growl
            -- on its own mob was never pressed once autocast was off.
            pet.target_inferred = false
            if not held and P.pet.designated then
                local guid, age = P.pet.designated()
                if guid and age and age < 30 and units.by_guid then
                    local u = try(units.by_guid, guid)
                    if u and try(u.is_valid, u) == true and try(u.is_dead, u) ~= true then
                        held, pet.target_inferred = u, true
                    end
                end
            end
            pet.target = held
            pet.target_guid = held and units.guid(held) or nil
            pet.mode = P.pet.mode and (try(P.pet.mode) or 2) or 2
        else
            pet.guid, pet.hp, pet.hp_rate, pet.projected = nil, 0, 0, 0
            pet.target, pet.target_guid = nil, nil
        end

        -- --- the target -------------------------------------------------------------
        local tg = W.target
        local target = s.target
        tg.unit = target
        tg.guid = target and units.guid(target) or nil
        memory.target_seen(tg.guid)
        tg.hp = s.thp or 0
        tg.distance = s.distance or huge
        tg.ttd = s.ttd or 0
        local f = target and facts_of(target, tg.guid) or nil
        tg.level = f and f.level or 0
        tg.level_diff = (f and f.level and f.level > 0 and pl.level > 0) and (f.level - pl.level) or 0
        tg.elite = f and f.elite or false
        tg.boss = f and f.boss or false
        tg.rare = f and f.rare or false
        tg.player = f and f.player or false
        tg.creature = f and f.creature or nil

        local row = s.target_row
        tg.row = row
        tg.casting = false
        if row and row.casting then
            fill_cast(tg.cast, row.casting, now_ms)
            tg.casting = true
        elseif target and not row then
            -- Not a tracked hostile (no enemies service, or not in its range):
            -- read the one unit that matters directly.
            if try(target.is_casting_spell, target) == true then
                fill_cast(tg.cast, {
                    spell_id = try(target.get_active_spell_id, target),
                    start_at = try(target.get_active_spell_cast_start_time, target),
                    end_at = try(target.get_active_spell_cast_end_time, target),
                    interruptible = try(target.is_active_spell_interruptable, target) ~= false,
                }, now_ms)
                tg.casting = true
            end
        end
        tg.target_guid = row and row.target_guid or nil
        tg.targets_me = row ~= nil and row.targeting_me == true
        tg.targets_pet = row ~= nil and row.targeting_pet == true
        tg.targets_group = tg.target_guid ~= nil and M.in_group(tg.target_guid)
        tg.controlled = row ~= nil and row.control ~= nil
        tg.activity = row and row.activity or nil
        tg.closing = row and row.closing or 0
        tg.threat_pct, tg.threat_rank, tg.tanking = nil, nil, false
        if th and target and th.mine then
            local pct, rank, _, tanking = th.mine(target)
            tg.threat_pct, tg.threat_rank, tg.tanking = pct, rank, tanking == true
        end
        -- The enemies row's detail is read a few times a second; the mob's
        -- own target is one call, and a moment matters here.
        if target and pet.guid and not tg.targets_pet and not tg.targets_me then
            local their = try(target.get_target, target)
            if their and units.guid(their) == pet.guid then
                tg.target_guid = pet.guid
                tg.targets_pet = true
            end
        end

        -- SOMEONE ELSE'S FIGHT (1.47.4): in combat with a unit that is not us,
        -- our pet or our group, and not a mob we started on. On Forever the
        -- client never says "tapped by another" -- the API recorder saw
        -- is_tap_denied answer false on every mob it caught fighting a stranger
        -- -- so it is read from who the mob is hitting. Kicking or stunning it
        -- would only pull it onto us.
        tg.others_fight = row ~= nil and row.in_combat == true and tg.target_guid ~= nil
            and not tg.targets_me and not tg.targets_pet and not tg.targets_group
            and tg.target_guid ~= pl.guid and not memory.attacked(tg.guid, 20)
        -- And whatever JCore calls somebody else's (on Forever the client's
        -- is_tap_denied, true since patch 1.60.1.70205, or a stranger's fight).
        if not tg.others_fight and target and loot and loot.tapped and try(loot.tapped, target) == true then
            tg.others_fight = true
        end

        -- --- the pet as the tank ---------------------------------------------------
        -- Solo, with the target on the pet: how long it has been there. A
        -- read that misses it for a moment does not restart the count.
        pet.tanking = pet.alive and not W.group.in_group and target ~= nil and tg.targets_pet
        if pet.tanking then
            if pet_hold.guid ~= tg.guid or (now - pet_hold.seen) > 0.6 then
                pet_hold.guid, pet_hold.since = tg.guid, now
            end
            pet_hold.seen = now
            pet.held_for = now - pet_hold.since
        else
            pet.held_for = 0
        end

        -- --- the hostiles -------------------------------------------------------------
        local en = W.enemies
        local rows, count = s.enemies or {}, s.enemy_count or 0
        local nearby, engaged, controlled, on_me, on_pet, on_group = 0, 0, 0, 0, 0, 0
        local melee_on_me = 0
        local casting_n = 0
        for i = 1, count do
            local r = rows[i]
            if r then
                if (r.dist or huge) <= NEAR then nearby = nearby + 1 end
                if r.engaged then engaged = engaged + 1 end
                if r.control then controlled = controlled + 1 end
                if r.targeting_me then
                    on_me = on_me + 1
                    if (r.dist or huge) <= 8 then melee_on_me = melee_on_me + 1 end
                end
                if r.targeting_pet then on_pet = on_pet + 1 end
                if r.engaged and not r.targeting_me and not r.targeting_pet
                    and r.target_guid and group_guids[r.target_guid] then
                    on_group = on_group + 1
                end
                if r.casting and casting_n < MAX_CASTERS and r.obj then
                    casting_n = casting_n + 1
                    local c = fill_cast(cast_pool[casting_n], r.casting, now_ms)
                    c.row, c.unit, c.guid = r, r.obj, r.guid
                    c.dist = r.dist or huge
                    c.engaged = r.engaged == true
                    c.at_me = r.targeting_me == true
                    c.at_pet = r.targeting_pet == true
                    c.at_group = r.target_guid ~= nil and group_guids[r.target_guid] == true
                    c.at_healer = c.at_group and r.target_guid == W.group.healer_guid
                    c.current = r.guid ~= nil and r.guid == tg.guid
                    local cf = facts_of(r.obj, r.guid)
                    c.elite = cf and cf.elite or false
                    c.boss = cf and cf.boss or false
                    c.player = cf and cf.player or false
                end
            end
        end
        for i = casting_n + 1, #en.casting do en.casting[i] = nil end
        for i = 1, casting_n do en.casting[i] = cast_pool[i] end
        en.casting_n = casting_n
        en.nearby, en.controlled = nearby, controlled
        en.engaged = math.max(engaged, F.count)
        en.on_me = math.max(on_me, s.on_me or 0)
        en.on_pet, en.on_group = on_pet, on_group
        en.melee_on_me = melee_on_me
        en.elites = F.elites
        en.inbound = math.max(F.inbound, s.closing or 0)
        en.list, en.count = rows, count
        pet.attackers = on_pet

        -- --- the encounter --------------------------------------------------------------
        local env = W.env
        local targeting = P.targeting
        env.context = targeting and targeting.context and (try(targeting.context) or "solo") or "solo"
        env.solo = env.context == "solo"
        local sense = P.sense
        env.pvp = env.context == "pvp" or tg.player
            or (sense and sense.pvp_active and try(sense.pvp_active) == true) or false
        env.boss = tg.boss or F.shape == "BOSS"
        env.elite = tg.elite or F.elites > 0

        -- --- hardcore -------------------------------------------------------------------
        -- Asked once a tick, here, because the answer logs its own start and
        -- end and carries the hysteresis (hardcore.lua).
        local hc = P.hardcore
        W.bailout = hc ~= nil and hc.should_stop_fighting ~= nil and hc.should_stop_fighting(s) == true
        -- NOTHING LEFT TO BAIL OUT WITH: no potion, no defensive, no escape.
        -- Standing still while being hit is the worst answer there is, so the
        -- bail-out stops holding the attacks back and the fight goes on.
        W.fight_on = W.bailout and pl.defensives_ready == 0 and pl.escapes_ready == 0
            and not pl.healthstone and not pl.potion

        return W
    end

    return M
end

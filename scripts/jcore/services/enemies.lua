-- JCore / enemies -- every hostile in range, read once per tick, with a memory.
--
-- Depends on: util, log, events, cache, units, combat.
--
-- WHAT THE UNIT CACHE CANNOT SAY
-- The sweep answers "what is there" for one tick and forgets. Almost every
-- question a plugin has about an enemy is about CHANGE: is it coming towards
-- me, is it running away, did it just start casting, did it just switch to
-- my pet, how long until it reaches me. None of those is readable from a
-- single frame, so each plugin that wanted one kept its own per-guid history
-- and asked the same natives again. This service keeps one history per
-- hostile and answers the questions from it.
--
-- WHAT A ROW HOLDS
-- Position and distance every tick (free, from the sweep), a short trail of
-- positions for velocity, and the detailed state -- cast, target, threat,
-- loss of control, health -- read on a budget: the nearest few enemies get a
-- fresh read every tick, the rest hold their last one. A boar sixty yards
-- away is not worth eight native calls a frame.
--
-- ACTIVITY
-- The one-word answer to "what is it doing", derived from the rest:
--
--   dead         it died this tick (the row is gone next tick)
--   controlled   stunned, feared, rooted, or otherwise not in charge of itself
--   casting      a cast or channel in progress
--   fleeing      engaged with us and moving away
--   attacking    engaged with us: targeting me or my pet, or holding threat
--   approaching  not engaged, but closing on me
--   patrolling   moving, not towards me
--   idle         standing still, not engaged
--
-- EVENTS, ON TRANSITION ONLY
--   jcore.enemy.engaged      it turned on me or my pet            (row)
--   jcore.enemy.approaching  a hostile that is not engaged is closing (row)
--   jcore.enemy.casting      a cast or channel started            (row, cast)
--   jcore.enemy.fleeing      an engaged enemy started running     (row)
--   jcore.enemy.controlled   it lost control of itself            (row)
--   jcore.enemy.died         it died                              (guid, row)
--
-- A row handed out or carried on an event is LIVE: it is the same table the
-- next tick rewrites. Read it, do not keep it.
--
-- WHAT FOREVER'S CLIENT DOES NOT SAY (1.6.4), answered here on Forever only,
-- decided once from world.client(); Era reads exactly what it always read:
--
--   damage on us     the combat log arrives with no arguments, so nothing
--                    names who hit us. Our own and the pet's health say how
--                    much; the mobs targeting each at that moment are who,
--                    split by what each has done so far. damage_rate(guid).
--   crowd control    loss of control is the player's own on the retail
--                    engine and reads "not valid" for every mob. The mob's
--                    debuffs say it instead: a polymorph, a trap, a fear by
--                    name, with whether damage breaks it (row.control.breaks).
--   the damage meter the combat log there is Blizzard's 12.0 locked kind: the
--                    event fires, its contents are secret to addon code (Details
--                    and BetterForeverChat say the same). What Blizzard offers
--                    instead is its own damage meter, which the loader wraps as
--                    core.damage_meter. 1.6.6 asks it once a session and, in
--                    combat, every two seconds, and says what it answered
--                    (meter_summary): totals only -- damage taken by us, damage
--                    taken by each enemy -- never who hit whom.
--   threat           get_threat_situation has only ever answered zeros there.
--                    A mob hitting us that the client says we hold nothing on
--                    is the proof: after DEAD_VOTES such reads with none ever
--                    saying more, threat is unread (nil), not a fake 0% that
--                    reads as "safe to pull the pet off", and is not asked again.

-- Crowd control by the debuff's name: what kind, and whether damage ends it.
local CC_KIND = {
    ["Polymorph"] = "incapacitate", ["Polymorph: Pig"] = "incapacitate", ["Polymorph: Turtle"] = "incapacitate",
    ["Sap"] = "incapacitate", ["Gouge"] = "incapacitate", ["Blind"] = "incapacitate",
    ["Freezing Trap"] = "incapacitate", ["Freezing Trap Effect"] = "incapacitate",
    ["Wyvern Sting"] = "incapacitate", ["Scatter Shot"] = "incapacitate", ["Hibernate"] = "incapacitate",
    ["Seduction"] = "incapacitate", ["Repentance"] = "incapacitate", ["Shackle Undead"] = "incapacitate",
    ["Sleep"] = "incapacitate", ["Hex"] = "incapacitate", ["Banish"] = "incapacitate",
    ["Fear"] = "fear", ["Howl of Terror"] = "fear", ["Psychic Scream"] = "fear",
    ["Intimidating Shout"] = "fear", ["Scare Beast"] = "fear", ["Turn Undead"] = "fear",
    ["Turn Evil"] = "fear", ["Terrify"] = "fear",
    ["Hammer of Justice"] = "stun", ["Kidney Shot"] = "stun", ["Cheap Shot"] = "stun", ["Bash"] = "stun",
    ["Intimidation"] = "stun", ["Concussion Blow"] = "stun", ["War Stomp"] = "stun", ["Charge Stun"] = "stun",
    ["Intercept Stun"] = "stun", ["Pounce"] = "stun", ["Impact"] = "stun", ["Blackout"] = "stun",
    ["Mace Stun Effect"] = "stun", ["Revenge Stun"] = "stun", ["Stun"] = "stun",
    ["Frost Nova"] = "root", ["Entangling Roots"] = "root", ["Improved Wing Clip"] = "root",
    ["Entrapment"] = "root", ["Frostbite"] = "root", ["Improved Hamstring"] = "root",
}
local CC_BREAKS = { incapacitate = true, fear = true, stun = false, root = false }

local DEAD_VOTES = 6         -- reads of a mob on us that say we hold nothing, before threat is called dead
-- The damage meter's session and meter types (Enum.DamageMeterSessionType,
-- Enum.DamageMeterType): Current = 1; DamageTaken = 7, AvoidableDamageTaken = 8,
-- and 9, 10 for whichever of Deaths and EnemyDamageTaken this client numbers so.
local METER_CURRENT = 1
local METER_TYPES = { 7, 9, 10 }
local METER_EVERY = 2.0
local TAKEN_KEEP = 6.0       -- seconds without a hit before a mob's damage rate is forgotten
local TAKEN_SWING = 2.0      -- a swing, for the rate of the first hits

return function(rt)
    local util = rt.util
    local events = rt.events
    local cache = rt.cache
    local units = rt.units
    local combat = rt.combat
    local log = rt.log.for_tag("JCore/enemies")

    local try = cache.try
    local sqrt = math.sqrt
    local huge = math.huge

    local M = {}

    -- What the client can say, decided once: rt.world is built after this
    -- service, so the first poll asks. A runtime without it is a classic one.
    local caps = nil
    local function client_caps()
        if caps then return caps end
        local world = rt.world
        if not (world and world.client) then return nil end
        local ok, c = pcall(world.client)
        if not ok or type(c) ~= "table" then return nil end
        caps = { forever = c.forever == true, combat_log = c.combat_log ~= false }
        return caps
    end
    local function on_forever()
        local c = client_caps()
        return c ~= nil and c.forever
    end

    M.ACTIVITIES = {
        "idle", "patrolling", "approaching", "attacking", "casting",
        "fleeing", "controlled", "dead",
    }

    -- --- tuning -------------------------------------------------------------

    -- Full reads per tick. The nearest enemies get them; the rest keep their
    -- last answer until their turn comes round.
    local detail_budget = 12
    -- Beyond this an enemy is position-only however much budget is left.
    local detail_range = 60.0
    -- A far enemy's stale detail is refreshed at least this often.
    local STALE_AFTER = 1.5

    local THREAT_EVERY = 0.5     -- threat is a slow-moving number
    local CONTROL_EVERY = 0.25   -- loss of control matters within a GCD

    local SAMPLE_EVERY = 0.15    -- position trail cadence
    local TRAIL = 8              -- samples kept: ~1.2s of motion
    local MIN_TRAIL_SPAN = 0.4   -- seconds before a velocity is believed

    local APPROACH_RANGE = 45.0  -- closing beyond this is not "approaching" yet
    local CLOSING_SPEED = 1.0    -- yards per second, either way, to count as moving relative to me
    local MELEE_REACH = 5.0      -- "reached me" for time_to_reach

    ---@param n integer
    function M.set_detail_budget(n) detail_budget = math.max(1, n or 12) end
    ---@param yards number
    function M.set_detail_range(yards) detail_range = math.max(10, yards or 60) end

    -- --- state --------------------------------------------------------------

    local rows = {}         -- guid -> row
    local ordered = {}      -- this tick's rows, nearest first
    local count = 0
    local last_poll = 0
    local reads_this_tick = 0

    local stats = { rows = 0, detailed = 0, events = 0 }

    local function new_row(guid, unit)
        local now = core.time()
        return {
            guid = guid,
            obj = unit,
            first_seen = now,
            last_seen = now,

            x = 0, y = 0, z = 0, dist = huge,

            -- motion
            speed = 0,               -- yards per second over the trail
            closing = 0,             -- yards per second towards me (negative: away)
            time_to_reach = huge,    -- seconds until melee reach at the current closing speed
            moving = false,
            trail_t = {}, trail_x = {}, trail_y = {}, trail_d = {},
            trail_n = 0, trail_head = 0, sampled_at = 0,

            -- status, from the last detailed read
            detailed_at = 0,
            hp = 1,
            ttd = huge,
            in_combat = false,
            casting = nil,
            target_guid = nil,
            targeting_me = false,
            targeting_pet = false,
            engaged = false,
            threat = nil,
            threat_at = 0,
            control = nil,
            control_at = 0,

            activity = "idle",
            activity_since = now,
            -- transition memory
            was_engaged = false,
            last_cast_key = nil,
            approach_announced_at = 0,
        }
    end

    -- --- motion -------------------------------------------------------------

    local function push_sample(row, now)
        local head = (row.trail_head % TRAIL) + 1
        row.trail_head = head
        row.trail_t[head] = now
        row.trail_x[head] = row.x
        row.trail_y[head] = row.y
        row.trail_d[head] = row.dist
        if row.trail_n < TRAIL then row.trail_n = row.trail_n + 1 end
        row.sampled_at = now
    end

    local function oldest_index(row)
        if row.trail_n < TRAIL then return 1 end
        return (row.trail_head % TRAIL) + 1
    end

    local function update_motion(row, now)
        if (now - row.sampled_at) >= SAMPLE_EVERY then push_sample(row, now) end
        if row.trail_n < 2 then return end

        local o = oldest_index(row)
        local h = row.trail_head
        local span = row.trail_t[h] - row.trail_t[o]
        if span < MIN_TRAIL_SPAN then return end

        local dx, dy = row.trail_x[h] - row.trail_x[o], row.trail_y[h] - row.trail_y[o]
        row.speed = sqrt(dx * dx + dy * dy) / span
        -- Distance change is measured against ME, so a mob that is not moving
        -- while I run at it reads as closing. That is the right frame: what
        -- matters is when we meet, not who is doing the walking.
        row.closing = (row.trail_d[o] - row.trail_d[h]) / span
        row.moving = row.speed > CLOSING_SPEED

        if row.closing > CLOSING_SPEED and row.dist > MELEE_REACH then
            row.time_to_reach = (row.dist - MELEE_REACH) / row.closing
        elseif row.dist <= MELEE_REACH then
            row.time_to_reach = 0
        else
            row.time_to_reach = huge
        end
    end

    -- --- threat, whichever way round the client means it ----------------------
    --
    -- The contract describes get_threat_situation as "the threat situation
    -- from the game_object to another game_object", which reads as
    -- holder:get_threat_situation(mob) -- UnitDetailedThreatSituation(holder,
    -- mob). Every caller here was written the other way round,
    -- mob:get_threat_situation(holder), and nothing offline can say which the
    -- client means: the wrong one answers zeros, or nothing, and a threat
    -- reading that is always zero looks exactly like "no threat yet".
    --
    -- So the client settles it. Until it has, both ways are asked and the
    -- answer that says more is used. A read where the mob is targeting the
    -- holder is a test: the right way round says that holder holds it. The
    -- way that says so when the other does not gets a vote, and VOTES_NEEDED
    -- with none against fixes the order for the session -- one native per
    -- read from then on.

    local VOTES_NEEDED = 3
    local order = nil                    -- nil, "holder" or "mob"
    local votes = { holder = 0, mob = 0 }
    -- Forever: is threat read at all? live once any read says more than
    -- nothing; dead after DEAD_VOTES reads of a mob on its holder saying nothing.
    local threat = { live = false, dead = false, votes = 0 }

    local function holds(t)
        return type(t) == "table"
            and ((t.status or 0) >= 2 or (t.threat_percent or 0) >= 100)
    end

    local function says(t)
        if type(t) ~= "table" then return -1 end
        return (t.status or 0) * 1000 + (t.threat_percent or 0)
    end

    --- The client's threat table entry for `holder` on `mob`, asked the way
    --- round the client answers.
    ---@param mob game_object
    ---@param holder game_object The player, a party member, a pet.
    ---@param targeted? boolean The mob is targeting this holder right now.
    ---@return table|nil situation { is_tanking, status, threat_percent }
    ---@return integer natives What the answer cost: 1 once the order is settled, 2 before.
    local function judge_threat(a, b, targeted)
        if threat.live or not on_forever() then return end
        if says(a) > 0 or says(b) > 0 then
            threat.live = true
            return
        end
        if not targeted then return end
        threat.votes = threat.votes + 1
        if threat.votes >= DEAD_VOTES then
            threat.dead = true
            local text = string.format("threat: the client answered nothing on %d reads of a mob hitting its holder; threat is unread on this client", threat.votes)
            log.info(text)
            pcall(events.emit, "jcore.recorder.trace", text)
        end
    end

    function M.situation(mob, holder, targeted)
        if not mob or not holder then return nil, 0 end
        -- Forever, proven dead: unread, and never asked again.
        if threat.dead then return nil, 0 end
        if order == "holder" then
            local s = try(holder.get_threat_situation, holder, mob)
            judge_threat(s, nil, targeted)
            if threat.dead then return nil, 1 end
            return s, 1
        end
        if order == "mob" then
            local s = try(mob.get_threat_situation, mob, holder)
            judge_threat(s, nil, targeted)
            if threat.dead then return nil, 1 end
            return s, 1
        end

        local a = try(holder.get_threat_situation, holder, mob)
        local b = try(mob.get_threat_situation, mob, holder)
        judge_threat(a, b, targeted)
        if threat.dead then return nil, 2 end
        if targeted then
            local ha, hb = holds(a), holds(b)
            if ha and not hb then
                votes.holder = votes.holder + 1
            elseif hb and not ha then
                votes.mob = votes.mob + 1
            end
            if votes.holder >= VOTES_NEEDED and votes.mob == 0 then
                order = "holder"
                log.info("threat is read holder:get_threat_situation(mob)")
            elseif votes.mob >= VOTES_NEEDED and votes.holder == 0 then
                order = "mob"
                log.info("threat is read mob:get_threat_situation(holder)")
            end
        end
        if says(a) >= says(b) then return a, 2 end
        return b, 2
    end

    --- Which way round threat is read: "holder", "mob", or nil while both
    --- are still being asked; and the votes so far.
    ---@return string|nil order
    ---@return integer holder_votes
    ---@return integer mob_votes
    function M.threat_order() return order, votes.holder, votes.mob end

    --- Does the client answer threat? true once a read has said something,
    --- false once Forever's zeros are proven (threat is then unread), nil
    --- while it is not known -- and always nil on a classic client.
    ---@return boolean|nil
    function M.threat_readable()
        if threat.live then return true end
        if threat.dead then return false end
        return nil
    end


    -- --- detail -------------------------------------------------------------

    local my_guid, my_pet_guid = nil, nil

    -- --- Forever: crowd control from the mob's debuffs -------------------------

    --- The strongest crowd control in a unit's debuffs: a breakable one first.
    local function control_from_debuffs(unit)
        local list = try(unit.get_debuffs, unit)
        if type(list) ~= "table" then return nil end
        local best = nil
        for _, d in pairs(list) do
            local name = type(d) == "table" and d.buff_name or nil
            local kind = name and CC_KIND[name]
            if kind and (not best or (CC_BREAKS[kind] and not best.breaks)) then
                local exp = tonumber(d.expire_time) or 0
                best = {
                    spell_id = d.buff_id, type = nil, kind = kind, breaks = CC_BREAKS[kind],
                    name = name, from = "debuff",
                    remaining = exp > 0 and math.max(0, (exp - core.game_time()) / 1000.0) or 0,
                }
            end
        end
        return best
    end

    -- --- Forever: who hit us, from our own health -------------------------------

    local taken = {}             -- source guid -> { first, last, total }
    local hp_last = { me = nil, pet = nil, me_guid = nil, pet_guid = nil }
    local taken_pruned = 0

    local function rate_of(guid, now)
        local t = guid and taken[guid]
        if not t or (now - t.last) > TAKEN_KEEP then return nil end
        return t.total / ((now - t.first) + TAKEN_SWING)
    end

    local function add_taken(guid, amount, now)
        local t = taken[guid]
        if not t or (now - t.last) > TAKEN_KEEP then
            t = { first = now, last = now, total = 0 }
            taken[guid] = t
        elseif (now - t.first) > 12 then
            t.total = t.total * 0.5
            t.first = now - (now - t.first) * 0.5
        end
        t.total = t.total + amount
        t.last = now
    end

    --- A drop in the health of who (us or the pet) since the last poll, shared among the rows
    --- attacking it: by what each has done so far, a newcomer as much as the
    --- average of the others.
    local function attribute(who, unit, guid, attackers, n, now)
        local hp = unit and units.health and units.health(unit) or nil
        local last, last_guid = hp_last[who], hp_last[who .. "_guid"]
        hp_last[who], hp_last[who .. "_guid"] = hp, guid
        if type(hp) ~= "number" or type(last) ~= "number" or last_guid ~= guid then return end
        local drop = last - hp
        if drop <= 0 or n == 0 then return end
        local known, sum = 0, 0
        for i = 1, n do
            local r = rate_of(attackers[i].guid, now)
            if r then known, sum = known + 1, sum + r end
        end
        local fallback = known > 0 and (sum / known) or 1
        local weights, total = {}, 0
        for i = 1, n do
            local w = rate_of(attackers[i].guid, now) or fallback
            if w <= 0 then w = fallback end
            weights[i] = w
            total = total + w
        end
        for i = 1, n do
            add_taken(attackers[i].guid, drop * weights[i] / total, now)
        end
    end

    local on_me, on_pet = {}, {}

    local function attribute_damage(player, pet, now)
        local nm, np = 0, 0
        for i = 1, count do
            local row = ordered[i]
            if row.targeting_me then
                nm = nm + 1
                on_me[nm] = row
            elseif row.targeting_pet then
                np = np + 1
                on_pet[np] = row
            end
        end
        for i = nm + 1, #on_me do on_me[i] = nil end
        for i = np + 1, #on_pet do on_pet[i] = nil end
        attribute("me", player, my_guid, on_me, nm, now)
        if pet and my_pet_guid then
            attribute("pet", pet, my_pet_guid, on_pet, np, now)
        else
            hp_last.pet, hp_last.pet_guid = nil, nil
        end
        if (now - taken_pruned) > 5 then
            taken_pruned = now
            for guid, t in pairs(taken) do
                if (now - t.last) > 30 then taken[guid] = nil end
            end
        end
    end

    -- --- Forever: Blizzard's damage meter, asked --------------------------------

    local meter = { asked = false, available = nil, reason = nil, at = -huge, by_type = {}, verdict = nil }

    local function meter_trace(text)
        log.info(text)
        pcall(events.emit, "jcore.recorder.trace", text)
    end

    --- What one session read says: how many sources, and whether the first
    --- one's amount is a number we can use.
    local function judge_session(s)
        if type(s) ~= "table" then return "nothing", 0 end
        local sources = s.sources
        if type(sources) ~= "table" then return "no sources", 0 end
        local n = #sources
        if n == 0 then return "empty", 0 end
        local first = sources[1]
        local amount = type(first) == "table" and first.total_amount or nil
        if type(amount) == "number" then return "answers", n end
        return "hidden (amount reads " .. type(amount) .. ")", n
    end

    local function probe_meter(now, in_combat)
        local dm = core.damage_meter
        if not meter.asked then
            meter.asked = true
            if type(dm) ~= "table" or type(dm.is_available) ~= "function" then
                meter.available, meter.reason = false, "no core.damage_meter"
            else
                local ok, avail, why = pcall(dm.is_available)
                meter.available = ok and avail == true
                meter.reason = ok and tostring(why or "") or ("raised: " .. tostring(avail))
            end
            meter_trace(string.format("damage meter: available=%s%s", tostring(meter.available),
                (meter.reason and meter.reason ~= "") and (" (" .. meter.reason .. ")") or ""))
        end
        if not meter.available or not in_combat or (now - meter.at) < METER_EVERY then return end
        meter.at = now
        local best = nil
        for i = 1, #METER_TYPES do
            local t = METER_TYPES[i]
            local ok, s = pcall(dm.get_session_from_type, METER_CURRENT, t)
            local verdict, n
            if ok then verdict, n = judge_session(s) else verdict, n = "raised", 0 end
            local was = meter.by_type[t]
            if not was or was.verdict ~= verdict then
                meter_trace(string.format("damage meter: type %d in combat: %s, %d source(s)", t, verdict, n))
            end
            meter.by_type[t] = { verdict = verdict, n = n, at = now }
            if verdict == "answers" then best = "answers in combat" end
        end
        meter.verdict = best or "nothing usable in combat"
    end

    --- One line on what Blizzard's damage meter answered on this client:
    --- nil before it was asked (and always on a client with a combat log).
    ---@return string|nil
    function M.meter_summary()
        if not meter.asked then return nil end
        if not meter.available then
            return "damage meter unavailable" .. ((meter.reason and meter.reason ~= "") and (" (" .. meter.reason .. ")") or "")
        end
        return "damage meter " .. (meter.verdict or "not read in a fight yet")
    end

    --- The meter's last read by type, for the tests and the dump.
    function M.meter_state() return meter end

    --- Damage per second this unit has been doing to us or the pet, where the
    --- client has no combat log to say it (Forever): from our own and the
    --- pet's health, shared among whoever was attacking each. nil on a client
    --- with a combat log (read that instead), and for a mob that has not hit.
    ---@param guid string
    ---@return number|nil
    function M.damage_rate(guid)
        local c = client_caps()
        if not c or c.combat_log then return nil end
        return rate_of(guid, core.time())
    end

    local function read_detail(row, unit, now)
        reads_this_tick = reads_this_tick + 1
        row.detailed_at = now

        row.in_combat = try(unit.is_in_combat, unit) == true
        row.hp = units.health_fraction(unit)
        row.ttd = combat.time_to_die(unit)

        -- cast or channel
        local cast = nil
        if try(unit.is_casting_spell, unit) == true then
            cast = {
                spell_id = try(unit.get_active_spell_id, unit),
                channel = false,
                start_at = try(unit.get_active_spell_cast_start_time, unit),
                end_at = try(unit.get_active_spell_cast_end_time, unit),
                interruptible = try(unit.is_active_spell_interruptable, unit) == true,
            }
        elseif try(unit.is_channelling_spell, unit) == true then
            cast = {
                spell_id = try(unit.get_active_channel_spell_id, unit),
                channel = true,
                start_at = try(unit.get_active_channel_cast_start_time, unit),
                end_at = try(unit.get_active_channel_cast_end_time, unit),
                interruptible = true,
            }
        end
        if cast then
            -- Cast times are engine milliseconds, the game_time base.
            local end_ms = type(cast.end_at) == "number" and cast.end_at or 0
            cast.remaining = end_ms > 0 and math.max(0, (end_ms - core.game_time()) / 1000.0) or 0
        end
        row.casting = cast

        -- target
        local target = try(unit.get_target, unit)
        local target_guid = nil
        if target and target:is_valid() then target_guid = try(target.get_guid, target) end
        row.target_guid = target_guid
        row.targeting_me = target_guid ~= nil and target_guid == my_guid
        row.targeting_pet = target_guid ~= nil and my_pet_guid ~= nil and target_guid == my_pet_guid

        -- threat, slowly
        if (now - row.threat_at) >= THREAT_EVERY then
            row.threat_at = now
            local player = units.player()
            local t = player and M.situation(unit, player, row.targeting_me) or nil
            if type(t) == "table" then
                row.threat = {
                    tanking = t.is_tanking == true,
                    status = t.status or 0,
                    percent = t.threat_percent or 0,
                }
            else
                row.threat = nil
            end
        end

        -- loss of control
        if (now - row.control_at) >= CONTROL_EVERY then
            row.control_at = now
            local loc = try(unit.get_loss_of_control_info, unit)
            if type(loc) == "table" and loc.valid then
                local end_ms = type(loc.end_time) == "number" and loc.end_time or 0
                row.control = {
                    spell_id = loc.spell_id,
                    type = loc.type,
                    remaining = end_ms > 0 and math.max(0, (end_ms - core.game_time()) / 1000.0) or 0,
                }
            elseif row.in_combat and on_forever() then
                -- Forever: the mob's debuffs, since its loss of control never says.
                row.control = control_from_debuffs(unit)
            else
                row.control = nil
            end
        end

        row.engaged = row.targeting_me or row.targeting_pet
            or (row.in_combat and row.threat ~= nil and (row.threat.percent or 0) > 0)
    end

    -- --- activity and events ------------------------------------------------

    local function classify(row)
        if row.control then return "controlled" end
        if row.casting then return "casting" end
        if row.engaged then
            if row.closing < -CLOSING_SPEED and row.dist > MELEE_REACH then return "fleeing" end
            return "attacking"
        end
        if row.closing > CLOSING_SPEED and row.dist <= APPROACH_RANGE then return "approaching" end
        if row.moving then return "patrolling" end
        return "idle"
    end

    local function emit(name, ...)
        stats.events = stats.events + 1
        events.emit(name, ...)
    end

    local function transitions(row, now)
        if row.engaged and not row.was_engaged then
            emit("jcore.enemy.engaged", row)
        end
        row.was_engaged = row.engaged

        local cast = row.casting
        local cast_key = cast and ((cast.spell_id or 0) .. ":" .. tostring(cast.start_at)) or nil
        if cast_key and cast_key ~= row.last_cast_key then
            emit("jcore.enemy.casting", row, cast)
        end
        row.last_cast_key = cast_key

        local activity = classify(row)
        if activity ~= row.activity then
            local previous = row.activity
            row.activity = activity
            row.activity_since = now
            if activity == "fleeing" then
                emit("jcore.enemy.fleeing", row)
            elseif activity == "controlled" then
                emit("jcore.enemy.controlled", row)
            elseif activity == "approaching" and not row.engaged then
                -- Once per approach, not once per wobble in the closing
                -- speed: a mob that pauses and resumes is the same approach.
                if (now - row.approach_announced_at) > 3.0 then
                    row.approach_announced_at = now
                    emit("jcore.enemy.approaching", row)
                end
            end
            log.fmt("trace", "%s: %s -> %s", units.name(row.obj), previous, activity)
        end
    end

    -- --- the poll -----------------------------------------------------------

    local candidates = {}

    function M._poll()
        local now = core.time()
        last_poll = now
        reads_this_tick = 0

        local player = units.player()
        if not player then
            rows, ordered, count = {}, {}, 0
            return
        end

        my_guid = units.guid(player)
        local pet = units.player_pet()
        my_pet_guid = (pet and pet:is_valid()) and try(pet.get_guid, pet) or nil

        local list = units.enemies()
        local seen = {}
        local n = 0
        for i = #candidates, 1, -1 do candidates[i] = nil end

        for i = 1, #list do
            local unit = list[i]
            local snap = units.snapshot(unit)
            local guid = snap and snap.guid
            if guid then
                local row = rows[guid]
                if not row then
                    row = new_row(guid, unit)
                    rows[guid] = row
                end
                row.obj = unit
                row.last_seen = now
                row.x, row.y, row.z, row.dist = snap.x, snap.y, snap.z, snap.dist
                update_motion(row, now)
                seen[guid] = true
                n = n + 1
                candidates[n] = row
            end
        end

        -- Nearest first. This is the order the detail budget spends in and
        -- the order all() hands out.
        table.sort(candidates, function(a, b) return a.dist < b.dist end)

        local budget = detail_budget
        for i = 1, n do
            local row = candidates[i]
            local wants = budget > 0 and row.dist <= detail_range
            -- A far or over-budget row still gets a slow refresh, so its
            -- state is stale by a second, not by a fight.
            if not wants and (now - row.detailed_at) >= STALE_AFTER and budget > 0 then
                wants = true
            end
            if wants then
                budget = budget - 1
                read_detail(row, row.obj, now)
            end
            transitions(row, now)
        end

        -- Rows that left the list: dead, or out of range. Dead is the one
        -- worth announcing; the sweep already announces removal.
        for guid, row in pairs(rows) do
            if not seen[guid] then
                local unit = units.by_guid(guid)
                if unit and try(unit.is_dead, unit) == true then
                    row.activity = "dead"
                    emit("jcore.enemy.died", guid, row)
                end
                rows[guid] = nil
            end
        end

        ordered = candidates
        count = n
        stats.rows = n
        stats.detailed = reads_this_tick

        -- Forever: who hit us, from our own health (no combat log there), and
        -- what Blizzard's own damage meter will say.
        local c = client_caps()
        if c and not c.combat_log then
            attribute_damage(player, pet, now)
            probe_meter(now, combat.in_combat and combat.in_combat() == true)
        end
    end

    -- --- queries ------------------------------------------------------------

    --- Every hostile in range this tick, nearest first. The array is rebuilt
    --- in place each poll: read it now, never hold it.
    ---@return table[] rows
    function M.all() return ordered end

    ---@return integer
    function M.count() return count end

    --- The row for a unit or a guid, or nil when it is not a tracked hostile.
    ---@param unit_or_guid game_object|string
    ---@return table|nil
    function M.get(unit_or_guid)
        if type(unit_or_guid) == "string" then return rows[unit_or_guid] end
        local guid = units.guid(unit_or_guid)
        return guid and rows[guid] or nil
    end

    --- Rows matching a predicate, nearest first. Allocates; prefer the
    --- specific queries below in a hot path.
    ---@param predicate fun(row: table): boolean
    ---@return table[]
    function M.where(predicate)
        local out = {}
        for i = 1, count do
            local row = ordered[i]
            if predicate(row) then out[#out + 1] = row end
        end
        return out
    end

    --- Enemies engaged with me or my pet.
    function M.engaged()
        return M.where(function(r) return r.engaged end)
    end

    --- Hostiles closing on me that have not engaged yet -- the patrol that is
    --- about to be part of this fight.
    function M.inbound()
        return M.where(function(r) return r.activity == "approaching" end)
    end

    function M.casting()
        return M.where(function(r) return r.casting ~= nil end)
    end

    function M.targeting_me()
        return M.where(function(r) return r.targeting_me end)
    end

    function M.fleeing()
        return M.where(function(r) return r.activity == "fleeing" end)
    end

    --- The cast that finishes soonest, optionally only interruptible ones.
    ---@param interruptible_only? boolean
    ---@return table|nil row
    ---@return table|nil cast
    function M.next_cast(interruptible_only)
        local best, best_cast, best_remaining = nil, nil, huge
        for i = 1, count do
            local row = ordered[i]
            local cast = row.casting
            if cast and (not interruptible_only or cast.interruptible) then
                if (cast.remaining or huge) < best_remaining then
                    best, best_cast, best_remaining = row, cast, cast.remaining
                end
            end
        end
        return best, best_cast
    end

    --- How many rows are in each activity this tick.
    ---@return table<string, integer>
    function M.count_by_activity()
        local out = {}
        for i = 1, #M.ACTIVITIES do out[M.ACTIVITIES[i]] = 0 end
        for i = 1, count do
            local a = ordered[i].activity
            out[a] = (out[a] or 0) + 1
        end
        return out
    end

    --- Seconds until a unit reaches melee at its current closing speed,
    --- math.huge when it is not closing.
    ---@param unit game_object
    ---@return number
    function M.time_to_reach(unit)
        local row = M.get(unit)
        return row and row.time_to_reach or huge
    end

    --- The nearest row passing a predicate, or the nearest of all.
    ---@param predicate? fun(row: table): boolean
    ---@return table|nil
    function M.nearest(predicate)
        for i = 1, count do
            local row = ordered[i]
            if not predicate or predicate(row) then return row end
        end
        return nil
    end

    --- The soonest arrival among everything approaching or engaged and not
    --- yet in reach. What a "brace for it" decision wants.
    ---@return table|nil row
    ---@return number seconds
    function M.first_arrival()
        local best, best_t = nil, huge
        for i = 1, count do
            local row = ordered[i]
            if row.time_to_reach < best_t and row.time_to_reach > 0 then
                best, best_t = row, row.time_to_reach
            end
        end
        return best, best_t
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local by = M.count_by_activity()
        return {
            rows = stats.rows,
            detailed = stats.detailed,
            budget = detail_budget,
            events = stats.events,
            age = core.time() - last_poll,
            threat_order = order,
            threat_readable = M.threat_readable(),
            attacking = by.attacking,
            approaching = by.approaching,
            casting = by.casting,
            fleeing = by.fleeing,
            controlled = by.controlled,
        }
    end

    return M
end

-- Jambix AIO / pet -- deciding what the pet should be standing on.
--
-- THE CONCEPT
--
-- A pet has exactly one job at a time and the interesting question is never
-- "attack or not", it is WHICH unit. Three answers are useful and they are
-- genuinely different intents, so they are a mode rather than a pile of
-- toggles:
--
--   ASSIST     Follow my target. What a damage pet does: whatever I am
--              killing, it is killing. Growl OFF in a group, because a pet
--              taunting off a tank is worse than the damage it adds -- and
--              ON when solo, because then nobody else is holding anything
--              and a pet that cannot hold the mob walks it straight to you.
--
--   TANK       Hold what nobody else is holding. The pet goes to the loose
--              mob, not to my target -- the whole point is that my target is
--              already handled and something else is not. Growl ON.
--
--   FOCUS      Stay on one designated unit and ignore everything, including
--              my target changing. For a pet parked on a caster or a runner
--              while the player kills something else.
--
-- WHY IT NEEDS ARBITRATION
-- pet_attack is a command, not a request, and issuing one every frame makes
-- the pet stutter in place instead of attacking: each order restarts its
-- approach. So a designation is held until the reason for it changes, and
-- re-issued only on a real change or after a long refresh.
--
-- AGGRO, AUTHORITATIVELY
-- "Loose" comes from get_threat_situation, the client's own threat table, the
-- same source the tank logic uses. A pet sent at something already held is a
-- pet wasted.
--
-- THE TAUNT IS AIMED (1.68.0)
-- Growl's autocast fires at the pet's own target, so while the reaction
-- engine runs it takes Growl (or Torment) off autocast and presses it at the
-- mob that needs it (react/petthreat.lua). Autocast comes back the moment
-- the engine lets go.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat
    local book, targeting = P.spellbook, P.targeting

    local M = {}

    M.OFF, M.ASSIST, M.TANK, M.FOCUS = 1, 2, 3, 4

    -- --- pet spellbook ------------------------------------------------------
    --
    -- A PET SPELL IS NOT A PLAYER SPELL. core.spell_book.get_spells() returns
    -- the player's book, so asking it for "Growl" or "Spell Lock" answers nil
    -- however long the pet has been out -- and every pet ability would then
    -- silently do nothing, with no error to notice.
    --
    -- The pet has its own book. get_pet_spells lists its action ids and
    -- get_pet_action_info resolves each to a name, which is the same
    -- resolve-by-name approach the player spellbook uses and for the same
    -- reason: no hard-coded ids that rot across ranks and game versions.

    local pet_by_name = {}
    local pet_spell_count = 0
    local last_pet_scan = 0
    -- The pet's stance as its bar shows it: the active stance button's token
    -- ("PET_MODE_AGGRESSIVE", ...), or nil where the bar says nothing (1.74.1).
    local pet_stance = nil

    local function refresh_pet_spells()
        local ok, spells = pcall(core.spell_book.get_pet_spells)
        if not ok or type(spells) ~= "table" then
            pet_by_name, pet_spell_count = {}, 0
            return
        end

        local fresh, seen, n = {}, {}, 0
        local stance_seen = nil

        local function consider(id)
            if type(id) ~= "number" or id <= 0 or seen[id] then return end
            seen[id] = true
            local ok_info, info = pcall(core.spell_book.get_pet_action_info, id)
            if not ok_info or type(info) ~= "table" then return end
            if type(info.name) ~= "string" or info.name == "" then return end
            -- Token actions are the stance buttons (Attack, Follow, Passive),
            -- not castable abilities. The active one is the pet's stance.
            if info.is_token then
                if info.is_active and info.name:find("^PET_MODE_") then stance_seen = info.name end
                return
            end
            local key = info.name:lower()
            if not fresh[key] or id > fresh[key] then
                if not fresh[key] then n = n + 1 end
                fresh[key] = id
            end
        end

        for k, v in pairs(spells) do
            consider(k)
            consider(v)
        end

        pet_by_name, pet_spell_count = fresh, n
        pet_stance = stance_seen
        last_pet_scan = core.time()
    end

    ---@param name string
    ---@return integer|nil
    function M.spell_id(name)
        return pet_by_name[name:lower()]
    end

    ---@param name string
    ---@return boolean
    function M.knows(name)
        return M.spell_id(name) ~= nil
    end

    -- SPELLS_CHANGED fires when a pet is summoned or dismissed as well.
    ctx.on("jambix.aio.spells_changed", refresh_pet_spells)
    ctx.every(3.0, refresh_pet_spells)
    refresh_pet_spells()

    -- Currently designated unit, and why.
    local designated_guid = nil
    local designated_reason = nil
    local designated_at = 0
    local last_command = 0
    local focus_guid = nil
    -- Mobs the pet is kept off for a while (an evading one): guid -> until.
    local shunned = {}

    -- Re-issue the same order at most this often. Long, because re-ordering a
    -- pet interrupts its approach.
    local REFRESH_SECONDS = 6

    -- --- pet state ----------------------------------------------------------

    ---@return game_object|nil
    function M.pet()
        local player = units.player()
        if not player then return nil end
        local ok, pet
        if units.player_pet then
            -- JCore's answer, per client: get_pet, and on Forever (where it
            -- answers nil) the pet looked for (units.player_pet, JCore 1.5.14).
            ok, pet = pcall(units.player_pet)
        else
            ok, pet = pcall(player.get_pet, player)
        end
        if not ok or not pet or not pet:is_valid() or pet:is_dead() then return nil end
        return pet
    end

    ---@return boolean
    function M.alive()
        return M.pet() ~= nil
    end

    ---@return number 0..1
    function M.health()
        local pet = M.pet()
        if not pet then return 0 end
        return units.health_fraction(pet)
    end

    ---@return integer
    function M.mode()
        return P.opt("pet_mode", M.ASSIST)
    end

    --- The unit the pet is currently attacking, per the client.
    ---@return game_object|nil
    function M.pet_target()
        local pet = M.pet()
        if not pet then return nil end
        local ok, target = pcall(pet.get_target, pet)
        if not ok or not target or not target:is_valid() then return nil end
        return target
    end

    -- --- designation --------------------------------------------------------

    --- Sends the pet at a unit, unless it is already going there.
    ---
    --- The guid comparison is what stops this from being a command spammed
    --- every tick. `force` is for the periodic refresh, where the pet may have
    --- wandered off the order without the designation changing.
    ---@param unit game_object
    ---@param reason string
    ---@param force? boolean
    ---@return boolean issued
    function M.send(unit, reason, force)
        if not unit or not unit:is_valid() or unit:is_dead() then return false end
        -- Nothing selected: the pet stays with you (1.87.1).
        if M.home() then return false end

        local guid = unit:get_guid()
        local now = core.time()

        -- Kept off it: an evading mob takes nothing and leads the pet home.
        local off_until = shunned[guid]
        if off_until and now < off_until then return false end

        if not force and guid == designated_guid
            and (now - designated_at) < REFRESH_SECONDS then
            return false
        end

        -- A hard floor regardless of reason: two orders in the same second
        -- leaves the pet running between them.
        if (now - last_command) < 0.5 then return false end

        last_command = now
        designated_guid, designated_reason, designated_at = guid, reason, now

        pcall(core.input.pet_attack, unit)

        local ok_name, name = pcall(unit.get_name, unit)
        log.fmt("debug", "pet -> %s (%s)", (ok_name and name) or guid, reason)
        ctx.emit("jambix.aio.pet_designated", { guid = guid, reason = reason })
        return true
    end

    --- Seconds since the pet was sent at this unit, or nil when it was not.
    --- The pull sequencing reads this: the pet goes in first, and the shots
    --- wait for it to arrive -- but not for ever.
    ---@param unit game_object|nil
    ---@return number|nil
    function M.sent_for(unit)
        if not unit or not designated_guid then return nil end
        local ok, guid = pcall(unit.get_guid, unit)
        if not ok or guid ~= designated_guid then return nil end
        return core.time() - designated_at
    end

    --- The unit the pet was last sent at, and how long ago: the pet's mob for
    --- a client that does not say what the pet is attacking (1.73.1).
    ---@return string|nil guid
    ---@return number|nil seconds
    function M.designated()
        if not designated_guid then return nil, nil end
        return designated_guid, core.time() - designated_at
    end

    --- Pins the pet to one unit until cleared. This is the manual override.
    ---@param unit game_object|nil
    function M.set_focus(unit)
        if not unit then
            focus_guid = nil
            log.info("pet focus cleared")
            return
        end
        focus_guid = unit:get_guid()
        local ok, name = pcall(unit.get_name, unit)
        log.fmt("info", "pet focus: %s", (ok and name) or focus_guid)
    end

    function M.focus()
        return focus_guid and units.by_guid(focus_guid) or nil
    end

    -- --- growl --------------------------------------------------------------
    --
    -- Growl is the whole difference between a damage pet and a tanking one,
    -- and leaving it on in a group is how a hunter pet pulls a mob off the
    -- tank. It is driven from the mode rather than left to the user, because
    -- the mode already states the intent.

    local function growl_name()
        for _, name in ipairs({ "Growl", "Torment", "Suffering" }) do
            if M.knows(name) then return name end
        end
        return nil
    end

    -- --- skills the engine presses itself (1.68.0; any pet skill since 1.71.0) ---
    --
    -- AUTOCAST AIMS AT THE PET'S OWN TARGET, the moment a skill is ready. A
    -- Growl wanted anywhere else -- the add hitting you, the mob you are about
    -- to pull off the pet -- found it on cooldown ("Spell is not ready yet",
    -- every few seconds, until the manual Growl went in 1.35.2). And autocast
    -- spends a skill whether it helps or not: Furious Howl's 60 focus every ten
    -- seconds with nobody within its 15 yards. So a skill the reaction engine
    -- presses (react/petthreat.lua for the taunt, react/rules/pet.lua for the
    -- rest) is off autocast while the engine keeps asking -- a lease of
    -- AIM_LEASE -- and goes back as it was when the engine stops: the rotation
    -- off, mounted, dead, the pet mode Off or Focus, the plugin paused or
    -- unloaded.
    --
    -- NOT ON THE CLIENT'S WORD (1.68.1). The first in-game log had the pet
    -- Growling by itself every five seconds while the engine aimed it: each of
    -- our presses met "Spell is not ready yet", and the mob came back to the
    -- pet a second later anyway. The switch-off had been skipped whenever the
    -- client's autocast flag already read "off". So autocast is switched off
    -- and back on without asking the flag, and the pet's own cast events say
    -- whether it worked: a use of the skill we did not press means autocast is
    -- still on. The first one gets it switched off again; the next means it
    -- will not stay off on this client (or someone is clicking the pet's bar),
    -- and the engine stops pressing that skill: autocast stays on, as before.
    -- Same when our presses keep being refused and no event of the pet's ever
    -- confirmed one -- for a skill off the pet's global cooldown only, since a
    -- refusal inside that cooldown says nothing about autocast.
    local AIMED_TAUNT = { growl = true, torment = true }
    local AIM_LEASE = 1.5              -- seconds one ask from the engine holds autocast off
    local holds = {}                   -- lower-case name -> what the engine holds
    local confirmed_any = false        -- the pet's events ever confirmed a press of ours

    -- What the client's spell tables say each pet skill is (modules/beasts_data.lua,
    -- tools/jcheck/beasts_extract.js): cooldown, global cooldown, cost, range.
    -- The running client's own tables (1.78.2). Until now Era's were read on
    -- Forever too, where Furious Howl is a 30 s cooldown, not 10, and 19
    -- skills are Forever's alone (Dismember, Savage Rend, Sonic Blast, ...).
    local beasts = nil
    do
        local load = P.load or function(path) return require("jambix_aio/" .. path) end
        local ok, data = pcall(load, "modules/beasts_data")
        if ok and type(data) == "table" then beasts = (P.forever and data.forever) or data.vanilla end
    end

    --- A pet skill as the client's tables describe it, or nil.
    ---@param name string
    ---@return table|nil { ranks, cd, gcd, power, cost, min, range, radius }
    function M.skill(name)
        local skills = beasts and beasts.skills
        return skills and type(name) == "string" and skills[name] or nil
    end

    --- The client's tables: { families, skills }, or nil.
    function M.beasts() return beasts end

    local said = {}
    local function say(key, text)
        local now = core.time()
        if said[key] and (now - said[key]) < 60 then return end
        said[key] = now
        log.info(text)
    end

    local function hold_of(key)
        local h = holds[key]
        if not h then
            h = { at = -math.huge, restore = nil, pet = nil, stuck = nil, switched_at = -math.huge,
                  rogue_n = 0, rogue_at = -math.huge, refused_n = 0, refused_at = -math.huge }
            holds[key] = h
        end
        return h
    end

    local function set_autocast(id, on, h)
        if on then
            pcall(core.input.enable_pet_autocast, id)
        else
            pcall(core.input.disable_pet_autocast, id)
            if h then h.switched_at = core.time() end
        end
    end

    local function action_info(id)
        local ok, info = pcall(core.spell_book.get_pet_action_info, id)
        if ok and type(info) == "table" then return info end
        return nil
    end

    local function autocast_flag(id)
        local info = action_info(id)
        if info and type(info.auto_cast_enabled) == "boolean" then return info.auto_cast_enabled end
        return nil
    end

    local function pet_guid_now()
        local pet = M.pet()
        if not pet then return nil end
        local ok, guid = pcall(pet.get_guid, pet)
        return ok and guid or nil
    end

    local function held(key)
        local h = holds[key]
        return h ~= nil and h.stuck == nil and h.restore ~= nil and (core.time() - h.at) < AIM_LEASE
    end

    --- The engine presses this skill itself while it keeps asking: off
    --- autocast once per pet, without asking the client's flag. A skill the
    --- client says has no autocast is only pressed.
    ---@param name string
    ---@param restore? boolean autocast as it goes back when the engine lets go (on by default)
    ---@return boolean held false when it will not stay off on this client
    function M.aim(name, restore)
        if type(name) ~= "string" then return false end
        local key = name:lower()
        local h = hold_of(key)
        if h.stuck then return false end
        local id = M.spell_id(name)
        if not id then return false end
        h.at = core.time()
        if h.restore == nil then h.restore = restore ~= false end
        local who = pet_guid_now() or "?"
        if h.pet ~= who then
            h.pet = who
            local info = action_info(id)
            h.no_autocast = info ~= nil and info.auto_cast_allowed == false
            if not h.no_autocast then
                local before = info and info.auto_cast_enabled
                set_autocast(id, false, h)
                say("take:" .. key, string.format("pet: %s off autocast -- the reaction engine presses it (the client's flag read %s)",
                    name, before == nil and "nothing" or (before and "on" or "off")))
            end
        end
        return true
    end

    --- Is the engine pressing this skill right now (autocast off for it)?
    ---@param name string|nil
    ---@return boolean
    function M.aimed(name)
        return type(name) == "string" and held(name:lower())
    end

    --- Why this skill is left on autocast for the session, or nil.
    ---@param name string|nil
    ---@return string|nil
    function M.stuck(name)
        local h = type(name) == "string" and holds[name:lower()] or nil
        return h and h.stuck or nil
    end

    local last_growl_state = nil
    local last_growl_pet = nil         -- the pet that state was read from
    local growl_key = nil              -- the taunt the mode manages, lower-case

    --- Gives a held skill back to autocast: the lease ran out, the plugin is
    --- stopping (`now`), or the engine gave up on it. Kept pending while no
    --- pet is out to give it back to.
    local function give_back(key, h, now)
        if h.restore == nil then return end
        local id = M.spell_id(key)
        if not id then return end
        local back = h.restore
        h.restore, h.pet = nil, nil
        if now then h.at = -math.huge end
        if not h.no_autocast then set_autocast(id, back, h) end
        if key == growl_key then last_growl_state = back end
        log.fmt("debug", "pet %s autocast %s: the engine let go of it", key, back and "on" or "off")
    end

    --- Puts autocast back on every skill the engine has stopped pressing.
    --- The gates in the pet's tick (the rotation off, the mode Off) would
    --- keep sync_growl from ever noticing, so this runs before them.
    ---@param now? boolean the plugin is pausing or unloading: no lease to wait out
    function M.release_all(now)
        local t = core.time()
        for key, h in pairs(holds) do
            if h.restore ~= nil and (now or (t - h.at) >= AIM_LEASE) then give_back(key, h, now) end
        end
    end

    --- Nobody else here to hold a mob: no party, no dungeon, no raid.
    local function solo()
        local targeting = P.targeting
        if not targeting or type(targeting.context) ~= "function" then return true end
        local ok, here = pcall(targeting.context)
        return not ok or here == nil or here == targeting.SOLO
    end

    --- Should Growl be on right now? Tank mode always. Assist mode when
    --- solo: the pet IS the tank then, whatever the mode is called, and a
    --- pet without Growl loses the mob to the first Aimed Shot. Assist in a
    --- group keeps it off, so the pet never taunts off the real tank.
    ---@return boolean
    function M.growl_wanted()
        local mode = M.mode()
        if mode == M.TANK then return true end
        if mode == M.ASSIST then return solo() end
        return false
    end

    -- Always managed (1.32.0): the mode says what the pet is for, and Growl
    -- follows it. There is no switch to leave it to chance any more. Not on
    -- the client's flag either (1.68.1): set once when the wish changes.
    local function sync_growl()

        local name = growl_name()
        if not name then return end

        local id = M.spell_id(name)
        if not id then return end
        growl_key = name:lower()

        -- A different pet keeps its own autocast: the remembered state was
        -- another pet's (a fresh pet has Growl on, whatever the last one had).
        local pet_guid = pet_guid_now()
        if pet_guid ~= last_growl_pet then last_growl_state, last_growl_pet = nil, pet_guid end

        -- The engine presses it (taken off autocast in M.aim, once per pet).
        if held(growl_key) then return end
        local h = holds[growl_key]
        if h and h.restore ~= nil then give_back(growl_key, h, false) end

        local want = M.growl_wanted()
        if want == last_growl_state then return end
        set_autocast(id, want)
        last_growl_state = want
        log.fmt("debug", "pet %s autocast %s", name, want and "on" or "off")
    end

    --- The engine aims the taunt this pass. Autocast goes off at once, not on
    --- the next pet tick, so the pet does not spend the cooldown on its own
    --- target in between. Nothing in pet mode Off or Focus.
    ---@return string|nil the taunt being aimed, when the pet has one
    function M.aim_taunt()
        local mode = M.mode()
        if mode == M.OFF or mode == M.FOCUS then return nil end
        local name = growl_name()
        if not name or not AIMED_TAUNT[name:lower()] then return nil end
        growl_key = name:lower()
        if not M.aim(name, M.growl_wanted()) then return nil end
        last_growl_state = false
        return name
    end

    --- Is the engine aiming the taunt right now (autocast off for it)?
    ---@return boolean
    function M.taunt_aimed()
        return M.aimed(growl_name())
    end

    --- Why the taunt is left on autocast for this session, or nil while the
    --- engine may aim it.
    ---@return string|nil
    function M.taunt_stuck() return M.stuck(growl_name()) end

    --- Every held skill back to autocast (the name is the 1.68.0 one).
    ---@param now? boolean
    function M.release_taunt(now) M.release_all(now) end

    -- --- when the pet can use a skill again ---------------------------------
    --
    -- Pressed off this clock: when the pet last used each skill -- sent by
    -- us, or seen in its own cast events (its autocast, a click on its bar)
    -- -- the skill's cooldown, and the pet's own global cooldown, which Claw,
    -- Bite and most skills start and Growl does not (the spell tables). No
    -- pet skill's cooldown is asked of the client: its cooldown read is the
    -- player's book's.
    local COOLDOWN = { growl = 5, torment = 5, suffering = 120 }
    local used_at, sent_at = {}, {}    -- lower-case name -> time
    local pressed_at = {}              -- lower-case name -> our last press, refused or not
    local gcd_until = -math.huge       -- the pet's own global cooldown
    local cooldown_cache = {}

    local function data_of(key)
        local skills = beasts and beasts.skills
        if not skills then return nil end
        for name, row in pairs(skills) do
            if name:lower() == key then return row end
        end
        return nil
    end

    local function cooldown_of(name)
        local key = name:lower()
        if cooldown_cache[key] then return cooldown_cache[key] end
        local row = data_of(key)
        local secs = (row and row.cd) or COOLDOWN[key] or 0
        if not row then
            local id = M.spell_id(name)
            local sb = core.spell_book
            if id and sb and sb.get_spell_base_cooldown then
                local ok, info = pcall(sb.get_spell_base_cooldown, id)
                local ms = ok and type(info) == "table" and tonumber(info.cooldown_ms) or nil
                if ms and ms > 0 and ms < 600000 then secs = ms / 1000 end
            end
        end
        cooldown_cache[key] = secs
        return secs
    end

    local function gcd_of(key)
        local row = data_of(key)
        return row and row.gcd or 0
    end

    local function started(key, now)
        used_at[key] = now
        local g = gcd_of(key)
        if g > 0 then gcd_until = math.max(gcd_until, now + g) end
    end

    --- Seconds until the pet can use this skill again, by that clock: its
    --- cooldown, and the pet's global cooldown when the skill is on it.
    ---@param name string
    ---@return number
    function M.ready_in(name)
        local key = name:lower()
        local now = core.time()
        local left = 0
        local at = used_at[key]
        if at then left = math.max(0, at + cooldown_of(name) - now) end
        if gcd_of(key) > 0 then left = math.max(left, gcd_until - now) end
        return left
    end

    local function pet_event_spell(args)
        if type(args) ~= "table" or args[1] ~= "pet" then return nil end
        local id = tonumber(args[3])
        local spells = ctx.spells
        if not id or not spells or not spells.name then return nil end
        local ok, n = pcall(spells.name, id)
        if ok and type(n) == "string" and n ~= "" then return n:lower() end
        return nil
    end

    --- Gives up pressing a skill for this session: back on autocast as it
    --- was, and the engine leaves it to the pet.
    local function give_up(key, why)
        local h = hold_of(key)
        if h.stuck then return end
        local back = h.restore
        if back == nil then back = (key == growl_key) and M.growl_wanted() or true end
        h.restore = back
        give_back(key, h, true)
        h.stuck = why
        log.fmt("info", "pet: %s will not stay off autocast here (%s) -- left on autocast; the engine stops pressing it",
            key, why)
    end

    --- The pet used a held skill and we had not pressed it: autocast is still on.
    local function by_itself(key, now)
        local h = holds[key]
        if not h or h.no_autocast then return end
        if (now - h.rogue_at) > 30 then h.rogue_n = 0 end
        -- One already on its way when we switched it off is not proof.
        if (now - h.switched_at) < 1.0 then return end
        h.rogue_n, h.rogue_at = h.rogue_n + 1, now
        local id = M.spell_id(key)
        if h.rogue_n == 1 then
            if id then set_autocast(id, false, h) end
            say("rogue:" .. key, string.format("pet: %s went off by itself while the engine presses it -- autocast switched off again", key))
        else
            give_up(key, string.format("the pet used %s by itself %d times after it was switched off", key, h.rogue_n))
        end
    end

    --- "Spell is not ready yet" right after our press: it was not used.
    local function refused(key, now)
        sent_at[key] = nil
        local g = gcd_of(key)
        if g > 0 then
            -- Inside the pet's global cooldown, most likely (its Claw, its
            -- Bite): ask again after one, and it proves nothing about autocast.
            used_at[key] = nil
            gcd_until = math.max(gcd_until, now + g)
            return
        end
        used_at[key] = now - cooldown_of(key) + 1.0          -- ask again in a second
        local h = hold_of(key)
        if (now - h.refused_at) > 20 then h.refused_n = 0 end
        h.refused_n, h.refused_at = h.refused_n + 1, now
        say("refused:" .. key, string.format("pet: %s refused (not ready) -- something else used it; asking again in 1s", key))
        if (h.refused_n >= 2 and not confirmed_any) or h.refused_n >= 3 then
            give_up(key, string.format("%d presses refused in 20s%s", h.refused_n,
                confirmed_any and "" or ", and the pet's cast events never confirmed one"))
        end
    end

    if ctx.on then
        ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
            local key = pet_event_spell(args)
            if not key then return end
            local now = core.time()
            local ours = pressed_at[key] ~= nil and (now - pressed_at[key]) < 1.5
            started(key, now)
            sent_at[key] = nil
            if ours then
                confirmed_any = true
                pressed_at[key] = nil
                -- A refusal laid on it was somebody else's error.
                local h = holds[key]
                if h and h.refused_n > 0 and (now - h.refused_at) < 1.5 then h.refused_n = h.refused_n - 1 end
            elseif held(key) then
                by_itself(key, now)
            end
        end)
        -- Ours, and turned down: it was never used.
        ctx.on("jcore.game_event.UNIT_SPELLCAST_FAILED", function(args)
            local key = pet_event_spell(args)
            if key and sent_at[key] and (core.time() - sent_at[key]) < 1.0 then
                used_at[key], sent_at[key] = nil, nil
            end
        end)
        ctx.on("jcore.game_event.UI_ERROR_MESSAGE", function(args)
            if type(args) ~= "table" then return end
            local code, text = tostring(args[3] or ""):upper(), tostring(args[2] or ""):lower()
            if not (code:find("NOT_READY", 1, true) or text:find("not ready", 1, true)) then return end
            local now = core.time()
            for key, at in pairs(sent_at) do
                if (now - at) < 0.6 and held(key) then refused(key, now) end
            end
        end)
    end

    --- The pet's focus and its most, where the client says (a hunter's pet).
    --- Not M.focus: that is the unit pinned in pet mode Focus (1.68.2 -- in
    --- 1.68.0 this took its name, and Focus mode's tick got a number).
    ---@return number|nil current
    ---@return number|nil most
    function M.focus_power()
        local pet = M.pet()
        if not pet then return nil end
        local ok_c, current = pcall(pet.get_power, pet, 2)     -- 2 is focus
        local ok_m, most = pcall(pet.get_max_power, pet, 2)
        if not ok_c or not ok_m or type(current) ~= "number" or type(most) ~= "number" or most <= 0 then
            return nil
        end
        return current, most
    end

    --- The client's range answer for a pet action -- which is about the pet's
    --- OWN target: true, false, or nil where it does not say.
    ---@param name string
    ---@return boolean|nil
    function M.in_range(name)
        local id = M.spell_id(name)
        if not id then return nil end
        local ok, info = pcall(core.spell_book.get_pet_action_info, id)
        if not ok or type(info) ~= "table" or info.checks_range == false then return nil end
        if info.in_range == true or info.in_range == false then return info.in_range end
        return nil
    end

    -- --- pet abilities ------------------------------------------------------

    --- Casts a pet spell by name at a target. Pet spells are NOT player
    --- spells: pushing one through the normal cast gateway silently does
    --- nothing, because the player does not know it.
    ---@param name string
    ---@param target game_object
    ---@return boolean
    function M.cast(name, target)
        if not M.alive() then return false end
        local id = M.spell_id(name)
        if not id then return false end

        -- Nothing selected: no skill at a mob either, or the pet goes to it
        -- (1.87.1). Its own and yours (Dash, Furious Howl) still go.
        if target and M.home() then
            local player = units.player()
            local ok_h, hostile = false, nil
            if player then ok_h, hostile = pcall(player.can_attack, player, target) end
            if ok_h and hostile and not rawequal(target, M.pet()) then return false end
        end

        -- The client's range answer is about the pet's own target. A spell
        -- aimed at another mob (the aimed taunt) had its reach measured by
        -- the caller, from where the pet stands.
        local own = M.pet_target()
        local elsewhere = false
        if own and target and not rawequal(own, target) then
            local ok_a, a = pcall(own.get_guid, own)
            local ok_b, b = pcall(target.get_guid, target)
            elsewhere = not (ok_a and ok_b and a == b)
        end
        if not elsewhere and own then
            local ok, info = pcall(core.spell_book.get_pet_action_info, id)
            if ok and type(info) == "table" then
                if info.in_range == false then return false end
            end
        end

        local sent = pcall(core.input.pet_cast_target_spell, id, target)
        if sent then
            local key, now = name:lower(), core.time()
            started(key, now)
            sent_at[key], pressed_at[key] = now, now
            log.fmt("debug", "pet cast %s", name)
            ctx.emit("jambix.aio.pet_cast", name)
        end
        return sent
    end

    --- Pet interrupt, from the class module's own list. Separate from the
    --- player interrupt path for the reason above.
    ---@param class_module table
    ---@param target game_object
    ---@return boolean
    function M.try_interrupt(class_module, target)
        if not target or not target:is_casting_spell() then return false end

        local list = class_module and class_module.pet_interrupts or nil
        if not list then return false end

        local ok, interruptible = pcall(target.is_active_spell_interruptable, target)
        if ok and interruptible == false then return false end

        for i = 1, #list do
            if M.knows(list[i]) and M.cast(list[i], target) then return true end
        end
        return false
    end

    -- --- how fast the pet is losing health ----------------------------------
    --
    -- The same reasoning as modules/resources.lua, in miniature: whether to
    -- heal a pet depends on where its health is HEADED, not where it is. A pet
    -- at 30% and steady is holding; a pet at 30% and dropping eight percent a
    -- second is already dead and only the animation is left.

    local hp_window = {}          -- { t, hp } newest last
    local HP_WINDOW = 4.0
    local last_hp_sample = 0
    local last_guid = nil

    local function sample_pet_health()
        local now = core.time()
        if (now - last_hp_sample) < 0.25 then return end
        last_hp_sample = now

        local pet = M.pet()
        if not pet then
            hp_window, last_guid = {}, nil
            return
        end

        -- A resummoned pet is a different pet at full health, not a miraculous
        -- recovery. Sampling across the swap would read as a huge heal.
        local ok, guid = pcall(pet.get_guid, pet)
        guid = ok and guid or nil
        if guid ~= last_guid then
            hp_window, last_guid = {}, guid
        end

        hp_window[#hp_window + 1] = { t = now, hp = units.health_fraction(pet) }
        while #hp_window > 2 and (now - hp_window[1].t) > HP_WINDOW do
            table.remove(hp_window, 1)
        end
    end

    --- Fraction of the pet's health bar per second, negative while falling.
    ---@return number
    function M.hp_rate()
        if #hp_window < 2 then return 0 end
        local first, last = hp_window[1], hp_window[#hp_window]
        local dt = last.t - first.t
        if dt < 0.5 then return 0 end
        return (last.hp - first.hp) / dt
    end

    -- --- upkeep -------------------------------------------------------------

    --- The pet's mana as a fraction, 0 when it has no mana bar.
    ---
    --- Dark Pact reads this: it converts the pet's mana into the warlock's,
    --- at no health cost at all, which makes it strictly better than Life Tap
    --- whenever the pet has anything to give.
    ---@return number 0..1
    function M.power_fraction()
        local pet = M.pet()
        if not pet then return 0 end
        local ok_cur, current = pcall(pet.get_power, pet, 0)   -- 0 is mana
        local ok_max, maximum = pcall(pet.get_max_power, pet, 0)
        if not ok_cur or not ok_max then return 0 end
        if type(maximum) ~= "number" or maximum <= 0 then return 0 end
        return (tonumber(current) or 0) / maximum
    end

    --- Is healing this pet a decision that changes anything?
    ---
    --- THE BUG THIS REPLACES. The old rule was "pet below 50% and I am above
    --- 40%, so heal it". Health Funnel then ran on a pet that three mobs were
    --- beating on, channelled through the warlock's own health bar, and ended
    --- with a dead pet AND a dead warlock. The percentage was never the
    --- question. The question is whether the heal changes the outcome.
    ---
    --- Four things have to be true, and the old rule checked one of them:
    ---
    ---   1. The pet is low enough to be worth a global cooldown.
    ---   2. The pet is DOING something -- holding a mob. A pet at 20% that is
    ---      not tanking anything is not about to be hit again, and a pet that
    ---      is not in combat at all should just be left alone.
    ---   3. We can afford it. Health Funnel is paid for in the warlock's own
    ---      health, so it goes through the same trade gate as Life Tap. This
    ---      is the check that stops the pet heal feeding the death spiral.
    ---   4. It will actually save the pet. If the pet is losing health faster
    ---      than the funnel can restore it, the funnel buys a second or two
    ---      and costs the warlock the fight. Better to let the pet die and
    ---      resummon than to die with it.
    ---
    ---@param name string the spell being considered
    ---@return boolean
    ---@return string reason
    --- A line worked out from live data (modules/auto.lua), else the default.
    --- Never the menu: there is no slider behind these.
    local function derived(id, default_pct)
        if P.derived then return P.derived(id, default_pct) end
        return default_pct / 100
    end

    local function pet_heal_worth_it(name)
        local pet = M.pet()
        if not pet then return false, "no pet" end

        local pet_hp = M.health()
        local line = P.derived and P.derived("pet_heal_hp", 20) or 0.20
        if pet_hp > line then return false, "pet is fine" end

        -- Out of combat a dead pet costs a summon, not a life. Resummoning is
        -- cheaper than channelling, and does not interrupt anything.
        if not combat.in_combat() then return false, "not in combat" end

        do
            local holding = M.pet_target() ~= nil
            if not holding then return false, "pet is not holding anything" end
        end

        -- Mend Pet costs only mana, so the health-trade test does not apply to
        -- it; Health Funnel is paid in health and does.
        if name == "Health Funnel" then
            local cost = derived("pet_funnel_cost_hp", 20)
            local ok, reason = false, "no resource tracking"
            if P.resources then
                -- need_power is deliberately 1.0: unlike Life Tap, the point
                -- of this trade is not to buy mana, so "mana is not the
                -- problem yet" must not veto it. Everything else applies.
                ok, reason = P.resources.may_trade_health(cost, {
                    floor = derived("pet_funnel_min_hp", 55),
                    need_power = 1.0,
                })
            end
            if not ok then return false, reason end

            -- Will it save the pet? Compare what the pet is losing against
            -- what a funnel restores. Both are rough; the decision only needs
            -- the sign, not the magnitude.
            local losing = M.hp_rate()
            if losing < -derived("pet_funnel_futile_rate", 8) then
                return false, string.format(
                    "pet is losing %.0f%%/s; a funnel will not save it",
                    -losing * 100)
            end
        end

        return true, "worth it"
    end

    --- Keeps the pet alive. Mend Pet and Health Funnel are player spells, so
    --- these go through the normal gateway.
    -- Only ever reached when the reaction engine does not own the heal (it
    -- does whenever it runs), so this is the fallback, not a second owner.
    local function pet_healing()

        local pet = M.pet()
        if not pet then return false end

        for _, name in ipairs({ "Mend Pet", "Health Funnel" }) do
            -- Health Funnel is a CHANNEL. Re-requesting it every tick restarts
            -- it, so the pet gets the first tick of a funnel over and over and
            -- the warlock pays for all of them. Same distinction that cost the
            -- Drain Soul refund; the helper that bounds it lives on the
            -- rotation so a latched flag cannot wedge this either.
            local helpers = P.rotation and P.rotation.helpers
            local channelling = helpers and helpers.channel_active
                and helpers.channel_active(name)
            -- A class rule for the same spell owns it (the hunter's Mend
            -- Pet): one decision, one lockout, not two casting in turn.
            local owned = P.rotation and P.rotation.has_rule
                and P.rotation.has_rule(name)
            -- And the reaction engine, which heals the pet by score, once per
            -- dip, predictively (modules/react/rules/core.lua).
            owned = owned or (P.react ~= nil and P.react.owns ~= nil and P.react.owns(name))

            if book.ready(name) and not channelling and not owned then
                local ok, reason = pet_heal_worth_it(name)
                if not ok then
                    -- Said once per reason rather than every frame: this fires
                    -- on a tick, and the interesting case is a player watching
                    -- the pet die and wondering why nothing happened.
                    log.once("debug", "pet_heal_" .. name,
                        string.format("not healing pet with %s: %s", name, reason))
                    return false
                end
                ctx.cast({
                    spell_id = book.id(name), target = pet,
                    priority = ctx.PRIORITY.UTILITY,
                    reason = name,
                })
                return true
            end
        end
        return false
    end

    -- --- the tick -----------------------------------------------------------

    -- AN ASSIGNMENT outranks the mode for a few seconds. The reaction engine
    -- sends the pet to pick up an add that is hitting us; without this the
    -- assist pass below re-sent it to our target on its very next tick.
    local pinned_guid, pinned_until = nil, 0

    --- Sends the pet at a unit and keeps it there for `seconds`, whatever the
    --- mode would choose. Ends early if the unit dies or leaves.
    ---@param unit game_object
    ---@param reason string
    ---@param seconds? number
    ---@return boolean issued
    function M.assign(unit, reason, seconds)
        if not M.send(unit, reason, true) then return false end
        local ok, guid = pcall(unit.get_guid, unit)
        pinned_guid = ok and guid or nil
        pinned_until = core.time() + (seconds or 5)
        return true
    end

    --- The unit the pet is pinned to, while the pin holds.
    ---@return game_object|nil
    function M.assigned()
        if not pinned_guid or core.time() >= pinned_until then return nil end
        local unit = units.by_guid(pinned_guid)
        if not unit or not unit:is_valid() or unit:is_dead() then
            pinned_guid = nil
            return nil
        end
        return unit
    end

    --- Calls the pet back to us and keeps it off one mob for a while. The
    --- reaction engine does this when the mob the pet is on starts evading:
    --- it is going home, takes nothing, and the pet would follow it through
    --- whatever stands on the way.
    ---@param reason string
    ---@param guid string|nil the mob to keep it off
    ---@param seconds? number
    ---@param quiet? boolean logged as debug, not info (a call repeated)
    ---@return boolean issued
    function M.recall(reason, guid, seconds, quiet)
        local input = ctx.input and ctx.input.pet
        if input and input.follow then
            input.follow()
        elseif core.input and core.input.set_pet_follow then
            pcall(core.input.set_pet_follow)
        else
            return false
        end
        local now = core.time()
        if guid then shunned[guid] = now + (seconds or 8) end
        designated_guid, designated_reason = nil, nil
        pinned_guid = nil
        last_command = now
        log.fmt(quiet and "debug" or "info", "pet: called back (%s)", reason or "recall")
        return true
    end

    -- --- the stance, and what the pet may follow us onto (1.74.1) -----------
    --
    -- The user: "make sure pets arent attacking shit on its own".
    --
    -- THE STANCE. The plugin never set it, so a pet left on Aggressive (a
    -- freshly tamed one, one switched by hand) attacked whatever wandered
    -- near, and pulled it. 1.75.1 kept it Defensive.
    --
    -- ALWAYS PASSIVE (1.75.2). The user: "should always be on Passive". The
    -- pet attacks only what it is sent at: by the rotation (your target, the
    -- add, a taunt), by the defence below (a mob hitting it or you, the one
    -- thing Defensive did by itself), or by you. Kept in every pet mode,
    -- with the rotation paused or off too -- only an ESP-only client is
    -- left alone. Aggressive and Defensive are switched back. Where the bar
    -- says nothing (Forever's pet book reads empty) it is set once per pet
    -- and again after every fight.
    local stance_set_for, stance_at, stance_said = nil, -math.huge, nil

    local function keep_passive()
        local now = core.time()
        local who = pet_guid_now() or "?"
        local unread = pet_stance == nil
        if not unread and pet_stance:find("PASSIVE", 1, true) then return end
        if unread and stance_set_for == who then return end
        if (now - stance_at) < 5 then return end
        stance_at, stance_set_for = now, who
        local input = ctx.input and ctx.input.pet
        if input and input.passive then
            input.passive()
        elseif core.input and core.input.set_pet_passive then
            pcall(core.input.set_pet_passive)
        else
            return
        end
        local was = unread and "not readable"
            or (pet_stance:find("AGGRESSIVE", 1, true) and "Aggressive")
            or (pet_stance:find("DEFENSIVE", 1, true) and "Defensive") or pet_stance
        -- Until the next scan of the bar reads it back.
        if not unread then pet_stance = "PET_MODE_PASSIVE" end
        if not unread or stance_said ~= who then
            stance_said = who
            log.fmt("info", "pet: set to Passive (it was %s) -- it attacks only what it is sent at", was)
        end
    end

    -- WHAT PASSIVE DOES NOT DO ITSELF. In a fight, a pet with nothing to do
    -- is sent at a mob hitting it, else one hitting you (the nearest); never
    -- one held by crowd control that damage breaks. Only while a mob is
    -- selected (1.87.1): with nothing selected the pet comes home (below).
    local function pet_busy()
        -- A target whose death cannot be read counts as alive: not redirected.
        local t = M.pet_target()
        if t then
            local ok, dead = pcall(t.is_dead, t)
            if not (ok and dead == true) then return true end
        end
        local d = designated_guid and units.by_guid and units.by_guid(designated_guid) or nil
        if not d then return false end
        local ok_v, valid = pcall(d.is_valid, d)
        local ok_d, dead = pcall(d.is_dead, d)
        return ok_v and valid == true and not (ok_d and dead == true)
    end

    local function attacker()
        local en = ctx.enemies
        if not (en and en.where) then return nil end
        local ok, rows = pcall(en.where, function(r)
            return (r.targeting_pet or r.targeting_me) and r.activity ~= "dead"
        end)
        if not ok or type(rows) ~= "table" then return nil end
        local react = P.react
        local best, best_rank, best_d = nil, -1, math.huge
        for i = 1, #rows do
            local r = rows[i]
            local obj = r.obj
            local held = obj and react and react.out_of_fight and react.out_of_fight(obj)
            if obj and not held then
                local rank = r.targeting_pet and 2 or 1
                local d = r.dist or math.huge
                if rank > best_rank or (rank == best_rank and d < best_d) then
                    best, best_rank, best_d = obj, rank, d
                end
            end
        end
        return best
    end

    --- The pet's stance as its bar shows it, or nil.
    function M.stance() return pet_stance end

    -- WHAT IT FOLLOWS US ONTO. Out of combat, the pull's own answer
    -- (rotation.may_engage_unit). In a fight that answer was "anything": a
    -- mob clicked in passing was the pet running off to pull it. Now only a
    -- mob already in the fight -- on you, the pet or the group, or one we
    -- have hit -- or the engage key held.
    local function may_follow(target)
        local rotation = P.rotation
        if not combat.in_combat() then
            return not rotation or rotation.may_engage_unit(target)
        end
        if P.key_armed and P.key_armed("rot_engage_key") then return true end
        local en = ctx.enemies
        local ok, row = false, nil
        if en and en.get then ok, row = pcall(en.get, target) end
        row = ok and row or nil
        if row and (row.engaged or row.targeting_me or row.targeting_pet) then return true end
        local world = P.react and P.react.world
        if row and row.in_combat and row.target_guid and world and world.in_group
            and world.in_group(row.target_guid) then
            return true
        end
        local mem = P.react and P.react.memory
        local ok_g, guid = pcall(target.get_guid, target)
        if ok_g and guid and mem and mem.attacked and mem.attacked(guid, 20) then return true end
        return false
    end
    M.may_follow = may_follow

    -- NOTHING SELECTED, THE PET COMES HOME (1.87.1). The user: "If no mobs
    -- selected all pets will come back to you as passive". With no live
    -- hostile mob selected the pet is sent at nothing: M.send and M.cast
    -- refuse, the defence above waits, and so do the reaction engine's sends
    -- and the skills it aims at a mob (the taunt, an add's pickup). Once
    -- nothing has been selected for HOME_GRACE, a pet still on a mob, or off
    -- fighting away from you, is called back (Follow); Passive, it stays.
    -- The grace is the auto-target's to pick the next mob after a kill, so
    -- the pet does not turn round in between. In every pet mode, with the
    -- rotation off too, as Passive is -- except Focus with its unit alive:
    -- that pin is yours.
    local HOME_GRACE = 1.0      -- s with nothing selected before the call
    local HOME_AGAIN = 3.0      -- s before calling a pet still out again
    local HOME_NEAR = 10        -- yd: a pet fighting further off is not with you
    local nothing_since, home_at, home_said = nil, -math.huge, false

    --- Your target when it is a live mob you could attack, else nil.
    ---@return game_object|nil
    local function selected_mob()
        local target = combat.target()
        if not target then return nil end
        local ok_v, valid = pcall(target.is_valid, target)
        if not (ok_v and valid) then return nil end
        local ok_d, dead = pcall(target.is_dead, target)
        if ok_d and dead == true then return nil end
        local player = units.player()
        if not player then return nil end
        local ok_a, hostile = pcall(player.can_attack, player, target)
        if not (ok_a and hostile) then return nil end
        return target
    end

    --- Does the pet stay with you: no mob selected, and not pinned in Focus?
    ---@return boolean
    function M.home()
        if P.esp_only then return false end
        if focus_guid and M.mode() == M.FOCUS then
            local unit = M.focus()
            local ok, dead = false, nil
            if unit then ok, dead = pcall(unit.is_dead, unit) end
            if ok and dead == false then return false end
        end
        return selected_mob() == nil
    end

    --- Why the pet is not with you, or nil when it is.
    ---@return string|nil
    local function pet_out()
        if pet_busy() then
            local on = M.pet_target()
                or (designated_guid and units.by_guid and units.by_guid(designated_guid)) or nil
            local ok, name = false, nil
            if on then ok, name = pcall(on.get_name, on) end
            return "it was on " .. ((ok and type(name) == "string" and name) or "a mob")
        end
        local pet = M.pet()
        if not pet then return nil end
        local ok_c, fighting = pcall(pet.is_in_combat, pet)
        if not (ok_c and fighting == true) or not units.distance then return nil end
        local ok_d, d = pcall(units.distance, pet)
        if ok_d and type(d) == "number" and d > HOME_NEAR and d < math.huge then
            return string.format("it was fighting %.0f yd away", d)
        end
        return nil
    end

    local function come_home()
        if not M.home() then
            nothing_since, home_said = nil, false
            return
        end
        local now = core.time()
        nothing_since = nothing_since or now
        if (now - nothing_since) < HOME_GRACE or (now - home_at) < HOME_AGAIN then return end
        local why = pet_out()
        if not why then return end
        home_at = now
        if M.recall("nothing selected: " .. why, nil, nil, home_said) then home_said = true end
    end

    local function decide()
        -- Before the gates: autocast back on whatever the engine has let go of.
        M.release_all()
        if not P.master_on() then return end
        -- Passive whatever the rotation is doing (1.75.2), and home with
        -- nothing selected (1.87.1).
        if not P.esp_only and M.alive() then
            keep_passive()
            come_home()
        end
        if not P.opt("rot_enabled", false) then return end
        if not P.rotation_active() then return end

        local mode = M.mode()
        if mode == M.OFF then return end
        if not M.alive() then return end

        sync_growl()
        sample_pet_health()
        pet_healing()

        local player = units.player()
        if not player then return end

        -- Pinned by an assignment: leave it where it was sent.
        if M.assigned() then return end

        -- FOCUS pins to one unit and ignores everything else, which is the
        -- point of it.
        if mode == M.FOCUS then
            local unit = M.focus()
            if unit and not unit:is_dead() then
                M.send(unit, "focus")
            end
            return
        end

        if mode == M.TANK then
            -- The pet's job here is what nobody is holding. Ask targeting for
            -- a loose mob first; only fall back to our target when everything
            -- is already held.
            local loose = targeting.reclaim_target(P.tune_secs("rot_target_range", 30))
            if loose then
                M.send(loose, "grab aggro")
                return
            end
        end

        -- ASSIST, and the TANK fallback: follow the player's target -- but
        -- only a target the rotation may engage, and in a fight only one in
        -- it (may_follow). A pet charging whatever is selected is an
        -- auto-pull by another route, and selecting is not attacking.
        local target = combat.target()
        local ordered = false
        -- NEVER ONTO CROWD CONTROL THAT DAMAGE BREAKS (1.7.6). A target in a
        -- Freezing Trap, a Scatter Shot or a sheep wakes at the first bite,
        -- and the PvP hunter's trap is worth nothing if its own pet breaks
        -- it. The pet is not sent there; on it already, it goes at what is
        -- hitting it or you, else it is called back off it until the control
        -- ends. The same for a player in Divine Shield or Ice Block.
        local react = P.react
        local held = target ~= nil and react ~= nil and react.out_of_fight ~= nil
            and react.out_of_fight(target) == true
        if held then
            local guid = units.guid(target)
            local on = M.pet_target()
            local on_it = (on ~= nil and units.guid(on) == guid) or (designated_guid ~= nil and designated_guid == guid)
            -- Once per call back: the pet still reads that target for a
            -- moment while it turns round.
            local kept_off = shunned[guid] ~= nil and core.time() < shunned[guid]
            if on_it and not kept_off then
                local other = attacker()
                if other and units.guid(other) ~= guid then
                    M.send(other, "off a held target", true)
                else
                    M.recall("its target is held by crowd control", guid, 3)
                end
            end
            ordered = on_it
        elseif target and not target:is_dead() and player:can_attack(target) then
            if may_follow(target) then
                M.send(target, "assist")
                ordered = true
            end
        end

        -- Passive: what is hitting it or you, when it has nothing to do --
        -- and a mob is selected (1.87.1).
        if not ordered and combat.in_combat() and not pet_busy() and not M.home() then
            local unit = attacker()
            if unit then M.send(unit, "defend") end
        end
    end

    ctx.tick(decide, { interval = 0.3, priority = 70 })

    -- Clear the designation when the fight ends, so the next pull does not
    -- inherit a stale order.
    ctx.on("jcore.combat.leave", function()
        designated_guid, designated_reason = nil, nil
        -- An unreadable stance is set again before the next pull (1.75.2).
        stance_set_for = nil
        for k in pairs(shunned) do shunned[k] = nil end
    end)

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local MODE_NAME = { [M.OFF] = "off", [M.ASSIST] = "assist",
                            [M.TANK] = "tank", [M.FOCUS] = "focus" }
        local pet = M.pet()
        local on = M.pet_target()
        local ok_name, name = false, nil
        if on then ok_name, name = pcall(on.get_name, on) end
        return {
            alive = pet ~= nil,
            health = M.health(),
            mode = MODE_NAME[M.mode()] or "?",
            growl = M.growl_wanted(),
            taunt_aimed = M.taunt_aimed(),
            taunt_stuck = M.taunt_stuck(),
            on = (ok_name and name) or nil,
            reason = designated_reason or (pet and M.home() and "home: nothing selected") or nil,
            focus = focus_guid,
        }
    end

    return M
end

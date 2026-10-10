-- Jambix AIO / react -- the reaction engine.
--
-- OBSERVE -> UNDERSTAND -> DECIDE -> ACT -> RE-EVALUATE
--
--   world.lua     game reads, once a tick, into one shared table
--   detect.lua    what it means: situations, each with two lines (latch.lua)
--   behavior.lua  what kind of moment: NORMAL / DEFENSIVE / EMERGENCY /
--                 ESCAPE / RECOVERY, and BOSS / AOE / PVP
--   engine.lua    every reaction proposes, everything is scored, one per lane
--                 is validated and sent
--   memory.lua    what was just done and what came of it, so nothing is done
--                 twice for one event
--   rules/        the reactions themselves, as data: core.lua for everyone,
--                 <class>.lua for what only that class has
--
-- WHERE IT SITS
-- modules/rotation.lua calls R.tick() first thing in its own tick, with the
-- snapshot it has just built. Whatever the engine sends outranks the rotation
-- in the cast arbiter; a reaction on the global cooldown means the priority
-- walk does not run this tick, and a hold (a hardcore bail-out, easing off
-- threat) means nothing offensive runs. When the engine is switched off the
-- rotation uses its old fixed sequence, unchanged.

return function(P)
    local ctx, log = P.ctx, P.log
    local units = P.units

    local load = P.load or function(path) return require("jambix_aio/" .. path) end

    local L = load("modules/react/latch")()

    local function clock() return core.time() end

    -- What the client can and cannot tell us (JCore's world.client(), 1.6.0):
    -- no combat log arguments (combat_log false: damage from tooltips, evades
    -- seen from the mob), and whether the API recorder runs (recording: the
    -- engine's decisions go into its timeline). Both say "as always" on Era.
    local client = {}
    do
        local world = ctx and ctx.world
        local ok, c = pcall(function() return world and world.client and world.client() end)
        if ok and type(c) == "table" then client = c end
    end
    local no_combat_log = client.combat_log == false
    local function spell_name(id)
        local spells = ctx and ctx.spells
        if spells and spells.name then
            local ok, n = pcall(spells.name, id)
            if ok and type(n) == "string" and n ~= "" then return n end
        end
        return nil
    end

    local memory = load("modules/react/memory")(clock, spell_name)
    local detect = load("modules/react/detect")(P, L)
    local world = load("modules/react/world")(P, detect, memory)
    local behavior = load("modules/react/behavior")(P)
    -- The rotation, changed by the fight: rotation.lua asks this for every
    -- rule that passes (see adapt.lua).
    -- What each skill actually does: measured from the combat log, the
    -- tooltip until then (damage.lua).
    local damage = load("modules/react/damage")(P, ctx)
    -- The plan for the fight: who dies first, who holds what, what an area
    -- spell reaches, and the race with every mob counted (tactics.lua).
    local tactics = load("modules/react/tactics")(P, world, memory)
    local adapt = load("modules/react/adapt")(P, world, damage, tactics)
    -- What the fights taught: immunities, the real range edges, evading mobs
    -- (learn.lua). The rotation's usable check asks it, so reactions do too.
    local learn = load("modules/react/learn")(P)
    -- Is a pet heal worth standing still for (petcare.lua)?
    local petcare = load("modules/react/petcare")(P)
    -- Which mob the pet's taunt goes to, and where the pet should go
    -- (petthreat.lua, 1.68.0): every engaged mob, every pass.
    local petthreat = load("modules/react/petthreat")(P, world, tactics, learn, memory)
    -- The other player (pvp.lua, 1.81.0): what controls us, what each enemy
    -- player is immune to or bursting with, which trinket breaks what.
    local pvp = load("modules/react/pvp")(P, world)
    -- What the reactions decide, drawn in the world (marks.lua, 1.85.0): the
    -- kick lined up on a caster, who a reaction just acted on, and PvP's
    -- vanish spot, the control on you and the player bursting on you.
    local marks = load("modules/react/marks")(P)

    local R = {}
    R.memory, R.detect, R.world, R.behavior, R.latch = memory, detect, world, behavior, L
    R.adapt_module = adapt
    R.tactics = tactics
    R.damage = damage
    R.learn = learn
    R.petcare = petcare
    R.petthreat = petthreat
    R.pvp = pvp
    R.marks = marks

    -- --- Forever: what its client does not say ------------------------------
    --
    -- The API recorder (jcore.recorder.json) showed what the Forever client
    -- leaves out: units' names read "", and the combat log arrives with no
    -- arguments at all. Names are JCore's since 1.6.0 (units.name answers per
    -- client: on Forever the names learned from our casts, kept by npc id, and
    -- the client's creature cache); the damage tally that the pet's threat
    -- guard reads comes from what each cast of ours is expected to deal; and
    -- an evading mob is seen from the mob itself. None of it exists on Era.
    local forever_hp = {}              -- guid -> { hp, at }, for the evade
    local forever_sample_at = 0

    local function npc_id(guid)
        if type(guid) ~= "string" then return nil end
        local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
        if kind == "Creature" or kind == "Vehicle" or kind == "Pet" then return id end
        return nil
    end

    --- A mob's name: JCore's (1.6.0: on Forever the names learned from our
    --- casts, kept by npc id, and the client's creature cache), else
    --- "npc <id>", so a lesson is never kept under a blank.
    local function unit_name(unit)
        local n = units.name and units.name(unit)
        if type(n) == "string" and n ~= "" then return n end
        local id = npc_id(units.guid(unit))
        return id and ("npc " .. id) or nil
    end
    learn.name_of = unit_name
    tactics.name_of = function(unit) return unit_name(unit) or "a mob" end
    R.forever_name = unit_name
    --- Weighs the rotation's candidates against each other by what they do.
    function R.weigh(cands, s)
        return adapt.weigh(cands, s)
    end

    --- How the fight moves one rotation candidate: bonus, reasons, refusal.
    function R.adapt(rule, row, s, c)
        return adapt.adjust(rule, row, s, c)
    end

    --- The plan's kill order: the unit to kill first, and whether there is a
    --- plan for this fight at all (solo, two or more engaged). targeting.lua
    --- takes it in place of its own score while one is live.
    ---@return game_object|nil
    ---@return boolean live
    function R.focus() return tactics.focus() end

    --- The whole plan, for the readout and the tests.
    function R.plan() return tactics.state end

    --- How many engaged mobs an area spell would hit, aimed at the
    --- snapshot's target: 0 when it would wake a mob we crowd-controlled or
    --- (solo) pull an idle one; nil when it is not an area spell, or this
    --- tick has no picture (H.spread then counts the old way).
    ---@param name string|nil
    ---@param s table|nil the rotation's snapshot
    ---@return integer|nil
    function R.reach_count(name, s)
        local W = world.W
        if type(name) ~= "string" or not W or not W.player
            or math.abs(clock() - (W.now or -math.huge)) > 0.25 then
            return nil
        end
        local catalog = P.catalog
        local row = catalog and catalog.ability and catalog.ability(name) or nil
        local count, wakes, pulls = tactics.reach(name, row, s and s.target or nil)
        if count == nil then return nil end
        if wakes or (pulls and W.env.solo) then return 0 end
        return count
    end

    --- Crowd-controlled in a way damage breaks: never a target to pick. Nor
    --- is a player in Divine Shield or Ice Block, or for a warrior or a rogue
    --- in Blessing of Protection (1.81.0): nothing of ours lands.
    ---@param unit game_object|nil
    ---@return boolean
    function R.out_of_fight(unit)
        if not unit then return false end
        local en = ctx and ctx.enemies
        if en and en.get then
            local ok, row = pcall(en.get, unit)
            if ok and row ~= nil and tactics.out_of_fight(row) then return true end
        end
        local ok_i, immune = pcall(pvp.immune_to_us, unit)
        return ok_i and immune == true
    end

    -- --- the journal --------------------------------------------------------
    --
    -- Every state change, every reaction sent, every refusal and why, every
    -- bail-out start and end, every retry held back. Kept as a ring for the
    -- Debug page and mirrored to the log -- at info for what changes the
    -- fight, at debug for refusals unless "log every decision" is on.

    local journal_rows, journal_seen = {}, {}
    local JOURNAL_MAX = 60
    local LEVEL = { state = "info", trigger = "info", bailout = "warn", reject = "debug",
                    retry = "debug", error = "warn", select = "debug", idle = "warn", learn = "info",
                    plan = "info" }

    local function explain_on() return P.opt and P.opt("react_explain_log", false) == true end

    ---@param kind string state | trigger | bailout | reject | retry | error | select
    ---@param text string
    ---@param key? string throttle: one line per key per 3s
    --- Would a line under this throttle key be kept right now? Asked before
    --- formatting one, so a refusal repeated every frame costs no string.
    local function journal_due(key)
        local last = journal_seen[key]
        return not last or (clock() - last) >= 3.0
    end

    local function journal(kind, text, key)
        local now = clock()
        if key then
            local last = journal_seen[key]
            if last and (now - last) < 3.0 then return end
            journal_seen[key] = now
        end
        journal_rows[#journal_rows + 1] = { at = now, kind = kind, text = text }
        if #journal_rows > JOURNAL_MAX then table.remove(journal_rows, 1) end
        local level = LEVEL[kind] or "debug"
        -- Forever: what the engine decided goes into the API recorder's
        -- timeline too, beside what the client answered (jcore.trace.txt).
        if client.recording and level ~= "debug" and ctx and ctx.emit then
            pcall(ctx.emit, "jcore.recorder.trace", "react " .. kind .. ": " .. text)
        end
        if level == "debug" and explain_on() then level = "info" end
        if log and log.fmt then log.fmt(level, "react %s: %s", kind, text) end
    end
    R.journal = journal

    local engine = load("modules/react/engine")(P, memory, journal)
    R.engine = engine

    -- --- the rule registry ----------------------------------------------------

    local unique = {}
    memory.unique = unique

    local lib = { memory = memory, detect = detect, world = world, engine = engine, latch = L,
                  journal = journal, petcare = petcare, petthreat = petthreat, pvp = pvp }

    R.add_rule = engine.add_rule
    R.remove_rule = engine.remove_rule
    R.set_enabled = engine.set_enabled
    R.rules = engine.rules

    --- Declares a one-per-caster debuff (Hunter's Mark): the memory tracks
    --- where it was last confirmed, and the rotation holds it while the
    --- target is flapping between mobs.
    ---@param name string
    function R.unique(name) unique[name] = true end

    local function load_rules(path)
        local ok, factory = pcall(load, path)
        if not ok or type(factory) ~= "function" then return false, factory end
        local built, err = pcall(factory, R, P, lib)
        if not built then
            journal("error", string.format("%s failed to load: %s", path, tostring(err)))
            return false, err
        end
        return true
    end

    load_rules("modules/react/rules/core")
    -- The pet's own skills, for every class with a pet (1.71.0).
    load_rules("modules/react/rules/pet")
    -- Answering another player, for every class (1.81.0).
    load_rules("modules/react/rules/pvp")

    -- The player's own reactions, GUI or Lua, and the switches on the
    -- built-in ones (the Reactions window, 1.76.0).
    do
        local ok, custom = pcall(function() return load("modules/react/custom")(R, P, lib, engine, load) end)
        if ok then
            R.custom = custom
        else
            journal("error", "your reactions failed to load: " .. tostring(custom))
        end
    end

    -- Defined further down; declared here so the closure below captures the
    -- local rather than an undefined global.
    local wire_wakes

    -- Class reactions: modules/react/rules/<class key>.lua, when there is one,
    -- and a class module's own `reactions(R, P, lib)` hook, when it has one.
    -- Only files that exist: a require that misses can be noisy in the
    -- game's loader. Add the class key here with its file.
    local CLASS_RULE_FILES = { hunter = true }
    -- More files for a class (1.7.6: the PvP hunter's reactions, which ask
    -- their own switch before anything).
    local CLASS_EXTRA_RULES = { hunter = { "hunter_pvp" } }

    local class_rules_for = nil
    local function sync_class_rules()
        local rot = P.rotation
        local class_module = rot and rot.active_class and rot.active_class()
        if not class_module or class_rules_for == class_module.key then return end
        class_rules_for = class_module.key
        if CLASS_RULE_FILES[class_module.key] then
            load_rules("modules/react/rules/" .. tostring(class_module.key))
        end
        for _, extra in ipairs(CLASS_EXTRA_RULES[class_module.key] or {}) do
            load_rules("modules/react/rules/" .. extra)
        end
        if type(class_module.reactions) == "function" then
            local ok, err = pcall(class_module.reactions, R, P, lib)
            if not ok then journal("error", "class reactions failed: " .. tostring(err)) end
        end
        if wire_wakes then wire_wakes() end
    end
    R.sync_class_rules = sync_class_rules

    -- --- wiring the memory to the game -----------------------------------------

    local function is_ours(request)
        return not (ctx.id and request.owner and request.owner ~= ctx.id)
    end

    if ctx and ctx.on then
        ctx.on("jcore.cast.sent", function(request)
            if type(request) ~= "table" or not request.spell_id or not is_ours(request) then return end
            local guid = request.target and units.guid and units.guid(request.target) or nil
            memory.on_sent(request.spell_id, guid, request.reason)
        end)

        -- The red text that says something about the MOB: too close, out of
        -- range, immune. Read with where the mob is now and how fast the gap
        -- moves; learn.lua decides whether the reading is worth keeping.
        local function teach(row, id, text)
            local up = type(id) == "string" and id:upper() or ""
            local low = type(text) == "string" and text:lower() or ""
            local kind = nil
            if up:find("TOO_CLOSE", 1, true) or low:find("too close", 1, true) then
                kind = "too_close"
            elseif up:find("OUT_OF_RANGE", 1, true) or low:find("out of range", 1, true) then
                kind = "out_of_range"
            elseif up:find("IMMUNE", 1, true) or low == "immune" then
                kind = "immune"
            end
            if not kind or not row.target_guid or not units.by_guid then return end
            local unit = units.by_guid(row.target_guid)
            if not unit then return end
            -- Hitbox to hitbox, the way the client measured it (1.58.1).
            local distance = units.distance and units.distance(unit) or nil
            local helpers = P.rotation and P.rotation.helpers
            if distance and helpers and helpers.gap then distance = helpers.gap(unit, distance) end
            local en = ctx.enemies
            local erow = en and en.get and en.get(unit) or nil
            local inner, reach = nil, nil
            local rot = P.rotation
            if rot and rot.range_of then inner, reach = rot.range_of(row.name) end
            learn.on_error(kind, row.name, unit, distance, erow and erow.closing or 0, reach, inner)
        end

        local function player_or_pet(args)
            return type(args) == "table" and (args[1] == "player" or args[1] == "pet")
        end

        ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
            if not player_or_pet(args) then return end
            local id = tonumber(args[3])
            memory.on_success(id)
            if args[1] == "player" and id then damage.cast(spell_name(id)) end
        end)

        -- Every point of damage we deal, by spell: the worth of each skill.
        -- Filtered on the first two fields -- this fires for everything in
        -- range, and a raid is thousands a second.
        local my_guid, my_unit = nil, nil
        ctx.on("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", function(a)
            if type(a) ~= "table" then return end
            local sub = a[2]
            local swing = sub == "SWING_DAMAGE"
            local missed = sub == "SPELL_MISSED" or sub == "RANGE_MISSED" or sub == "SWING_MISSED"
            if not swing and not missed and sub ~= "SPELL_DAMAGE" and sub ~= "SPELL_PERIODIC_DAMAGE"
                and sub ~= "RANGE_DAMAGE" then return end
            local player = units.player and units.player()
            -- IDENTITY, NOT ~=. A game object compares through the client's
            -- own __eq, which raises "Invalid game object!" when either side
            -- has gone stale -- and the cached one does, after a loading
            -- screen. Then the raise came before the cache could be replaced,
            -- so it repeated on every hit for the rest of the session and
            -- nothing more was measured (Era log, 2026-10-03). JCore keys its
            -- units by identity too (units.lua's snap).
            if not rawequal(player, my_unit) then
                my_unit = player
                my_guid = player and units.guid(player) or nil
            end
            if not my_guid then return end
            -- A hit on us or on the pet: what that mob does to us, by source,
            -- for the plan's kill order and its race (tactics.lua).
            if not missed and a[4] ~= my_guid then
                local pet_guid = world.W.pet and world.W.pet.guid
                -- In a group, a hit on any member counts too (the group plan).
                if a[8] == my_guid or (pet_guid ~= nil and a[8] == pet_guid) or world.in_group(a[8]) then
                    tactics.taken(a[4], tonumber(swing and a[12] or a[15]))
                    return
                end
            end
            if a[4] ~= my_guid then
                -- The pet's misses say one thing we need: the mob it is
                -- chasing is evading, going home through whatever is on the way.
                if missed and P.pet and P.pet.pet then
                    local pet = P.pet.pet()
                    if pet and a[4] == units.guid(pet) then
                        learn.on_miss(a[8], a[9], nil, sub == "SWING_MISSED" and a[12] or a[15])
                    end
                end
                return
            end
            -- A miss: immune, evading (learn.lua). A swing's miss type sits
            -- where a spell's id does.
            if missed then
                if sub == "SWING_MISSED" then
                    learn.on_miss(a[8], a[9], nil, a[12])
                else
                    learn.on_miss(a[8], a[9], a[13], a[15])
                end
                return
            end
            -- A swing carries its amount where a spell carries its id.
            if swing then
                damage.dealt_to(a[8], tonumber(a[12]))
                return
            end
            local name, amount = a[13], tonumber(a[15])
            if amount then damage.dealt_to(a[8], amount) end
            if type(name) == "string" and amount then
                damage.damage(name, amount)
                learn.on_hit(a[9], name)
            end
        end)
        ctx.on("jcore.spell.cast", function(data)
            if type(data) ~= "table" or not data.spell_id then return end
            local player = units.player and units.player()
            if not player then return end
            if data.caster and data.caster.get_guid then
                local ok, guid = pcall(data.caster.get_guid, data.caster)
                if ok and guid ~= units.guid(player) then return end
            end
            memory.on_success(data.spell_id)
            damage.cast(spell_name(data.spell_id))
            -- Forever: no combat log, so what this cast is expected to deal
            -- (its tooltip, damage.lua) goes on the target's tally instead.
            if no_combat_log and data.target then
                local name = spell_name(data.spell_id)
                local expected = name and damage.expected(name)
                local guid = units.guid(data.target)
                if expected and guid then damage.dealt_to(guid, expected) end
            end
        end)
        -- FAILED carries no reason, and most of them are a queued press
        -- arriving a moment early: recorded, never counted towards a back-off.
        ctx.on("jcore.game_event.UNIT_SPELLCAST_FAILED", function(args)
            if not player_or_pet(args) then return end
            local row = memory.on_failure(tonumber(args[3]), "refused", true)
            if row then journal("reject", string.format("%s was refused by the client", row.name), "fail:" .. row.name) end
        end)
        ctx.on("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", function(args)
            if not player_or_pet(args) then return end
            memory.on_failure(tonumber(args[3]), "interrupted", true)
        end)
        ctx.on("jcore.game_event.UI_ERROR_MESSAGE", function(args)
            if type(args) ~= "table" then return end
            -- Only an error that will repeat on the next press counts (out of
            -- range, not facing, no sight); "not ready yet" fixes itself.
            local soft = not memory.persistent_error(args[3])
            -- Which press it was, the client does not say: name the others
            -- sent with it, so a pet's refused Growl is not read as Auto Shot's.
            local also = {}
            for _, n in ipairs(memory.sent_recently(0.6)) do also[#also + 1] = n end
            local row = memory.on_failure(nil, tostring(args[3] or args[2] or "error"), soft)
            if row then
                for i = #also, 1, -1 do
                    if also[i] == row.name then table.remove(also, i) end
                end
                journal("reject", string.format("client error after %s%s: %s", row.name,
                    #also > 0 and (" (or " .. table.concat(also, ", ") .. ", sent with it)") or "",
                    tostring(args[2] or args[3] or "error")), "uierr:" .. row.name)
                teach(row, args[3], args[2])
            end
        end)
        ctx.on("jcore.game_event.UNIT_SPELLCAST_CHANNEL_START", function(args)
            if type(args) == "table" and args[1] == "player" then memory.on_channel(tonumber(args[3]), true) end
        end)
        ctx.on("jcore.game_event.UNIT_SPELLCAST_CHANNEL_STOP", function(args)
            if type(args) == "table" and args[1] == "player" then memory.on_channel(tonumber(args[3]), false) end
        end)
        ctx.on("jcore.combat.leave", function()
            memory.combat_end()
            learn.combat_end()
            damage.reset_dealt()
            world.forget_units()
            tactics.reset()
            petthreat.reset()
            pvp.reset()
            marks.reset()
        end)
    end

    -- Wake events: a rule that waits on an interval is asked at once when
    -- the thing it answers happens. Registered per event, once.
    local woken = {}
    wire_wakes = function()
        if not (ctx and ctx.on) then return end
        local rules = engine.rules()
        for i = 1, #rules do
            local def = rules[i]
            for _, event in ipairs(def.wake or {}) do
                if not woken[event] then
                    woken[event] = true
                    ctx.on(event, function()
                        local list = engine.rules()
                        for j = 1, #list do
                            local d = list[j]
                            for _, e in ipairs(d.wake or {}) do
                                if e == event then engine.wake(d) end
                            end
                        end
                    end)
                end
            end
        end
    end
    wire_wakes()

    -- --- switches -------------------------------------------------------------

    --- Always (1.32.0): the engine is the path, not an option. Kept as a
    --- function because the rotation and the pet ask it.
    ---@return boolean
    function R.active()
        return true
    end

    --- Does a reaction own this spell right now? Other casters of it stand aside.
    ---@param spell string
    ---@return boolean
    function R.owns(spell)
        if not R.active() then return false end
        return engine.owns(spell, world.W)
    end

    -- --- the debug snapshot ------------------------------------------------------
    --
    -- Plain strings and numbers, copied at decision time, so the readout can be
    -- drawn on a later frame without touching a unit handle. Built only while
    -- something is reading it: the menu page, the overlay, or the explain log.

    local snap = nil
    local wanted_at = -math.huge

    local function wanted(now)
        if explain_on() then return true end
        if P.opt and P.opt("react_overlay", false) then return true end
        return (now - wanted_at) < 1.5
    end

    local function describe(c)
        local reasons = {}
        for i = 1, #c.reasons do
            local r = c.reasons[i]
            reasons[i] = string.format("%+d %s", math.floor(r[1] + 0.5), r[2])
        end
        local target = ""
        if c.target and c.target ~= world.W.player.unit and units.name then
            local ok, n = pcall(units.name, c.target)
            if ok and type(n) == "string" and n ~= "" then target = n end
        end
        return {
            name = c.name, rule = c.rule.name, score = math.floor(c.score + 0.5),
            lane = c.lane, kind = c.kind, state = c.state, why = c.why,
            rejected = c.rejected, reasons = reasons, target = target,
        }
    end

    --- One line on the other player, while there is one (1.81.0): what
    --- controls you, your PvP trinket and what it breaks, and your target's
    --- immunity, burst and trinket.
    local function pvp_line(W)
        local V = W.pvp
        if not V or not V.active then return nil end
        local parts = { string.format("PvP: %d player(s), %d on you", V.players or 0, V.attackers or 0) }
        local ctl = V.control or V.root or V.snare
        if ctl then
            parts[#parts + 1] = string.format("%s by %s (%.1fs)", ctl.mech, ctl.name, math.min(ctl.remaining or 0, 99))
        end
        local worn = {}
        for _, t in ipairs(pvp.trinkets()) do
            if t.breaks then
                local ready, why = true, nil
                local hc = P.hardcore
                if hc and hc.named_ready then ready, why = hc.named_ready(t.name) end
                worn[#worn + 1] = string.format("%s (%s) %s", t.name, pvp.breaks_text(t.breaks),
                    ready and "ready" or tostring(why or "not ready"))
            end
        end
        parts[#parts + 1] = #worn > 0 and ("trinket " .. table.concat(worn, "; ")) or "no PvP trinket worn"
        local st = V.target
        if st then
            if st.immune then
                parts[#parts + 1] = string.format("target in %s (%.0fs)", st.immune_name, math.min(st.immune_left or 0, 99))
            end
            if st.burst then parts[#parts + 1] = "target bursting: " .. st.burst_name end
            if st.trinket_down then
                parts[#parts + 1] = string.format("target's trinket back in %.0fs", st.trinket_back or 0)
            end
        end
        if V.flag then parts[#parts + 1] = "you carry the flag" end
        return table.concat(parts, " | ")
    end

    local function take_snapshot(W, d, sent)
        local s = {
            at = W.now, mode = W.mode, context = W.context, mode_why = W.mode_why,
            mode_age = W.mode_age or 0,
            danger = math.floor((W.env.danger or 0) + 0.5), danger_reasons = {},
            gcd = d.gcd and describe(d.gcd) or nil,
            fast = d.fast and describe(d.fast) or nil,
            pet = d.pet and describe(d.pet) or nil,
            holds = {}, others = {}, rejected = {}, sent = sent,
            sits = {}, rotation = nil, deferred = d.deferred and describe(d.deferred) or nil,
        }
        for i = 1, #(W.env.danger_reasons or {}) do s.danger_reasons[i] = W.env.danger_reasons[i] end
        for i = 1, #d.holds do s.holds[i] = describe(d.holds[i]) end
        for i = 1, #d.cands do
            local c = d.cands[i]
            if c ~= d.gcd and c ~= d.fast and c ~= d.pet and c.kind ~= "hold" then
                local row = describe(c)
                s.others[#s.others + 1] = row
                if c.rejected then s.rejected[#s.rejected + 1] = row end
            end
        end
        for _, name in ipairs({ "hp_low", "hp_critical", "pet_low", "pet_critical", "mana_low",
                                "threat_warning", "threat_critical", "danger_high", "danger_extreme",
                                "aoe", "flee", "losing", "incoming", "spike", "adds", "bailout",
                                "aggro_pulled", "pet_lost_aggro", "incapacitated", "outnumbered" }) do
            if W.sit[name] then s.sits[#s.sits + 1] = name end
        end
        s.plan = tactics.lines(W.now)
        do
            local ok, line = pcall(pvp_line, W)
            s.pvp = ok and line or nil
        end
        -- The pet's taunt (petthreat.lua): its own row when there is no plan,
        -- else on the plan's second, so the readout keeps its 35 rows.
        local taunt = petthreat.line(tactics.name_of)
        if taunt then
            if #s.plan >= 2 then
                s.plan[2] = s.plan[2] .. " | " .. taunt
            else
                s.plan[#s.plan + 1] = taunt
            end
        end
        local st = tactics.state
        if st.live and st.focus then
            s.plan_short = string.format("Plan: %d up, kill %s first%s", st.count, tactics.name_of(st.focus),
                st.losing and " -- OUTNUMBERED" or "")
        end
        return s
    end

    -- --- the tick -------------------------------------------------------------------

    local idle_check, last_holds   -- defined just below; declared first for the closures
    local pet_skill_line           -- the held pet skills' log line, below
    local pending_deferred = nil
    local last_selected = nil          -- describe() of the last reaction actually sent
    local HUMANOID = 7                 -- the client's creature type
    local last_verdict = nil           -- the previous tick's, for the idle report
    local pet_watch = { lost = false, held = 0 }
    local last_rotation = nil          -- { name, at }: the rotation's last real press

    -- --- standing still ------------------------------------------------------
    --
    -- THE FAILURE THAT LOOKS LIKE NOTHING. In combat, with a target, not
    -- casting, the global cooldown free, no auto attack running, standing
    -- still -- and nothing of ours has gone out for over half a second. Every
    -- gate in the rotation and every hold in here has a reason; this says
    -- which one it was, the moment it happens, instead of leaving a gap in the
    -- log for somebody to guess at.
    local IDLE_AFTER = 0.6
    local idle = { since = nil, reported = false, episodes = 0, total = 0, why = nil, at = 0 }

    local function idle_reason(W)
        local why = {}
        local v = last_verdict
        if v and v.halt then
            local names = {}
            for i = 1, #(last_holds or {}) do names[#names + 1] = last_holds[i] end
            why[#why + 1] = "halted by " .. (#names > 0 and table.concat(names, ", ") or "a hold")
        end
        if v and v.waiting then why[#why + 1] = "waiting for " .. v.waiting .. " to start" end
        if W.hold_fire then why[#why + 1] = "holding fire: the target has not engaged and is not ours to open on" end
        local rot = P.rotation
        local cands = rot and rot.last_candidates and rot.last_candidates() or {}
        local named = {}
        if #cands == 0 then
            why[#why + 1] = "no rotation rule passed"
        else
            for i = 1, math.min(#cands, 3) do
                local c = cands[i]
                named[c.rule[1]] = true
                why[#why + 1] = string.format("%s: %s", c.rule[1], c.state or "?")
            end
        end
        -- The rules that never became candidates: the gates say why.
        local profile = W.profile
        if rot and rot.explain and profile and profile.rules then
            local asked = 0
            for i = 1, #profile.rules do
                local name = profile.rules[i][1]
                if not named[name] and not profile.rules[i].self then
                    named[name] = true
                    local ok, text = pcall(rot.explain, name, profile, W.s)
                    if ok and type(text) == "string" then why[#why + 1] = text end
                    asked = asked + 1
                    if asked >= 3 then break end
                end
            end
        end
        return table.concat(why, " | ")
    end

    function idle_check(W, now)
        local pl, tg = W.player, W.target
        -- Shooting is not standing still: the client's auto-attack flag does
        -- not cover Auto Shot or a wand on every build (the live log reported
        -- "idle" with Auto Shot firing), so a shot of either within a swing
        -- counts too, from the cast stream or the weave's own shot clock.
        local shooting = pl.shooting == true          -- world.lua reads it
        if not shooting and P.weave and P.weave.last_shot_at then
            local ok, at = pcall(P.weave.last_shot_at)
            shooting = ok and type(at) == "number" and at > 0 and (now - at) < 4.5
        end
        local standing_idle = pl.in_combat and tg.unit ~= nil and pl.cast_remaining <= 0
            and (pl.gcd or 0) <= 0.05 and not pl.auto_attacking and not shooting and not pl.moving
            and memory.since_any_sent() > IDLE_AFTER
        if standing_idle then
            -- Counted from the first idle tick, never back-dated: the first tick
            -- of a pull is idle-looking until the walk presses, a frame later.
            idle.since = idle.since or now
            if not idle.reported and (now - idle.since) >= IDLE_AFTER then
                idle.reported = true
                idle.episodes = idle.episodes + 1
                idle.why = idle_reason(W)
                idle.at = now
                journal("idle", string.format("standing still in combat on %s: %s",
                    (units.name and units.name(tg.unit)) or "the target", idle.why))
            end
        elseif idle.since then
            local lasted = now - idle.since
            if idle.reported then idle.total = idle.total + lasted end
            if idle.reported then
                journal("idle", string.format("moving again after %.1fs idle", lasted))
            end
            idle.since, idle.reported = nil, false
        end
    end

    --- The idle report: episodes, total seconds, and the last reason.
    function R.idle_stats() return idle end

    -- A HEAL CHANNEL THAT GIVES WAY (1.66.0). Mend Pet holds us still for five
    -- seconds; if, halfway, standing there would get us killed (a mob turned
    -- on us at half health, our health heading under the line, danger
    -- ground), the channel stops outranking the fight: any reaction may cut
    -- it, and the rotation's cast gate opens for the walk and the kite.
    local yield_state = nil            -- { name, why, rule, at }

    --- The channel giving way and why, while it does (a tick or so old at
    --- most). rotation.lua's cast gate reads it.
    ---@return string|nil why
    ---@return string|nil spell
    function R.yielding()
        local y = yield_state
        if not y or (clock() - y.at) > 0.5 then return nil end
        return y.why, y.name
    end

    -- A CAST WE SENT THAT HAS NOT STARTED YET. Between the arbiter sending a
    -- spell and the client reporting it as in progress there is a round trip
    -- in which the player reads as idle, and the rotation's walk pressed into
    -- that gap: the live log has a Mend Pet sent at 7:27 and cut off at once
    -- by the next press, then sent again at 7:31. So after a reaction takes
    -- the global cooldown, the walk is held until the cast or channel shows
    -- up, the client confirms or refuses it, or a short grace runs out. A
    -- channel is only "started" once it shows: the client reports SUCCEEDED
    -- for a channel before CHANNEL_START.
    local pending_start = nil          -- { name, at, grace, channel, score, row }

    local function start_grace(long)
        local ping = 0
        if type(core.get_ping) == "function" then
            local ok, value = pcall(core.get_ping)
            if ok and type(value) == "number" then ping = value end
        end
        -- An instant has nothing to show on a cast bar: its confirmation, or a
        -- round trip and a little, is all the wait it deserves.
        if not long then return math.min(0.5, math.max(0.2, ping / 1000 * 1.5 + 0.1)) end
        return math.min(0.8, math.max(0.3, ping / 1000 * 2 + 0.2))
    end

    local function hold_start(c, now)
        if c.kind ~= "spell" or c.lane ~= "gcd" then return end
        local tags = adapt.tags_for(c.name, { c.name, channel = c.channel }, P.catalog and P.catalog.ability
            and P.catalog.ability(c.name) or nil)
        local long = c.channel == true or (tags and (tags.channel or (tags.cast or 0) > 0))
        pending_start = {
            name = c.name, at = now, grace = start_grace(long), channel = c.channel == true,
            score = c.score, row = memory.last_attempt,
        }
    end

    --- Is the cast we sent still on its way? Clears itself when it is not.
    local function still_starting(W, now)
        local p = pending_start
        if not p then return nil end
        local state = p.row and p.row.state or "sent"
        local over = W.player.cast_remaining > 0
            or state == "failed" or state == "lost" or state == "unknown"
            or (state == "ok" and not p.channel)
            or (now - p.at) > p.grace
        if over then
            pending_start = nil
            return nil
        end
        return p
    end

    -- WHY A HELD PET SKILL WAITS (1.73.1). The user: "I dont see any [pet
    -- skills] being used when its off auto". Every skill the engine holds
    -- off autocast says, every 20 s of a fight, when it was last pressed or
    -- why it waits: the rule's own reason, or what the engine did with the
    -- candidate it made (outscored, refused, under the rotation's score).
    local pet_line_at = -math.huge
    function pet_skill_line(W, d, now)
        if not W.player.in_combat or not W.pet.alive then return end
        local pets = P.pet
        if not (pets and pets.aimed) then return end
        local status = petthreat.status
        for i = 1, #d.cands do
            local c = d.cands[i]
            if c.kind == "pet_spell" and status[c.name] == "offered" then
                if c.state == "selected" then
                    status[c.name] = "pressed now"
                else
                    status[c.name] = string.format("%s (score %d)", c.rejected or c.state or "?", math.floor(c.score + 0.5))
                end
            end
        end
        if (now - pet_line_at) < 20 then return end
        local parts = {}
        for name, why in pairs(status) do
            if pets.aimed(name) then
                local since = memory.since(name)
                if since < 20 then
                    parts[#parts + 1] = string.format("%s pressed %.0fs ago", name, since)
                else
                    parts[#parts + 1] = string.format("%s waits: %s", name, tostring(why))
                end
            end
        end
        if #parts == 0 then return end
        pet_line_at = now
        table.sort(parts)
        journal("state", "pet skills: " .. table.concat(parts, " | "))
    end

    --- Runs one reaction pass. Called by the rotation with its fresh snapshot.
    ---@param class_module table
    ---@param profile table
    ---@param s table
    ---@return table verdict { gcd: boolean, fast: boolean, halt: boolean, mode: string }
    function R.tick(class_module, profile, s)
        local now = clock()
        sync_class_rules()
        if R.custom then pcall(R.custom.sync) end

        local W = world.build(class_module, profile, s, now)
        W.explain = wanted(now)
        -- The other player (pvp.lua): read before any rule proposes. A read
        -- that raises leaves the PvP reactions out of this tick, nothing else.
        do
            local ok, V = pcall(pvp.read, W)
            W.pvp = ok and V or nil
            if not ok then journal("error", "the PvP read failed: " .. tostring(V), "pvp_read") end
        end
        -- Forever: no combat log to say EVADE. A mob we attacked that is out
        -- of combat, alive, and getting its health back is going home.
        if no_combat_log then
            local rows = s.enemies or {}
            for i = 1, math.min(s.enemy_count or 0, 12) do
                local row = rows[i]
                local guid = row and row.guid
                if guid and row.in_combat == false and not row.dead and memory.attacked(guid, 20) then
                    local hp = tonumber(row.hp) or 1
                    local was = forever_hp[guid]
                    if was and hp < 0.999 and hp > was.hp + 0.01 then
                        learn.on_miss(guid, unit_name(row.obj), nil, "EVADE")
                    end
                    forever_hp[guid] = { hp = hp, at = now }
                elseif guid then
                    forever_hp[guid] = nil
                end
            end
        end
        W.target.evading = learn.evading(W.target.guid)

        -- Forever: a short line every two seconds of a fight into the API
        -- recorder's timeline -- the global cooldown, the counted resources,
        -- the target and what was pressed -- so the next recording shows the
        -- rotation working (or not) beside what the client answered.
        if client.recording and W.player.in_combat and ctx and ctx.emit and (now - forever_sample_at) >= 2 then
            forever_sample_at = now
            local pl, tg, sn = W.player, W.target, W.s or {}
            local last = memory.last_sent
            pcall(ctx.emit, "jcore.recorder.trace", string.format(
                "react sample: mode=%s gcd=%.2f %s=%d/%d%s combo=%s target=%s %d%% ttd=%s last=%s",
                tostring(W.mode or "?"), pl.gcd or 0, tostring(pl.power_kind or "?"):lower(),
                math.floor(pl.power or 0), math.floor(pl.power_max or 0),
                (P.power_counted and P.power_counted(pl.power_kind or "")) and "(counted)" or "",
                tostring(sn.combo or "-"),
                tg.unit and (unit_name(tg.unit) or "?") or "none",
                math.floor((tg.hp or 0) * 100 + 0.5),
                (type(tg.ttd) == "number" and tg.ttd > 0 and tg.ttd < math.huge) and string.format("%.1f", tg.ttd) or "-",
                last and last.name and string.format("%s %.1fs ago", last.name, now - (last.sent_at or last.at or now)) or "-"))
        end
        W.pet.target_evading = learn.evading(W.pet.target_guid)
        if W.player.in_combat then learn.observe(s.enemies, s.enemy_count) end
        -- Does this one run when it is low? What the fights said, else the
        -- creature type: in Classic most humanoids do. Never a player.
        do
            local tg = W.target
            local said = tg.unit and learn.runs(learn.name_of(tg.unit)) or nil
            if said == nil then said = tg.creature == HUMANOID and not tg.player end
            tg.runs = said == true
        end
        for _, text in ipairs(learn.drain()) do journal("learn", text) end
        damage.tick()
        memory.update(W.player.busy)
        W.pending = still_starting(W, now)

        -- Understand.
        local changes = detect.update(W, now)
        for i = 1, #changes do
            local ch = changes[i]
            journal("state", string.format("%s %s%s", ch.name, ch.on and "ON" or "off",
                type(ch.value) == "number" and string.format(" (%.2f)", ch.value) or ""))
        end
        -- The moment a mob the pet held turns on us: the threat we had on it,
        -- how long the pet had it, and what we pressed last. The pet's threat
        -- guard (react/adapt.lua) is tuned from these lines.
        local lost = W.sit.pet_lost_aggro == true
        if lost and not pet_watch.lost then
            local last = memory.last_sent
            local pct = W.target.threat_pct
            journal("state", string.format("%s left the pet for you: your threat %s, the pet had it %.1fs%s",
                units.name(W.target.unit) or "the target",
                type(pct) == "number" and string.format("%d%%", math.floor(pct)) or "unread",
                pet_watch.held,
                last and last.name and string.format("; last press %s %.1fs ago", last.name,
                    now - (last.sent_at or last.at or now)) or ""))
        end
        pet_watch.lost = lost
        if W.pet.tanking then pet_watch.held = W.pet.held_for or 0 end

        -- Who needs the pet's taunt (petthreat.lua): before the plan, whose
        -- kill order asks whether a taunt is about to land on the pet's mob.
        petthreat.update(W, now)
        -- The plan for this fight (tactics.lua), re-planned whenever its
        -- shape changes: before the mode, which reads its race, and before
        -- the reactions, which read who holds what.
        for _, text in ipairs(tactics.update(W, now)) do journal("plan", text) end

        local mode_change, ctx_change = behavior.update(W, now)
        if mode_change then
            journal("state", string.format("mode %s -> %s: %s", mode_change.from, mode_change.to, mode_change.why))
            memory.set_state("mode", mode_change.to)
            -- An ESCAPE that comes from the field's FLEE has already been said
            -- by the field ("Break off"); saying it again stacks two banners.
            local said = mode_change.to == "ESCAPE" and W.sit.flee
            if P.narrate and not said and (mode_change.to == "EMERGENCY" or mode_change.to == "ESCAPE") then
                P.narrate.say(mode_change.to == "ESCAPE" and "danger" or "warn",
                    mode_change.to == "ESCAPE" and "Escape" or "Emergency", mode_change.why, "react_mode")
            end
        end
        if ctx_change then
            journal("state", string.format("context %s -> %s", tostring(ctx_change.from or "none"),
                tostring(ctx_change.to or "none")))
        end
        -- Only a real edge is news. The first reading after a reload is
        -- "never set -> off", which is not the end of a bail-out that never
        -- started (the live log had "bail-out END at 100%" on every first pull).
        local bail_changed, bail_before = memory.set_state("bailout", W.bailout == true)
        if bail_changed and (W.bailout or bail_before == true) then
            journal("bailout", W.bailout
                and string.format("bail-out START at %.0f%% health: no attacks", W.player.hp * 100)
                or string.format("bail-out END at %.0f%% health", W.player.hp * 100))
        end
        memory.set_state("escape", W.mode == "ESCAPE")

        local y = engine.yielding(W)
        if y and not (yield_state and yield_state.name == y.name and (now - yield_state.at) <= 0.5) then
            journal("state", string.format("%s gives way: %s", y.name, y.why))
        end
        if y then y.at = now end
        W.yield, yield_state = y, y

        -- Decide and act.
        local d = engine.decide(W)
        pet_skill_line(W, d, now)
        local verdict = { gcd = false, fast = false, halt = false, mode = W.mode }
        for _, lane in ipairs({ "fast", "gcd", "pet" }) do
            local c = d[lane]
            if c and engine.execute(c, W) then
                verdict[lane] = true
                hold_start(c, now)
                last_selected = describe(c)
                last_selected.at = now
                local parts = {}
                for i = 2, #c.reasons do
                    parts[#parts + 1] = string.format("%+d %s", math.floor(c.reasons[i][1] + 0.5), c.reasons[i][2])
                end
                journal("trigger", string.format("%s -> %s (%s) score %d%s", c.rule.name, c.name,
                    lane, math.floor(c.score + 0.5),
                    #parts > 0 and (": " .. table.concat(parts, ", ")) or ""))
            end
        end
        last_holds = {}
        for i = 1, #d.holds do
            verdict.halt = true
            local h = d.holds[i]
            last_holds[#last_holds + 1] = h.rule.name
            local key = "hold:" .. h.rule.name
            if journal_due(key) then
                journal("select", string.format("holding: %s (%s)", h.rule.name, h.why or h.name), key)
            end
        end
        for i = 1, #d.rejected do
            local c = d.rejected[i]
            local key = "rej:" .. c.rule.name .. ":" .. c.name
            if journal_due(key) then
                local kind = (c.rejected or ""):find("^failed") and "retry" or "reject"
                journal(kind, string.format("%s (%s) score %d: %s", c.name, c.rule.name,
                    math.floor(c.score + 0.5), c.rejected or "?"), key)
            end
        end
        -- Your own reactions keep what became of them, for the window's
        -- "why not" and their history (1.79.0).
        if R.custom and R.custom.after_decide then pcall(R.custom.after_decide, W, d, verdict) end
        pcall(marks.capture, W, d, verdict)

        -- Still waiting for our last cast to start: the walk's global
        -- cooldown is not free yet, whatever the cast bar says.
        if W.pending and not verdict.gcd then
            verdict.gcd = true
            verdict.waiting = W.pending.name
        end

        pending_deferred = (not verdict.gcd and not verdict.halt) and d.deferred or nil
        if wanted(now) then snap = take_snapshot(W, d, last_selected) end
        last_verdict = verdict
        if snap then
            local note = nil
            if verdict.halt then
                note = "held -- " .. (#last_holds > 0 and table.concat(last_holds, ", ") or "a hold")
            elseif verdict.waiting then
                note = "waiting for " .. verdict.waiting .. " to start"
            elseif verdict.gcd and last_selected then
                note = "a reaction took the global cooldown (" .. last_selected.name .. ")"
            end
            snap.verdict_note = note
            snap.casting_name = (W.player.casting_id and spell_name(W.player.casting_id)) or nil
            snap.has_target = W.target.unit ~= nil
        end
        idle_check(W, now)
        return verdict
    end

    --- After the priority walk: the rotation's own pick and its scored
    --- candidates, for the readout, and the low-priority reaction when the
    --- rotation had nothing to press.
    ---@param rotation_choice string|nil the walk's GCD choice; nil when it chose nothing
    ---@param cands? table[] the walk's candidates, scored (rotation.last_candidates)
    function R.after_rotation(rotation_choice, cands)
        local deferred = pending_deferred
        pending_deferred = nil
        if type(rotation_choice) == "string" and rotation_choice:sub(1, 1) ~= "(" then
            last_rotation = { name = rotation_choice, at = clock() }
        end
        if snap then
            snap.rotation = rotation_choice
            local rows = {}
            for i = 1, math.min(#(cands or {}), 6) do
                local c = cands[i]
                local reasons = {}
                for k = 1, #(c.reasons or {}) do
                    reasons[k] = string.format("%+d %s", math.floor(c.reasons[k][1] + 0.5), c.reasons[k][2])
                end
                rows[i] = { name = c.rule[1], score = c.score, state = c.state, reasons = reasons }
            end
            snap.rotation_cands = rows
        end
        if rotation_choice ~= nil and rotation_choice ~= "(holding fire: target not engaged)" then return end
        if not deferred then return end
        if engine.execute(deferred, world.W) then
            hold_start(deferred, clock())
            last_selected = describe(deferred)
            last_selected.at = clock()
            journal("trigger", string.format("%s -> %s (rotation idle) score %d", deferred.rule.name,
                deferred.name, math.floor(deferred.score + 0.5)))
        end
    end

    -- --- the memory's word on a rotation press ----------------------------------------

    local function alive_marked(guid)
        local unit = units.by_guid and units.by_guid(guid) or nil
        if not unit then return false end
        local ok_v, valid = pcall(unit.is_valid, unit)
        if not ok_v or not valid then return false end
        local ok_d, dead = pcall(unit.is_dead, unit)
        if ok_d and dead then return false end
        return (units.health_fraction and units.health_fraction(unit) or 1) > 0.2
    end

    --- Why the memory says the rotation should not press this now, or nil.
    --- Bounded on purpose: a back-off is at most a few seconds, and a press
    --- the memory knows nothing about always goes through.
    ---@param name string
    ---@param target game_object|nil
    ---@return string|nil
    function R.gate(name, target)
        -- A reaction pressed this very spell a moment ago.
        local waiting, row = memory.waiting(name)
        if waiting and row and row.rule ~= "rotation" and memory.since(name) < 1.0 then
            return "a reaction just pressed it"
        end
        -- NO BACK-OFF FOR THE ROTATION'S OWN PRESSES (1.35.2). Two "You are
        -- too far away!" used to hold Auto Shot for seconds after the mob came
        -- into range (live log, 138:02-138:09). The rotation checks range
        -- itself and retries a refused press once a second already; a reaction
        -- is still backed off (engine.validate), because a reaction repeats
        -- the same action at the same event and a rotation does not.
        if unique[name] and target then
            local where, ago = memory.applied(name)
            local guid = units.guid and units.guid(target) or nil
            if where and guid and where ~= guid and ago < 20
                and (memory.flaps(6) >= 2 or memory.stable_for() < 1.5)
                and alive_marked(where) then
                return string.format("target flapping: %s stays where it is", name)
            end
        end
        return nil
    end

    -- --- the readout --------------------------------------------------------------------

    local function fmt_reasons(row, limit)
        local out = {}
        for i = 1, math.min(#row.reasons, limit or 8) do out[#out + 1] = "    " .. row.reasons[i] end
        return out
    end

    --- What the rotation is doing, in words. A rotation presses on one frame in
    --- dozens -- the global cooldown fills the rest -- so "nothing this frame"
    --- is the normal state of a working rotation, and the line says what came
    --- last and what is next instead. It also says when the rotation is not
    --- running at all, so a panel left from before is never read as current.
    ---@param s table|nil the snapshot
    ---@param now number
    ---@return string
    local function rotation_state(s, now)
        -- TBC, Wrath, Mists, Retail: the plugin runs as an overlay only there.
        if P.esp_only then
            return "off on " .. tostring(P.client_label or "this client") .. " -- the plugin is ESP-only here"
        end
        if P.opt and not P.opt("rot_enabled", false) then
            return "OFF -- switch on Enable rotation, at the top of the Rotation page"
        end
        if P.rotation_active and not P.rotation_active() then
            return "paused -- the rotation key (X by default) is off; press it"
        end
        if not s then return "waiting for the first tick" end
        local age = now - (s.at or now)
        if age > 1.5 then
            return string.format("not running for %.0fs (mounted, dead, or no rotation for this class)", age)
        end
        if s.verdict_note then return s.verdict_note end
        local r = s.rotation
        if r == "(casting)" then
            return "casting" .. (s.casting_name and (" " .. s.casting_name) or "") .. " -- the next press waits for it"
        end
        if type(r) == "string" and r:find("^%(holding fire") then
            return "holding fire -- the target has not engaged you and is not yours to open on"
        end
        if type(r) == "string" and r:sub(1, 1) ~= "(" then return "pressed " .. r end
        if s.has_target == false then return "no target" end

        local next_name = nil
        local rot = P.rotation
        local cands = rot and rot.last_candidates and rot.last_candidates() or {}
        for i = 1, #cands do
            if cands[i].state ~= "pressed" then next_name = cands[i].rule[1] break end
        end
        local last = (last_rotation and (now - last_rotation.at) < 15)
            and string.format("last %s %.1fs ago", last_rotation.name, now - last_rotation.at) or nil
        if last and next_name then return last .. "; next " .. next_name end
        if last then return last .. "; nothing else ready yet" end
        if next_name then return "next " .. next_name .. " (waiting on the global cooldown, range or resources)" end
        return "no rule passes right now -- the watch lines and any [idle] report say why"
    end
    R.rotation_state = function() return rotation_state(snap, clock()) end

    --- The debug view: why the last decision was made.
    ---@return string[]
    function R.debug_lines()
        local now = clock()
        wanted_at = now
        local out = {}
        local s = snap
        if not s then
            out[1] = "Reactions: on -- waiting for the rotation to run (enable it, hold its key)."
            return out
        end
        out[#out + 1] = string.format("Reactions: %s%s   (%.1fs: %s)   danger %d%s",
            s.mode or "?", s.context and (" + " .. s.context) or "", s.mode_age, s.mode_why or "", s.danger,
            pending_start and ("   [waiting for " .. pending_start.name .. " to start]") or "")
        if #s.danger_reasons > 0 then
            out[#out + 1] = "  danger: " .. table.concat(s.danger_reasons, ", ")
        end
        if #s.sits > 0 then out[#out + 1] = "  situations: " .. table.concat(s.sits, ", ") end
        if s.pvp then out[#out + 1] = "  " .. s.pvp end
        -- The plan for the fight: the kill order, the pet's job, the race.
        for i = 1, math.min(#(s.plan or {}), 2) do out[#out + 1] = s.plan[i] end

        -- The menu shows a fixed 30 rows and drops anything past them, so the
        -- blocks are capped to fit even when all three lanes fire at once:
        -- 3 + 2 plan + 7 + 5 + 4 + 2 holds + 1 + 2 rotation + 3 rejected + 1 damage
        -- + 1 learned + 3 memory + 1 idle = 35, + 1 PvP (main.lua declares 36,
        -- and 37 on Forever for its own line).
        local function selected(label, row, reasons)
            out[#out + 1] = string.format("%s %s%s   score %d   [%s]", label, row.name,
                row.target ~= "" and (" -> " .. row.target) or "", row.score, row.rule)
            for _, line in ipairs(fmt_reasons(row, reasons)) do out[#out + 1] = line end
        end
        if s.gcd then selected("Selected:", s.gcd, 6) end
        if s.fast then selected("Off-GCD: ", s.fast, 4) end
        if s.pet then selected("Pet:     ", s.pet, 3) end
        if not s.gcd and not s.fast and not s.pet then
            out[#out + 1] = "Selected: no reaction needed -- rotation " .. rotation_state(s, now)
        end
        for i = 1, math.min(#s.holds, 2) do
            out[#out + 1] = string.format("Holding: %s -- %s", s.holds[i].rule, s.holds[i].why or s.holds[i].name)
        end

        local others = {}
        for i = 1, math.min(#s.others, 6) do
            local o = s.others[i]
            others[#others + 1] = string.format("%s %d%s", o.name, o.score,
                o.state and o.state ~= "rejected" and (" (" .. o.state .. ")") or "")
        end
        if #others > 0 then out[#out + 1] = "Other candidates: " .. table.concat(others, ", ") end

        -- The rotation's own choice, scored by the same fight.
        local rc = s.rotation_cands
        if rc and #rc > 0 then
            local parts, pressed = {}, nil
            for i = 1, math.min(#rc, 4) do
                local r = rc[i]
                if r.state == "pressed" then pressed = r end
                parts[#parts + 1] = string.format("%s %.1f%s", r.name, r.score,
                    (r.state and r.state ~= "outscored") and (" (" .. r.state .. ")") or "")
            end
            out[#out + 1] = "Rotation: " .. table.concat(parts, ", ")
            local top = pressed or rc[1]
            if #top.reasons > 0 then
                out[#out + 1] = string.format("  %s: %s", top.name,
                    table.concat(top.reasons, ", ", 1, math.min(#top.reasons, 3)))
            end
        end
        for i = 1, math.min(#s.rejected, 3) do
            local r = s.rejected[i]
            out[#out + 1] = string.format("  rejected %s (%d): %s", r.name, r.score, r.rejected or "?")
        end

        local function ago(row)
            if not row then return "-" end
            return string.format("%s %.1fs ago%s", row.name or "?", now - (row.resolved_at or row.at or now),
                row.why and (" (" .. row.why .. ")") or "")
        end
        -- What each skill has been measured to deal, per cast (the combat log).
        do
            local list = {}
            for name, st in pairs(damage.stats()) do
                if st.avg and st.casts > 0 then list[#list + 1] = { name = name, avg = st.avg, casts = st.casts } end
            end
            table.sort(list, function(x, y) return x.casts > y.casts end)
            if #list > 0 then
                local parts = {}
                for i = 1, math.min(#list, 5) do
                    parts[i] = string.format("%s %.0f (%d)", list[i].name, list[i].avg, list[i].casts)
                end
                out[#out + 1] = "Damage per cast: " .. table.concat(parts, ", ")
            end
        end
        local learned = learn.summary()
        if learned then out[#out + 1] = "Learned: " .. learned end
        if no_combat_log then
            local spells = ctx and ctx.spells
            local probe = spells and spells.gcd_probe and spells.gcd_probe() or nil
            local names = ctx and ctx.names
            local ok_n, ns = pcall(function() return names and names.stats and names.stats() end)
            local n = ok_n and type(ns) == "table" and tonumber(ns.kept) or 0
            local en = ctx and ctx.enemies
            local ok_t, readable = pcall(function() return en and en.threat_readable and en.threat_readable() end)
            readable = ok_t and readable or nil
            local ok_m, meter = pcall(function() return en and en.meter_summary and en.meter_summary() end)
            out[#out + 1] = string.format("Forever: GCD %s | %s | combat log locked: ours from tooltips, theirs from your health | threat %s | %s | %d name(s) kept by JCore",
                probe and ("off spell " .. probe) or "not found yet",
                P.power_summary and P.power_summary() or "power read",
                readable == true and "read" or (readable == false and "unread (the client answers zeros)" or "not known yet"),
                (ok_m and type(meter) == "string") and meter or "damage meter not asked", n)
        end
        out[#out + 1] = string.format("Memory: tried %s | ok %s | failed %s",
            ago(memory.last_attempt), ago(memory.last_success), ago(memory.last_failure))
        out[#out + 1] = string.format("  %d event(s) handled%s   target changes %d in 6s",
            memory.handled_count(),
            (function()
                local keys = memory.handled_keys()
                return #keys > 0 and (": " .. table.concat(keys, "; ", 1, math.min(#keys, 3))) or ""
            end)(),
            memory.flaps(6))
        if last_selected then
            out[#out + 1] = string.format("Last reaction: %s (%s) %.1fs ago, score %d",
                last_selected.name, last_selected.rule, now - (last_selected.at or now), last_selected.score)
        end
        if idle.episodes > 0 then
            out[#out + 1] = string.format("Idle in combat: %d time(s), %.1fs in all; last %.0fs ago: %s",
                idle.episodes, idle.total + (idle.since and (now - idle.since) or 0), now - idle.at,
                (idle.why or "?"):sub(1, 160))
        end
        return out
    end

    --- The journal, newest first.
    ---@param n integer
    ---@return string[]
    function R.log_lines(n)
        local out, now = {}, clock()
        for i = #journal_rows, math.max(1, #journal_rows - (n or 10) + 1), -1 do
            local row = journal_rows[i]
            out[#out + 1] = string.format("%5.1fs  [%s] %s", now - row.at, row.kind, row.text)
        end
        if #out == 0 then out[1] = "(nothing yet)" end
        return out
    end

    --- One line for the overview page.
    ---@return string
    function R.summary()
        local mode, context = behavior.current()
        local last = last_selected and string.format("   last: %s %.0fs ago", last_selected.name,
            clock() - (last_selected.at or 0)) or ""
        return string.format("on, %s%s%s", mode, context and (" + " .. context) or "", last)
    end

    function R.stats()
        local mode, context, why = behavior.current()
        return {
            active = R.active(), mode = mode, context = context, why = why,
            rules = #engine.rules(), handled = memory.handled_count(),
            last = last_selected and last_selected.name or nil,
        }
    end

    -- --- the overlay ------------------------------------------------------------------------
    --
    -- A SHORT version of the readout, in a window that is dragged by its title
    -- bar and remembered where it was left -- the same JCore window the spell
    -- window uses. The first version sat at a fixed spot on the left, which is
    -- exactly where the threat panel is drawn, and its top ran under the
    -- hardcore low-health banner: both of which are showing when a reaction is
    -- most worth reading. The default spot is the right-hand side, below the
    -- guide panel and above the spell window, clear of all three.

    --- The overlay's lines: the mode, what was chosen and its top reasons,
    --- what came next, what was refused, the last reaction. At most a dozen.
    ---@return string[]
    function R.overlay_lines()
        local now = clock()
        wanted_at = now
        local s = snap
        if not s or (now - (s.at or now)) > 1.5 then return { "Rotation: " .. rotation_state(s, now) } end
        local out = {}
        out[#out + 1] = string.format("%s%s   danger %d", s.mode or "?",
            s.context and (" + " .. s.context) or "", s.danger)
        if s.plan_short then out[#out + 1] = s.plan_short end
        local first = nil
        for _, pair in ipairs({ { "GCD", s.gcd }, { "Off-GCD", s.fast }, { "Pet", s.pet } }) do
            local row = pair[2]
            if row then
                out[#out + 1] = string.format("%s: %s  %d%s", pair[1], row.name, row.score,
                    row.target ~= "" and ("  -> " .. row.target) or "")
                first = first or row
            end
        end
        if first then
            for i = 2, math.min(#first.reasons, 4) do out[#out + 1] = "    " .. first.reasons[i] end
        else
            local rc = s.rotation_cands or {}
            local pick = nil
            for i = 1, #rc do if rc[i].state == "pressed" then pick = rc[i] break end end
            if pick then
                out[#out + 1] = string.format("Rotation: %s  %.1f", pick.name, pick.score)
                for i = 1, math.min(#pick.reasons, 2) do out[#out + 1] = "    " .. pick.reasons[i] end
            else
                out[#out + 1] = "Rotation: " .. rotation_state(s, now)
            end
        end
        if s.holds[1] then out[#out + 1] = "Holding: " .. (s.holds[1].why or s.holds[1].rule) end
        local others = {}
        for i = 1, math.min(#s.others, 3) do
            others[i] = string.format("%s %d", s.others[i].name, s.others[i].score)
        end
        if #others > 0 then out[#out + 1] = "Next: " .. table.concat(others, ", ") end
        if s.rejected[1] then
            out[#out + 1] = string.format("Refused %s: %s", s.rejected[1].name, s.rejected[1].rejected or "?")
        end
        if last_selected then
            out[#out + 1] = string.format("Last: %s %.1fs ago", last_selected.name, now - (last_selected.at or now))
        end
        return out
    end

    local OVERLAY_ID = "react_overlay"
    local OVERLAY_W, ROW_H, PAD, FALLBACK_BAR = 380, 15, 8, 22

    --- The title bar: a JCore window when the overlay UI is there, our own
    --- bar otherwise. Returns the window's top-left and the bar's height, or
    --- nil when it is folded away.
    local function title_bar(x, y, layer)
        local UI = P.JCore and P.JCore.ui
        local ui = ctx and ctx.ui
        if ui and ui.begin_window and UI and type(UI.theme) == "table" then
            local theme = UI.theme
            local bar = math.floor((theme.title_h or 24) * (theme.scale or 1) + 0.5)
            local ok, open, win = pcall(ui.begin_window, ui, OVERLAY_ID, {
                title = "Reactions", x = x, y = y, w = OVERLAY_W, h = bar, min_w = OVERLAY_W,
                collapsible = true, closable = false, scroll = false, padding = 0,
            })
            -- Always paired, whatever begin answered.
            pcall(ui.end_window, ui)
            if ok and type(win) == "table" then
                if win.collapsed or win.visible == false then return nil end
                if open then return win.x, win.y, bar end
                x, y = win.x or x, win.y or y
            end
        end
        P.draw.rect_2d({ x = x, y = y }, OVERLAY_W, FALLBACK_BAR, P.color(30, 34, 46, 230),
            { filled = true, layer = layer })
        P.draw.text_2d({ x = x + 10, y = y + 4 }, "Reactions", P.color(235, 235, 240, 255),
            { layer = layer, size = 13 })
        return x, y, FALLBACK_BAR
    end

    function R.render()
        if not (P.opt and P.opt("react_overlay", false)) then return end
        if P.master_on and not P.master_on() then return end
        local draw = P.draw
        if not draw or not draw.text_2d or not draw.rect_2d or not draw.screen_size then return end
        local w, h = draw.screen_size()
        if not w or w <= 0 or not h or h <= 0 then return end

        local layer = ctx.LAYER and ctx.LAYER.HUD or 500
        local x, y, bar = title_bar(math.floor(w - OVERLAY_W - 24), math.floor(h * 0.38), layer)
        if not x then return end
        x, y = math.floor(x), math.floor(y)

        local lines = R.overlay_lines()
        local body_h = #lines * ROW_H + PAD * 2
        local y0 = y + bar
        -- A card under the title bar (1.89.0): JCore 1.15's plate, soft-edged
        -- with a shadow when shader drawing is on; flat without it.
        local body_col = P.color(10, 12, 18, 200)
        if draw.plate_2d then
            draw.plate_2d({ x = x, y = y0 }, OVERLAY_W, body_h, body_col, { layer = layer, rounding = 3 })
        else
            draw.rect_2d({ x = x, y = y0 }, OVERLAY_W, body_h, body_col, { layer = layer, filled = true })
        end
        for i = 1, #lines do
            local line = lines[i]
            local col = (i == 1) and P.color(255, 210, 120, 255)
                or (line:find("^GCD") or line:find("^Off%-GCD") or line:find("^Pet:")) and P.color(140, 230, 140, 255)
                or (line:find("^Holding") or line:find("^Refused")) and P.color(240, 140, 120, 255)
                or P.color(215, 215, 225, 235)
            draw.text_2d({ x = x + PAD, y = y0 + PAD + (i - 1) * ROW_H }, line, col,
                { layer = layer, size = 12 })
        end
    end

    if ctx and ctx.render then
        ctx.render(function() R.render() end, { priority = 208 })
    end

    --- Forgets everything, for the Debug page's reset button.
    function R.reset()
        memory.reset()
        detect.reset(clock())
        behavior.reset(clock())
        tactics.reset()
        journal_rows, journal_seen, snap, last_selected, pending_start = {}, {}, nil, nil, nil
    end

    return R
end

-- Jambix AIO / react / intel -- the PvP intelligence layer (PVP_INTEL_PLAN.md).
--
-- WHAT IS HERE, AND WHAT IS NOT
-- Phase 2 (Stage 1): the state model, state.lua -- one picture of the PvP
-- fight, built once a tick into W.intel from what the reactions already
-- read, with every field marked observed, inferred (with a confidence) or
-- unknown. Nothing here decides, and nothing here casts: the later stages
-- (threat, cooldowns, prediction...) read this table, and their
-- recommendations go out as reactions through the one engine (ctx.react).
--
-- WHEN IT RUNS
-- init.lua's R.tick calls I.update(W, now) after pvp.read has filled W.pvp
-- and before the situations are read, so every rule and every later stage
-- sees the same picture. With the switch off (intel_enabled), or with no
-- enemy player about, the table only says so: nothing is read.
--
-- WHAT IT LISTENS TO (the engine already receives these; this adds the
-- handlers the state model asked for, each filtering on its first line)
--   UNIT_SPELLCAST_START / SUCCEEDED / INTERRUPTED / CHANNEL_START
--                  for units that are not us, the pet or the group:
--                  another player's cast, by its unit token
--   UNIT_AURA      "added" records for the same units: a cooldown's aura
--   COMBAT_LOG_EVENT_UNFILTERED   Era only: SPELL_CAST_SUCCESS by a hostile
--                  player (on Forever the event has no arguments)
--   DUEL_REQUESTED / DUEL_FINISHED, PLAYER_ENTERING_WORLD, UNIT_PET
--   jcore.unit.removed, jcore.zone.changed, jcore.player.died, jcore.combat.leave

return function(P, lib)
    local ctx = P.ctx
    local load = P.load or function(path) return require("jambix_aio/" .. path) end

    local I = {}

    -- The game's Lua is a sandbox: no `os` table (seen live on Forever,
    -- 2026-10-12: "attempt to index global 'os' (a nil value)" from the
    -- debrief on your death), and no promise of `_G` or `rawget`. The wall
    -- clock is the realm's (core.get_server_time), else the PC's where
    -- `os` exists, else nil; nothing here indexes a global it has not
    -- checked first.
    if lib.wall_time == nil then
        lib.wall_time = function()
            if type(core) == "table" and type(core.get_server_time) == "function" then
                local ok, s = pcall(core.get_server_time)
                s = ok and tonumber(s) or nil
                if s and s > 0 then return math.floor(s) end
            end
            if type(os) == "table" and type(os.time) == "function" then
                local ok, s = pcall(os.time)
                s = ok and tonumber(s) or nil
                if s and s > 0 then return s end
            end
            return nil
        end
    end
    -- Random ids (contributors, fights, records, episodes): the generator
    -- is seeded once with what differs between two machines starting the
    -- same second -- a fresh table's address, the session clock's
    -- fraction, the wall clock, the local player's id (hashed into the
    -- seed only, never stored or sent) -- so two players never draw the
    -- same sequence. An unseeded generator would hand every player the
    -- same contributor id and the same record ids.
    if lib.random_hex == nil then
        local seeded = false
        local function seed()
            seeded = true
            local parts = { tostring({}), tostring(lib.wall_time() or 0) }
            if type(core) == "table" and type(core.time) == "function" then
                local ok, t = pcall(core.time)
                if ok then parts[#parts + 1] = string.format("%.6f", tonumber(t) or 0) end
            end
            local okp, me = pcall(function()
                local pl = core.object_manager.get_local_player()
                return pl and pl.get_guid and tostring(pl:get_guid()) or nil
            end)
            if okp and me then parts[#parts + 1] = me end
            local s, h = table.concat(parts, "|"), 5381
            for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
            if type(math.randomseed) == "function" then pcall(math.randomseed, h) end
            -- A few draws thrown away: some generators' first ones follow the seed closely.
            for _ = 1, 8 do math.random() end
        end
        lib.random_hex = function(n)
            if not seeded then seed() end
            local t = {}
            for i = 1, n do t[i] = string.format("%x", math.random(0, 15)) end
            return table.concat(t)
        end
    end

    -- A player's death needs the game's word on a unit that is still there.
    -- JCore's units.is_dead answers true for a unit that has GONE ("gone is
    -- as good as dead to every caller" -- right for targeting, wrong for a
    -- fight's outcome): live on 2026-10-12 a rogue's Vanish and a druid
    -- slipping out of sight were both recorded as deaths, two fights as
    -- won. A unit that is no longer valid has left; it did not die.
    if lib.unit_dead == nil then
        lib.unit_dead = function(unit)
            if not unit then return false end
            local okv, valid = pcall(function() return unit:is_valid() end)
            if not okv or valid ~= true then return false end
            local okd, dead = pcall(function() return unit:is_dead() end)
            return okd and dead == true
        end
    end

    local state = load("modules/react/intel/state")(P, lib)
    -- The one way a later module reads an inference: with a threshold.
    lib.sure = state.sure
    -- Stage 2: the threat read, on the picture, with its weights written
    -- down (score.lua) and the class facts it reads (data.lua).
    local data = load("modules/react/intel/data")
    local weights = load("modules/react/intel/score")
    local threat = load("modules/react/intel/threat")(P, lib, data, weights)
    -- Stage 3: the cooldown ledger and the economy questions, with what the
    -- clients' own tables say about each ability (pvp_data.lua, generated by
    -- tools/jcheck/pvp_extract.js; absent, every cooldown is unknown).
    if lib.pvp_data == nil then
        local ok, pd = pcall(load, "modules/pvp_data")
        lib.pvp_data = (ok and type(pd) == "table") and pd or nil
    end
    local cooldowns = load("modules/react/intel/cooldowns")(P, lib, data, weights)
    lib.cooldowns = cooldowns
    -- Stage 6: the control plan (every control on every player, whose,
    -- what breaks it, its diminishing returns, what it is worth), on the
    -- ledger (the breakers' cooldowns, the tables' durations).
    local ccplan = load("modules/react/intel/ccplan")(P, lib, data, weights)
    -- Stage 7: what each player tends to do, from this session's
    -- observations (after the plan: it watches our control landing).
    -- The central fight database (asked for 2026-10-12): the predictor's
    -- priors come down from it, the debriefs go up; loaded before the
    -- predictor so a new player's pattern can start at the database's rate.
    lib.my_class = function()
        local rot = P.rotation
        if not (rot and rot.detect_class) then return nil end
        local ok, name = pcall(rot.detect_class)
        return ok and name or nil
    end
    -- The field checks: the game's own answers to what was assumed (item 6
    -- of the user's relook, 2026-10-12).
    local fieldcheck = load("modules/react/intel/fieldcheck")(P, lib, data, weights)
    lib.fieldcheck = fieldcheck
    local last_W = nil
    local central = load("modules/react/intel/central")(P, lib, data, weights)
    lib.central = central
    local predict = load("modules/react/intel/predict")(P, lib, data, weights)
    lib.predict_inputs = predict.inputs_text
    -- Stage 8: the baits, on the predictions, the threat, the ledger and
    -- the control plan.
    local bait = load("modules/react/intel/bait")(P, lib, data, weights)
    -- Stage 9: the kill window, on the picture, the ledger, the threat and
    -- the predictor; read by the states, the burst and the PvP hunter.
    local killwindow = load("modules/react/intel/killwindow")(P, lib, data, weights)
    lib.killwindow = killwindow
    -- Stage 10: the teamfight, on the picture, the kill window and the control plan.
    local team = load("modules/react/intel/team")(P, lib, data, weights)
    lib.team = team
    -- Stage 4: the tactical state, the ground, and the words.
    local states = load("modules/react/intel/states")(P, lib, data, weights)
    local position = load("modules/react/intel/position")(P, lib, data, weights)
    local explain = load("modules/react/intel/explain")(P, lib, weights)
    -- The decision episodes (the collector): a window round each tactical
    -- opportunity, with the state before and after, the prediction and the
    -- recommendation as they stood, and what came of them.
    local episodes = load("modules/react/intel/episodes")(P, lib, data, weights)
    lib.episodes = episodes
    -- Stage 11-a: the lessons of each fight, after everything else has read the tick.
    local debrief = load("modules/react/intel/debrief")(P, lib, data, weights)
    lib.debrief = debrief
    I.state, I.threat, I.cooldowns, I.data, I.weights = state, threat, cooldowns, data, weights
    I.states, I.position, I.explain, I.cc, I.predict, I.bait = states, position, explain, ccplan, predict, bait
    I.kill, I.team = killwindow, team
    I.debrief, I.central, I.episodes, I.fieldcheck = debrief, central, episodes, fieldcheck
    I.S = state.S
    I.S.threat = threat.T
    I.S.cds = cooldowns.T
    I.S.cc = ccplan.T
    I.S.predict = predict.T
    I.S.bait = bait.T
    I.S.kill = killwindow.T
    I.S.team = team.T
    I.S.debrief = debrief.T
    I.S.tactic = states.T
    I.S.pos = position.T
    I.summary = explain.summary
    -- The names the Reactions window's readers ask about (custom.lua), so
    -- they never carry a list of their own.
    I.S.mobility_names = data.MOBILITY
    I.S.protection_names = data.PROTECTION
    I.sure = state.sure
    I.inferred = state.inferred
    I.stats = state.stats

    --- The readout's rows: the picture's, with the threat on the first.
    function I.lines()
        local out = state.lines()
        local S = state.S
        if S.active and not S.off then
            local line = out[1] or ""
            local cut = line:find(" | ", 1, true)
            local head = cut and line:sub(1, cut - 1) or line
            local rest = cut and line:sub(cut) or ""
            out[1] = head .. " | " .. threat.line() .. rest
            local cds = cooldowns.line(S)
            if cds then out[2] = (out[2] or "Intel:") .. " | " .. cds end
            local cc = ccplan.line(S)
            if cc then out[2] = (out[2] or "Intel:") .. " | " .. cc end
            -- The third row: the state, the move, and what the target tends to do.
            local st, mv, pr, bt = states.line(), position.line(), predict.line(S), bait.line(S)
            local kw = (killwindow.T.target and killwindow.T.line ~= "") and killwindow.T.line or nil
            if st or mv or pr or bt or kw then
                local bits = {}
                if st then bits[#bits + 1] = st end
                if mv then bits[#bits + 1] = mv end
                if kw then bits[#bits + 1] = kw end
                if pr then bits[#bits + 1] = pr end
                if bt then bits[#bits + 1] = bt end
                out[3] = "Intel: " .. table.concat(bits, " | ")
            end
            -- A fourth row only in a fight with more than one player a side.
            local tm = team.line()
            if tm then out[#out + 1] = "Intel: " .. tm end
        end
        return out
    end

    local function clock() return core.time() end

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    --- The layer's emergency switch (the Reactions page, *Advanced PvP
    --- Intelligence*): off, nothing of the layer runs.
    function I.enabled()
        return opt("intel_enabled", true) == true
    end

    --- One module's switch (the same page): threat, cooldowns, tactics,
    --- position, kill, team, cc, predict, bait, learn.
    function I.module_on(name)
        return opt("intel_" .. name, true) == true
    end

    --- Once a tick, after W.pvp: the picture, or a cheap "off".
    ---@param W table
    ---@param now number
    ---@return table S
    -- The hold, kept. The hold reaction halts the rotation's walk, but an
    -- attack already running goes on: live on 2026-10-12 a Freezing Trap
    -- broke with 2.4 s left while the hold stood three times. So while the
    -- control plan holds the player you have targeted, a running auto attack
    -- (Auto Shot or the swing) is stopped -- on every client, at most once
    -- every hold_restop seconds. Nothing is cast; only the attack stops.
    local HOLD_RESTOP = 2.0
    local hold_stop = { key = nil, at = -math.huge, stops = 0 }
    I.hold_stop = hold_stop
    local function enforce_hold(W, S, now)
        local h = S.cc and S.cc.hold or nil
        if not h or h.guid == nil or h.guid ~= (S.env and S.env.target and S.env.target.guid) then
            hold_stop.key = nil
            return
        end
        local pl = W.player
        if not (pl and (pl.auto_attacking == true or pl.shooting == true)) then return end
        local key = tostring(h.guid) .. "|" .. tostring(h.name)
        if hold_stop.key == key and (now - hold_stop.at) < HOLD_RESTOP then return end
        local input = type(core) == "table" and core.input or nil
        if not (input and type(input.stop_attack) == "function") then return end
        if pcall(input.stop_attack) then
            if hold_stop.key ~= key and P.log and P.log.fmt then
                P.log.fmt("info", "intel hold: the attack stopped -- %s", tostring(h.why))
            end
            hold_stop.key, hold_stop.at, hold_stop.stops = key, now, hold_stop.stops + 1
            h.attack_stopped = true
        end
    end

    function I.update(W, now)
        if not I.enabled() then
            W.intel = state.idle(now, "switched off")
            threat.reset()
            ccplan.reset()
            predict.reset()
            bait.reset()
            killwindow.reset()
            team.reset()
            states.reset()
            position.reset()
            return W.intel
        end
        W.intel = state.build(W, now)
        -- Each module behind its own switch; off, its table reads calm.
        if I.module_on("threat") then threat.update(W, W.intel, now) else threat.reset() end
        if I.module_on("cooldowns") then cooldowns.update(W, W.intel, now) else cooldowns.reset() end
        if I.module_on("cc") then ccplan.update(W, W.intel, now) else ccplan.reset() end
        if I.module_on("cc") then enforce_hold(W, W.intel, now) end
        if I.module_on("predict") then predict.update(W, W.intel, now) else predict.reset() end
        if I.module_on("bait") then bait.update(W, W.intel, now) else bait.reset() end
        if I.module_on("kill") then killwindow.update(W, W.intel, now) else killwindow.reset() end
        if I.module_on("team") then team.update(W, W.intel, now) else team.reset() end
        if I.module_on("tactics") then states.update(W, W.intel, now) else states.reset() end
        if I.module_on("position") then position.update(W, W.intel, now) else position.reset() end
        explain.update(W.intel, now)
        episodes.update(W, W.intel, now)
        debrief.update(W, W.intel, now)
        last_W = W
        local okf, errf = pcall(fieldcheck.update, W, W.intel, now)
        if not okf and P.log and type(P.log.once) == "function" then pcall(P.log.once, "warn", "fieldcheck", "field checks failed: " .. tostring(errf)) end
        -- The network's client last: the uploads and the downloads, both
        -- asynchronous; nothing above waited on it.
        central.update(W, W.intel, now)
        return W.intel
    end

    function I.reset()
        state.reset()
        threat.reset()
        cooldowns.reset()
        ccplan.reset()
        predict.reset()
        bait.reset()
        states.reset()
        position.reset()
        explain.reset()
        episodes.reset()
        debrief.reset()
    end

    -- --- the events ---------------------------------------------------------------------

    if ctx and ctx.on then
        local function cast_event(kind, spell_at)
            return function(args)
                if type(args) ~= "table" then return end
                local token = args[1]
                -- Our own and the group's are the engine's and the rotation's
                -- business; the first line keeps the raid's volume out.
                if token == "player" or token == "pet" then return end
                state.on_cast(token, args[spell_at], kind, clock())
            end
        end
        ctx.on("jcore.game_event.UNIT_SPELLCAST_START", cast_event("start", 3))
        ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", cast_event("cast", 3))
        ctx.on("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", cast_event("interrupted", 3))
        -- The channel events carry no cast guid: args[2] is a hole, the
        -- spell id stays at 3 (the .api's note).
        ctx.on("jcore.game_event.UNIT_SPELLCAST_CHANNEL_START", cast_event("channel", 3))

        -- Our own casts, for the predictor (Stage 7): a slow or a burst we
        -- pressed opens a chance for the target's pattern; our cast
        -- interrupted is a player's doing.
        ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
            if type(args) ~= "table" or args[1] ~= "player" then return end
            pcall(fieldcheck.on_our_cast, lib.spell_name and lib.spell_name(tonumber(args[3])) or nil, last_W, state.S, clock())
            debrief.on_our_cast(args[3], state.S.env.target.guid, clock())
            episodes.on_our_cast(lib.spell_name and lib.spell_name(tonumber(args[3])) or nil, state.S.env.target.guid, clock())
            if not I.module_on("predict") then return end
            predict.on_our_cast(state.S, args[3], state.S.env.target.guid, clock())
        end)
        -- Your death closes the fight's record before the picture forgets
        -- everyone (the handler below runs after this one).
        ctx.on("jcore.player.died", function()
            -- Each on its own: one failing never keeps the other from the
            -- death (live 2026-10-12 the debrief's failure ended the handler).
            for _, m in ipairs({ { "episodes", episodes }, { "debrief", debrief } }) do
                local ok, err = pcall(m[2].on_death, state.S, clock())
                if not ok and P.log and P.log.fmt then P.log.fmt("warn", "intel: %s on your death failed: %s", m[1], tostring(err)) end
            end
        end)
        ctx.on("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", function(args)
            if type(args) ~= "table" or args[1] ~= "player" then return end
            if not I.module_on("predict") then return end
            predict.on_our_interrupted(state.S, args[3], clock())
        end)

        ctx.on("jcore.game_event.UNIT_AURA", function(args)
            if type(args) ~= "table" or args[1] ~= "added" then return end
            local token = args[2]
            if token == "player" or token == "pet" then return end
            local guid = state.on_aura(token, args[4], args[5], args[10] == true, clock())
            -- One of our controls landing on a player: its duration, for the field checks.
            if guid and args[9] == "player" then pcall(fieldcheck.on_control_aura, guid, args[5], args[7], clock()) end
        end)
        -- JCore's cast requests (the sting sent at an add) and the rotation's
        -- word that a spell it called castable never went out.
        ctx.on("jcore.cast.sent", function(request) pcall(fieldcheck.on_sent, request, state.S, clock()) end)
        ctx.on("jambix.aio.rotation_stuck", function(name) pcall(fieldcheck.on_stuck, name, clock()) end)

        -- Era: the combat log names a hostile player's instant casts by
        -- guid. On Forever the event arrives empty; filtered on its second
        -- field, so a raid's hits cost one comparison each.
        if lib.client == nil or lib.client.combat_log ~= false then
            ctx.on("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", function(a)
                if type(a) ~= "table" or a[2] ~= "SPELL_CAST_SUCCESS" then return end
                state.on_combat_log(a[4], a[6], a[12], a[13], clock())
            end)
        end

        ctx.on("jcore.game_event.DUEL_REQUESTED", function() state.on_duel("DUEL_REQUESTED", clock()) end)
        ctx.on("jcore.game_event.DUEL_FINISHED", function() state.on_duel("DUEL_FINISHED", clock()) end)

        ctx.on("jcore.unit.removed", function(guid) state.on_unit_removed(guid) end)
        ctx.on("jcore.zone.changed", function() state.invalidate("zone changed") end)
        ctx.on("jcore.player.died", function() state.invalidate("you died") end)
        ctx.on("jcore.game_event.PLAYER_ENTERING_WORLD", function() state.invalidate("entering the world") end)
        ctx.on("jcore.combat.leave", function() state.combat_end() end)
    end

    return I
end

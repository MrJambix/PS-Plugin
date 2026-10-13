-- Jambix AIO / react / intel / states -- what kind of moment this is, in a
-- fight with players (PvP intelligence, Stage 4 / brief Phase 3).
--
-- behavior.lua answers "how much trouble am I in" (NORMAL .. ESCAPE) for
-- every fight. Against a player the question has more answers than that:
-- is this the opening, am I keeping a warrior off me, is its burst up, is
-- it frozen in my trap, is its healer free, is my healer being hit, is the
-- flag the point? The brief names eighteen tactical states; each is a row
-- below with what makes it, what it recommends, what it says not to do,
-- what it keeps back, how it ranks and how sure it is.
--
-- HOW ONE IS CHOSEN. Every state is asked each tick (enter). The emergency
-- ones (DISENGAGE, ANTI_BURST, DEFENSIVE) take over the moment they hold.
-- Otherwise the state in force keeps for DWELL seconds while it still
-- holds, and the highest-ranked candidate replaces it after that, or at
-- once when it no longer holds -- so the state does not flicker between
-- two true things, and never finishes a sequence it has no reason to.
--
-- Nothing here casts. The actions are NAMES the readout shows and the
-- later stages weigh; the one rule file that acts (rules/intel.lua) reads
-- S.pos, not this. Every number is in score.lua TACTIC.

return function(P, lib, data, K)
    local book = P.spellbook
    local units = P.units
    local M = {}
    local huge, max, min = math.huge, math.max, math.min
    local KT = K.TACTIC
    local RANK = K.RANK

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function H() return (P.rotation and P.rotation.helpers) or {} end

    --- A module's switch on the Reactions page (kill, team).
    local function module_on(name)
        if not P.opt then return true end
        local v = P.opt("intel_" .. name, true)
        return v == nil or v == true
    end

    -- Our slows on a player: the PvP hunter's list (rules/hunter_pvp.lua).
    local SLOWS = { "Wing Clip", "Improved Wing Clip", "Concussive Shot", "Frost Trap Aura", "Entrapment", "Counterattack" }
    local function slowed(unit)
        local h = H()
        if not unit or not h.debuff_up then return false end
        for i = 1, #SLOWS do
            if try(h.debuff_up, unit, SLOWS[i]) == true then return true end
        end
        return false
    end

    --- Our control that damage breaks on a unit (pvphunter.held): kind, left.
    local function held(unit)
        local ph = P.pvphunter
        if not (ph and ph.held and unit) then return nil, 0 end
        local ok, kind, left = pcall(ph.held, unit)
        if ok and kind then return kind, left or 0 end
        return nil, 0
    end

    local function known_list(names, out)
        for i = #out, 1, -1 do out[i] = nil end
        for i = 1, #names do
            if book.known(names[i]) then out[#out + 1] = names[i] end
        end
        return out
    end

    -- --- the context, once a tick ------------------------------------------------

    local X = {}

    local function melee_foe_on_me(S)
        local best = nil
        for i = 1, #S.foe_list do
            local f = S.foe_list[i]
            if f.targets_me and f.dist <= (S.env.melee_range or 5) + 1 then
                if not best or f.dist < best.dist then best = f end
            end
        end
        return best
    end

    local function melee_foe_closing(S)
        for i = 1, #S.foe_list do
            local f = S.foe_list[i]
            if (f.targets_me or f.in_combat) and f.inferred.role.v == "melee" and f.inferred.role.conf >= 0.6
                and f.dist > (S.env.melee_range or 5) and (f.time_to_reach or huge) <= KT.closing_within then
                return f
            end
        end
        return nil
    end

    local function vulnerable_ally_targeted(S)
        for i = 1, #S.foe_list do
            local f = S.foe_list[i]
            if f.targets_ally then
                local ally = S.allies[f.target_guid]
                if ally and (ally.healer or (ally.hp or 1) < 0.5) then return f, ally end
            end
        end
        return nil
    end

    local function melee_on_ally(S)
        for i = 1, #S.foe_list do
            local f = S.foe_list[i]
            if f.targets_ally and f.inferred.role.v == "melee" and f.inferred.role.conf >= 0.6 then
                return f, S.allies[f.target_guid]
            end
        end
        return nil
    end

    local function burst_ended(f, now)
        if not f or not f.cds then return nil end
        for name, e in pairs(f.cds) do
            local row = lib.pvp and lib.pvp.ENEMY and lib.pvp.ENEMY[name] or nil
            if row and row.burst and e.state == "down" and e.seen_at then
                local age = now - e.seen_at
                local dur = lib.cooldowns and lib.cooldowns.fact and (lib.cooldowns.fact(name, f.class) or {}).duration or nil
                local ended = dur and (age > dur) or (age > 15)
                if ended and age <= (dur or 15) + KT.counter_window then return name, age end
            end
        end
        return nil
    end

    -- --- the states ---------------------------------------------------------------
    --
    -- enter(X) -> ok, why, conf.  actions / avoid / reserve: names.

    local STATES = {
        { name = "DISENGAGE", priority = 100, emergency = true,
          enter = function(X)
              local T = X.T
              if X.W.mode == "ESCAPE" or (X.W.sit and X.W.sit.flee) then
                  return true, "the fight cannot be won: " .. tostring(X.W.mode_why or "escape"), 0.9
              end
              if T.level == "CRITICAL" and (X.me.defensives_ready or 0) == 0 and #X.C.protection.names == 0 then
                  return true, "CRITICAL threat with no defensive ready", 0.85
              end
              return false
          end,
          actions = { "Feign Death", "break line of sight", "run to allies" },
          avoid = { "Aimed Shot", "Serpent Sting", "Multi-Shot" } },

        { name = "ANTI_BURST", priority = 95, emergency = true,
          enter = function(X)
              local V = X.W.pvp
              local b = V and V.burster
              if not (b and b.st and b.st.burst) then return false end
              return true, string.format("%s bursting on you (%s)", X.S.foes[b.guid] and X.S.foes[b.guid].name or "a player",
                  tostring(b.st.burst_name)), 1.0
          end,
          actions = function(X, out)
              local a = X.S.cds.answer
              for i = #out, 1, -1 do out[i] = nil end
              if a and a.verdict == "preserve" then
                  out[1] = "keep your defensives: " .. a.why
              elseif a and a.verdict == "cheapest" then
                  out[1] = a.name
              else
                  out[1] = "no defensive answers it: escape, control or line of sight"
              end
              return out
          end,
          avoid = { "a second defensive while covered", "Aimed Shot" } },

        -- Also: you held by a player's control you cannot act through (the
        -- scenario suite, 2026-10-12: polymorphed, the advice was still
        -- Aimed Shot). Nothing of ours can be cast; the break-control
        -- reaction decides the trinket.
        { name = "DEFENSIVE", priority = 90, emergency = true,
          enter = function(X)
              local T = X.T
              local c = X.me.control
              if c and c.helpless and c.from_player ~= false and (c.left or 0) >= KT.controlled_left then
                  return true, string.format("you are held: %s %.1fs (%s%s)", tostring(c.kind), c.left or 0, tostring(c.name or "?"),
                      c.from_player and ", a player's" or ""), 0.95
              end
              if RANK[T.level] >= RANK.HIGH then return true, "threat " .. T.level .. " (" .. tostring(T.highest and T.highest.why or "") .. ")", 0.9 end
              if X.W.sit and X.W.sit.hp_low and X.S.attackers > 0 then return true, "low health with a player on you", 0.95 end
              return false
          end,
          actions = function(X, out)
              for i = #out, 1, -1 do out[i] = nil end
              local c = X.me.control
              if c and c.helpless and (c.left or 0) >= KT.controlled_left then
                  -- A breaker you can press under this control, ready (Stage 13).
                  for _, b in ipairs(data.SELF_BREAKERS) do
                      if b.under[c.kind or ""] and book.known(b.name) and book.ready(b.name) then
                          out[#out + 1] = string.format("%s (it breaks the %s)", b.name, tostring(c.kind))
                          break
                      end
                  end
                  out[#out + 1] = "the trinket if it costs more than the trinket is worth (the break-control reaction decides)"
                  out[#out + 1] = "nothing else can be cast: queue nothing"
                  return out
              end
              local list = lib.cooldowns.cheapest(X.S.melee_attackers > 0 and "melee" or "spell", X.S)
              for i = 1, min(3, #list) do out[#out + 1] = list[i].name end
              if #out == 0 then out[1] = "no defensive ready: slow and step away" end
              return out
          end,
          avoid = { "Aimed Shot while hit", "a second defensive while covered" } },

        -- A dangerous cast at you; in a group (Stage 10, team.lua) also a
        -- heal on a low enemy or a control at an ally, the first in order a
        -- stopper of ours reaches.
        { name = "INTERRUPT_OPPORTUNITY", priority = 85,
          enter = function(X)
              local T = X.T
              if T.incoming_cast then
                  local stopper = nil
                  if book.known("Scatter Shot") and book.ready("Scatter Shot") then stopper = "Scatter Shot" end
                  if not stopper and book.known("Intimidation") and book.ready("Intimidation") and X.S.pet.on_player then stopper = "Intimidation" end
                  if not stopper and book.known("Feign Death") and book.ready("Feign Death") then stopper = "Feign Death" end
                  if stopper then return true, "a dangerous cast at you and " .. stopper .. " ready", 1.0 end
              end
              local c = module_on("team") and X.S.team and X.S.team.interrupt or nil
              if c and (c.kind == "heal" or c.kind == "control") and RANK[T.level] < RANK.HIGH then
                  return true, c.why, 0.8
              end
              return false
          end,
          actions = function(X, out)
              for i = #out, 1, -1 do out[i] = nil end
              local c = not X.T.incoming_cast and X.S.team and X.S.team.interrupt or nil
              if c and c.tool then out[1] = c.tool .. " on " .. c.name return out end
              out[1], out[2], out[3] = "Scatter Shot", "Intimidation", "Feign Death"
              return out
          end },

        { name = "CONTROL_DISTANCE", priority = 80,
          enter = function(X)
              local f = X.melee_on_me or X.melee_closing
              if not f then return false end
              if f.st and f.st.burst then return false end       -- ANTI_BURST's
              if held(f.unit) then return false end              -- frozen: CROWD_CONTROL_SETUP's / RESET_FIGHT's
              local why = X.melee_on_me and string.format("%s in melee%s", f.name, slowed(f.unit) and ", slowed" or ", not slowed")
                  or string.format("%s closing, %.1fs to reach you", f.name, f.time_to_reach or 0)
              return true, why, max(0.6, f.inferred.role.conf)
          end,
          actions = function(X, out)
              for i = #out, 1, -1 do out[i] = nil end
              local f = X.melee_on_me or X.melee_closing
              if X.melee_on_me then
                  if not slowed(f.unit) then out[#out + 1] = "Wing Clip" end
                  out[#out + 1] = "step out past the dead zone"
                  if book.known("Aspect of the Monkey") then out[#out + 1] = "Aspect of the Monkey" end
                  if book.known("Freezing Trap") then out[#out + 1] = "Freezing Trap once the clip does not shake it" end
              else
                  out[#out + 1] = "Concussive Shot"
                  out[#out + 1] = "keep the distance"
              end
              return out
          end,
          avoid = { "Aimed Shot in melee", "Multi-Shot on one" },
          reserve = { "Scatter Shot" } },

        { name = "CROWD_CONTROL_SETUP", priority = 75,
          enter = function(X)
              local tg = X.tg
              if not tg then return false end
              local kind, left = held(tg.unit)
              if kind and left >= 1 then return true, string.format("%s held by your %s (%.1fs)", tg.name, kind, left), 1.0 end
              return false
          end,
          actions = { "no damage on it", "shoot another", "Freezing Trap under a scattered player" },
          avoid = { "Serpent Sting", "Multi-Shot", "Summon Hawk", "Auto Shot on it" } },

        { name = "RESET_FIGHT", priority = 78,
          enter = function(X)
              local tg = X.tg
              if not tg then return false end
              local kind, left = held(tg.unit)
              if kind == "trap" and left >= KT.reset_left then
                  return true, string.format("%s frozen for %.1fs: walk to the opener's distance", tg.name, left), 1.0
              end
              return false
          end,
          actions = { "walk to 25 yd", "Aimed Shot from range" },
          avoid = { "any damage on it" } },

        -- The team module's peel (Stage 10) names the enemy, the ally and our
        -- tool that reaches it; without it, the old read.
        { name = "PROTECT_ALLY", priority = 70,
          enter = function(X)
              if not module_on("team") or RANK[X.T.level] >= RANK.HIGH then return false end
              local p = X.S.team and X.S.team.peel or nil
              if p then return true, p.why, p.action and 0.9 or 0.7 end
              local f, ally = vulnerable_ally_targeted(X.S)
              if not f then return false end
              return true, string.format("%s on %s (%s)", f.name, ally.name, ally.healer and "the healer" or "hurt"), 0.9
          end,
          actions = function(X, out)
              for i = #out, 1, -1 do out[i] = nil end
              local p = X.S.team and X.S.team.peel or nil
              if p and p.action then out[#out + 1] = p.action .. " on " .. p.name end
              local base = { "Concussive Shot on it", "Wing Clip", "Scatter Shot", "Intimidation" }
              for i = 1, #base do
                  if not (p and p.action and base[i]:find(p.action, 1, true)) then out[#out + 1] = base[i] end
              end
              return out
          end },

        { name = "PEEL_ENEMY", priority = 68,
          enter = function(X)
              if not module_on("team") or RANK[X.T.level] >= RANK.HIGH then return false end
              local f, ally = melee_on_ally(X.S)
              if not f then return false end
              if held(f.unit) then return false end
              local o = X.S.team and X.S.team.overlap or nil
              if o and o.guid == f.guid then return false end      -- an ally's control on it: leave it be
              return true, string.format("%s meleeing %s", f.name, ally and ally.name or "an ally"), max(0.6, f.inferred.role.conf)
          end,
          actions = { "Concussive Shot on it", "Scatter Shot", "Freezing Trap in its path" } },

        -- Stage 9: the kill window's verdict (killwindow.lua) -- its outs,
        -- heals, our burst and our risk weighed -- decides, with its own
        -- confidence and words; without one, the old read at half.
        { name = "KILL_WINDOW", priority = 65,
          enter = function(X)
              local tg = X.tg
              if not module_on("kill") or not tg or RANK[X.T.level] >= RANK.HIGH then return false end
              if held(tg.unit) then return false end
              local k = X.S.kill and X.S.kill.target or nil
              if k and k.guid == tg.guid then
                  if k.v == "HIGH_CONFIDENCE_KILL_WINDOW" or k.v == "PREPARE_BURST" then
                      return true, k.v:lower():gsub("_", " ") .. ": " .. k.why, k.conf
                  end
                  return false
              end
              if tg.hp > KT.kill_hp then return false end
              if tg.st and tg.st.immune then return false end
              return true, string.format("%s at %d%% with no immunity up (no kill-window read)", tg.name, math.floor(tg.hp * 100 + 0.5)), 0.5
          end,
          actions = function(X, out)
              for i = #out, 1, -1 do out[i] = nil end
              local k = X.S.kill and X.S.kill.target or nil
              if k and k.actions and #k.actions > 0 then
                  for i = 1, #k.actions do out[i] = k.actions[i] end
              else
                  out[1], out[2], out[3], out[4] = "Rapid Fire", "Aimed Shot", "Arcane Shot", "Multi-Shot on two or more"
              end
              return out
          end,
          avoid = { "spending an escape to chase" } },

        { name = "COUNTER_ATTACK", priority = 62,
          enter = function(X)
              local tg = X.tg
              if not tg or RANK[X.T.level] >= RANK.HIGH then return false end
              if tg.st and (tg.st.burst or tg.st.immune) then return false end
              local name, age = burst_ended(tg, X.now)
              if name then return true, string.format("%s's %s ended %.0fs ago", tg.name, name, age), 0.8 end
              return false
          end,
          actions = { "Aimed Shot", "Serpent Sting", "Rapid Fire" } },

        -- "Battleground objectives may outweigh immediate damage opportunities":
        -- carrying the flag outranks everything but an emergency; an enemy
        -- carrier near outranks a peel.
        { name = "OBJECTIVE_CONTROL", priority = function(X) return X.me.flag and 88 or 69 end,
          enter = function(X)
              if not module_on("team") or X.S.mode.kind ~= "bg" then return false end
              if X.me.flag then return true, "you carry the flag", 0.95 end
              local carriers = X.S.env.objectives.carriers
              for i = 1, #carriers do
                  if carriers[i].enemy then return true, carriers[i].name .. " carries the flag", 0.95 end
              end
              return false
          end,
          actions = function(X, out)
              for i = #out, 1, -1 do out[i] = nil end
              if X.me.flag then out[1] = "run with it: do not stop to fight" else out[1] = "Concussive Shot on the carrier"; out[2] = "Wing Clip the carrier" end
              return out
          end },

        { name = "OPENING", priority = 55,
          enter = function(X)
              local tg = X.tg
              if not tg or not X.me.in_combat or RANK[X.T.level] >= RANK.HIGH then return false end
              if X.fight_age > KT.young_fight then return false end
              local zone = X.S.env.target.zone
              if zone ~= "ranged" then return false end
              return true, string.format("fight %.0fs old, %s at range", X.fight_age, tg.name), 0.9
          end,
          actions = { "Hunter's Mark", "send the pet", "Aimed Shot", "Serpent Sting" } },

        { name = "SUSTAINED_PRESSURE", priority = 50,
          enter = function(X)
              local tg = X.tg
              if not tg or not X.me.in_combat or RANK[X.T.level] >= RANK.HIGH then return false end
              if X.fight_age <= KT.young_fight then return false end
              if X.S.env.target.zone ~= "ranged" then return false end
              return true, string.format("%s at range, %.0fs in", tg.name, X.fight_age), 0.9
          end,
          actions = { "Auto Shot", "Aimed Shot", "Serpent Sting", "Summon Hawk", "Multi-Shot on two or more" },
          avoid = { "Multi-Shot on one" } },

        { name = "RANGED_PRESSURE", priority = 48,
          enter = function(X)
              local tg = X.tg
              if not tg or not X.me.in_combat or RANK[X.T.level] >= RANK.HIGH then return false end
              local zone = X.S.env.target.zone
              if zone ~= "ranged" and zone ~= "far" then return false end
              return true, string.format("%s at %s", tg.name, zone), 0.8
          end,
          actions = { "Auto Shot", "Aimed Shot", "Concussive Shot if it comes" } },

        { name = "RESOURCE_RECOVERY", priority = 40,
          enter = function(X)
              if X.me.in_combat or X.S.attackers > 0 then return false end
              if (X.me.power_pct or 1) < KT.recover_power or (X.me.hp or 1) < KT.recover_hp then
                  return true, string.format("out of combat at %d%% health, %d%% mana", math.floor((X.me.hp or 1) * 100 + 0.5),
                      math.floor((X.me.power_pct or 1) * 100 + 0.5)), 0.8
              end
              return false
          end,
          actions = { "drink and eat", "bandage", "Mend Pet" },
          avoid = { "opening" } },

        { name = "PREPARATION", priority = 30,
          enter = function(X)
              if X.me.in_combat or X.S.attackers > 0 then return false end
              if X.S.players == 0 then return false end
              return true, string.format("%d enemy player(s) near, none on you", X.S.players), 0.8
          end,
          actions = { "Hunter's Mark", "Aspect of the Hawk", "the pet passive beside you", "a trap where it will walk" } },

        { name = "BAIT_OPPONENT", priority = 0,
          enter = function() return false end,
          actions = { "(Stage 8)" } },
    }
    M.STATES = STATES
    M.NAMES = {}
    for i = 1, #STATES do M.NAMES[i] = STATES[i].name end

    -- --- the choice ------------------------------------------------------------------

    local T = {
        state = "NONE", prev = nil, since = 0, why = "no PvP", conf = 0, priority = 0, emergency = false,
        actions = {}, avoid = {}, reserve = {}, candidates = {}, changed = false, predicted = {},
    }
    M.T = T

    -- Stage 13: the target's sure predictions in the advice. Read the way the
    -- baits read them (intel.sure at the predictor's threshold, sure, not
    -- adapting); each adds its response after the state's own actions,
    -- labelled "predicted", and what to avoid -- never which state it is.
    local KP = K.PREDICT
    local function add_predicted(name, X)
        local list = T.predicted
        for i = #list, 1, -1 do list[i] = nil end
        if name == "DISENGAGE" then return end
        local c = X.me and X.me.control
        if c and c.helpless then return end                   -- held: nothing can be cast
        local tg = X.tg
        if not (tg and tg.predict) then return end
        for key, e in pairs(tg.predict) do
            local map = data.PREDICTED_ADVICE[key]
            if map and map.states[name] and e.sure and not e.adapting and lib.sure(e, KP.threshold) ~= nil then
                list[#list + 1] = { key = key, v = e.v, p = e.p or 0, label = e.label or "", response = e.response, avoid = map.avoid }
            end
        end
        table.sort(list, function(a, b) return a.p > b.p end)
        for i = 1, #list do
            local e = list[i]
            T.actions[#T.actions + 1] = string.format("predicted: %s (p %.2f, %s) -- %s", tostring(e.v), e.p, e.label, tostring(e.response or ""))
            if e.avoid then T.avoid[#T.avoid + 1] = e.avoid .. " (predicted)" end
        end
    end

    local cand_pool = {}
    local action_pool, avoid_pool, reserve_pool = {}, {}, {}

    local function fill_list(state, field, X, out)
        for i = #out, 1, -1 do out[i] = nil end
        local v = state[field]
        if type(v) == "function" then return v(X, out) end
        if type(v) == "table" then
            for i = 1, #v do out[i] = v[i] end
        end
        return out
    end

    local function by_rank(name) return RANK[name] or 0 end

    function M.update(W, S, now)
        T.prev = T.state
        T.changed = false
        if not S.active then
            T.state, T.why, T.conf, T.priority, T.emergency = "NONE", S.why or "no PvP", 0, 0, false
            for i = #T.actions, 1, -1 do T.actions[i] = nil end
            for i = #T.avoid, 1, -1 do T.avoid[i] = nil end
            for i = #T.reserve, 1, -1 do T.reserve[i] = nil end
            for i = #T.candidates, 1, -1 do T.candidates[i] = nil end
            for i = #T.predicted, 1, -1 do T.predicted[i] = nil end
            T.changed = T.prev ~= "NONE"
            if T.changed then T.since = now end
            return T
        end

        -- The context.
        X.W, X.S, X.T, X.C, X.me, X.now = W, S, S.threat, S.cds, S.me, now
        X.tg = S.env.target.guid and S.foes[S.env.target.guid] or nil
        X.melee_on_me = melee_foe_on_me(S)
        X.melee_closing = melee_foe_closing(S)
        local combat = P.combat
        X.fight_age = (S.me.in_combat and combat and combat.duration) and (try(combat.duration) or 0) or 0

        -- Every state's answer.
        local n = 0
        for i = 1, #STATES do
            local st = STATES[i]
            local ok, why, conf = st.enter(X)
            if ok then
                n = n + 1
                local c = cand_pool[n] or {}
                cand_pool[n] = c
                local pr = st.priority
                if type(pr) == "function" then pr = pr(X) end
                c.state, c.name, c.why, c.conf, c.priority, c.emergency = st, st.name, why or "", conf or 0.5, pr, st.emergency == true
            end
        end
        for i = #T.candidates, 1, -1 do T.candidates[i] = nil end
        for i = 1, n do T.candidates[i] = cand_pool[i] end
        table.sort(T.candidates, function(a, b) return a.priority > b.priority end)

        local best = T.candidates[1]
        local current = nil
        for i = 1, n do
            if T.candidates[i].name == T.state then current = T.candidates[i] break end
        end
        local pick
        if not best then
            pick = nil
        elseif best.emergency and best.name ~= T.state then
            pick = best
        elseif current and (now - T.since) < KT.dwell then
            pick = current
        elseif current and best.priority <= current.priority then
            pick = current
        else
            pick = best
        end

        if pick then
            if pick.name ~= T.state then
                T.state, T.since, T.changed = pick.name, now, true
            end
            T.why, T.conf, T.priority, T.emergency = pick.why, pick.conf, pick.priority, pick.emergency
            local st = pick.state
            fill_list(st, "actions", X, T.actions)
            fill_list(st, "avoid", X, T.avoid)
            fill_list(st, "reserve", X, T.reserve)
            add_predicted(pick.name, X)
            -- What the ledger keeps is kept here too.
            for name, why in pairs(S.cds.reserved or {}) do T.reserve[#T.reserve + 1] = name end
        else
            if T.state ~= "IDLE" then T.state, T.since, T.changed = "IDLE", now, true end
            T.why, T.conf, T.priority, T.emergency = "PvP about, nothing to do yet", 0.5, 0, false
            for i = #T.actions, 1, -1 do T.actions[i] = nil end
            for i = #T.avoid, 1, -1 do T.avoid[i] = nil end
            for i = #T.reserve, 1, -1 do T.reserve[i] = nil end
            for i = #T.predicted, 1, -1 do T.predicted[i] = nil end
        end
        return T
    end

    function M.reset()
        T.state, T.prev, T.since, T.why, T.conf, T.changed = "NONE", nil, 0, "reset", 0, false
        for i = #T.actions, 1, -1 do T.actions[i] = nil end
        for i = #T.avoid, 1, -1 do T.avoid[i] = nil end
        for i = #T.reserve, 1, -1 do T.reserve[i] = nil end
        for i = #T.candidates, 1, -1 do T.candidates[i] = nil end
        for i = #T.predicted, 1, -1 do T.predicted[i] = nil end
    end

    --- "state CONTROL_DISTANCE (0.90): Enemy in melee, not slowed | do: Wing Clip, step out ... | avoid: ... | keep: ..."
    function M.line()
        if T.state == "NONE" then return nil end
        local parts = { string.format("state %s (%.2f): %s", T.state, T.conf or 0, T.why or "") }
        if #T.actions > 0 then parts[#parts + 1] = "do: " .. table.concat(T.actions, ", ") end
        if #T.avoid > 0 then parts[#parts + 1] = "avoid: " .. table.concat(T.avoid, ", ") end
        if #T.reserve > 0 then parts[#parts + 1] = "keep: " .. table.concat(T.reserve, ", ") end
        return table.concat(parts, " | ")
    end

    return M
end

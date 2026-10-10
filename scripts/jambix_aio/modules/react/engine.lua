-- Jambix AIO / react / engine -- several things are happening; which matters most?
--
-- THE PIPELINE, ONE TICK
--
--   rules propose      every enabled rule that is due looks at the world and
--                      offers zero or more candidate actions, each with the
--                      event it answers ("cast:<guid>:<spell>:<start>")
--   score              base priority + the rule's own modifiers + what the
--                      behaviour state, the encounter and the memory add or
--                      take away. Every point carries its reason.
--   select             per lane (global cooldown, off-GCD), highest score
--                      first; the first candidate that passes validation wins.
--                      A rule's "hold" (stop attacking) is not an action and
--                      never takes a lane: it only halts the rotation.
--   validate           known, ready, right kind of target, not already
--                      handled, not just failed, not talking over something
--                      more important (below)
--   execute            through the same cast arbiter as the rotation, or the
--                      pet, or the bag
--   remember           the attempt, and the event as handled
--
-- WHAT IS NEVER DONE
-- Every valid reaction is not fired. One per lane per tick, and only when it
-- outscores the rotation (ROTATION_SCORE); anything scoring below that waits
-- for a tick on which the rotation had nothing to press.

return function(P, memory, journal)
    local ctx = P.ctx
    local book = P.spellbook

    local E = {}

    local huge, floor = math.huge, math.floor

    --- The score the rotation's own presses stand at. A reaction has to beat
    --- it to override the priority list; below it, it waits for an idle tick.
    E.ROTATION_SCORE = 40
    --- How many candidates per lane are put through validation in one tick.
    --- Validation can ask the client about range and sight; this caps it.
    local VALIDATE_PER_LANE = 4

    -- --- how the moment shifts the weights --------------------------------------

    -- Added to a candidate's score by category. The base priorities already
    -- order the categories; these move them as the fight changes, which is the
    -- point of having a state at all.
    local MODE_MODS = {
        NORMAL = {},
        RECOVERY = { pet = 5, defensive = 3, resource = 5, buff = -5 },
        DEFENSIVE = { survival = 5, defensive = 10, escape = 0, cc = 5, pet = -5, resource = -5,
                      buff = -10, low = -10 },
        EMERGENCY = { survival = 15, bailout = 5, defensive = 15, escape = 10, cc = 10, threat = 5,
                      pet = -25, interrupt = -5, resource = -15, utility = -15, buff = -25, low = -30 },
        ESCAPE = { survival = 10, escape = 30, cc = 15, defensive = 5, threat = 10,
                   pet = -40, interrupt = -20, resource = -30, utility = -30, buff = -35, low = -40 },
    }
    local CONTEXT_MODS = {
        BOSS = { interrupt = 10, defensive = 5, threat = 10 },
        AOE = { cc = 5, threat = 5 },
        PVP = { cc = 10, interrupt = 5, escape = 5 },
    }
    E.MODE_MODS, E.CONTEXT_MODS = MODE_MODS, CONTEXT_MODS

    -- Categories that are an attack on something. Not while holding fire, and
    -- not during a hardcore bail-out.
    local OFFENSIVE = { interrupt = true, buff = true, low = false }

    -- --- the rule registry ------------------------------------------------------------

    local rules, by_name = {}, {}
    local next_eval = {}            -- rule -> earliest time it is asked again
    local owned = {}                -- spell name -> rule that owns casting it
    local errors = {}               -- rule name -> consecutive failures
    local order_seq = 0

    local CATEGORIES = {
        survival = true, bailout = true, interrupt = true, cc = true, escape = true,
        defensive = true, pet = true, threat = true, utility = true, buff = true, low = true,
        resource = true,
    }

    --- Adds a reaction. See rules/core.lua for the shape and many examples.
    ---@param def table
    ---@return table def
    function E.add_rule(def)
        assert(type(def) == "table" and type(def.name) == "string", "a reaction needs a name")
        assert(type(def.priority) == "number", def.name .. ": a reaction needs a base priority")
        assert(type(def.propose) == "function" or type(def.condition) == "function",
            def.name .. ": a reaction needs propose() or condition()")
        def.category = def.category or "utility"
        assert(CATEGORIES[def.category], def.name .. ": unknown category " .. tostring(def.category))
        def.lane = def.lane or "gcd"
        assert(def.lane == "gcd" or def.lane == "fast" or def.lane == "pet",
            def.name .. ": lane must be gcd, fast or pet")
        def.retry = def.retry or {}
        if def.offensive == nil then def.offensive = OFFENSIVE[def.category] == true end

        if by_name[def.name] then E.remove_rule(def.name) end
        order_seq = order_seq + 1
        def.order = order_seq
        rules[#rules + 1] = def
        by_name[def.name] = def
        if type(def.owns) == "table" then
            for i = 1, #def.owns do owned[def.owns[i]] = def end
        end
        return def
    end

    ---@param name string
    function E.remove_rule(name)
        local def = by_name[name]
        if not def then return end
        by_name[name] = nil
        for i = #rules, 1, -1 do
            if rules[i] == def then table.remove(rules, i) end
        end
        for spell, owner in pairs(owned) do
            if owner == def then owned[spell] = nil end
        end
        next_eval[def] = nil
    end

    ---@param name string
    ---@param on boolean
    function E.set_enabled(name, on)
        local def = by_name[name]
        if def then def.disabled = not on end
    end

    ---@param name string
    ---@return table|nil
    function E.rule(name) return by_name[name] end

    ---@return table[]
    function E.rules() return rules end

    --- The player's switches on the rules (the Reactions window, 1.76.0;
    --- react/custom.lua sets it): false keeps a rule out, whatever its own
    --- gate says.
    E.filter = nil

    local function filtered_out(def, W)
        local f = E.filter
        if not f then return false end
        local ok, yes = pcall(f, def, W)
        return ok and yes == false
    end

    --- Is the rule switched on? Its own switch, the player's, then its
    --- setting gate.
    local function enabled(def, W)
        if def.disabled then return false end
        if filtered_out(def, W) then return false end
        local gate = def.enabled
        if gate == nil then return true end
        if type(gate) == "function" then
            local ok, yes = pcall(gate, W)
            return ok and yes == true
        end
        return gate == true
    end

    --- Does a reaction own this spell? A rotation rule or another module that
    --- would cast the same spell on its own clock stands aside: two owners
    --- with two lockouts cast it twice as often as either intends.
    ---@param spell string
    ---@param W? table
    ---@return boolean
    function E.owns(spell, W)
        local def = owned[spell]
        if not def or def.disabled then return false end
        if filtered_out(def, W) then return false end
        if def.enabled == nil or def.enabled == true then return true end
        if type(def.enabled) == "function" then
            local ok, yes = pcall(def.enabled, W)
            return ok and yes == true
        end
        return false
    end

    --- A channel of ours that should give way now: the rule that owns the
    --- spell has a yield(W, spell), and it says standing still any longer
    --- would get us killed (the pet heal, react/petcare.lua). Asked only
    --- while something is being cast.
    ---@param W table
    ---@return table|nil { name, why, rule }
    function E.yielding(W)
        if not W.player.busy then return nil end
        local H = P.rotation and P.rotation.helpers
        if not (H and H.channel_active) then return nil end
        for spell, def in pairs(owned) do
            if def.yield and not def.disabled and H.channel_active(spell) then
                local ok, why = pcall(def.yield, W, spell)
                if ok and why then return { name = spell, why = why, rule = def.name } end
            end
        end
        return nil
    end

    --- Forces a rule to be asked on the next tick, whatever its interval.
    ---@param def table
    function E.wake(def)
        next_eval[def] = 0
    end

    local function due(def, now)
        local every = def.every or 0
        if every <= 0 then return true end
        if now < (next_eval[def] or 0) then return false end
        next_eval[def] = now + every
        return true
    end

    local function needs_ok(def, W)
        local needs = def.needs
        if not needs then return true end
        for i = 1, #needs do
            local need = needs[i]
            if need == "combat" then
                if not W.player.in_combat then return false end
            elseif need == "pet" then
                if not W.pet.alive then return false end
            elseif need == "target" then
                if not W.target.unit then return false end
            elseif need == "group" then
                if not W.group.in_group then return false end
            elseif need == "casting" then
                if W.enemies.casting_n == 0 and not W.target.casting then return false end
            end
        end
        return true
    end

    -- --- candidates ----------------------------------------------------------------

    local CAND = {}
    CAND.__index = CAND

    --- Adds points, with the reason they were added. The debug view prints
    --- these lines exactly.
    ---@param points number
    ---@param why string
    function CAND:add(points, why)
        if points == nil or points == 0 then return self end
        self.score = self.score + points
        self.reasons[#self.reasons + 1] = { points, why }
        return self
    end

    --- Marks the candidate as one to show but not to press yet.
    ---@param why string
    function CAND:wait(why)
        self.hold = why
        return self
    end

    local current_def, current_W, cands = nil, nil, {}

    local function target_for(kind, W)
        if kind == "self" then return W.player.unit end
        if kind == "pet" then return W.pet.unit end
        if kind == "enemy" then return W.target.unit end
        return nil
    end

    --- What a rule's propose() calls, once per action it wants considered.
    ---@param spec table { name, kind?, target?, target_kind?, event_key?, handled_for?, why?, lane?, item?, channel?, offensive? }
    ---@return table candidate
    local function offer(spec)
        local def, W = current_def, current_W
        local kind = spec.kind or def.kind or "spell"
        -- A SPELL YOU HAVE NOT LEARNED IS NOT A CANDIDATE (1.54.1). It used to
        -- be offered and then refused at validation ("not trained"): never
        -- pressed, but listed among the candidates, refused in the readout and
        -- the window ("Refused Feign Death: not trained") and written to the
        -- journal -- which reads as the engine trying spells that are not in
        -- your spellbook. The rule still gets a candidate to fill in; it just
        -- never joins the list.
        if (kind == "spell" or kind == "aspect") and not book.known(spec.name or def.name) then
            return setmetatable({ rule = def, name = spec.name or def.name, kind = kind, score = 0,
                reasons = {}, dropped = "not learned" }, CAND)
        end
        local target_kind = spec.target_kind or def.target_kind
            or (type(def.target) == "string" and def.target)
            or ((kind == "item" or kind == "named_item") and "self") or (kind == "hold" and "none") or "enemy"
        local target = spec.target
        if target == nil and kind ~= "hold" then
            if type(def.target) == "function" then
                local ok, unit = pcall(def.target, W)
                target = ok and unit or nil
            else
                target = target_for(target_kind, W)
            end
        end
        local c = setmetatable({
            rule = def,
            name = spec.name or def.name,
            kind = kind,
            item = spec.item,
            target = target,
            target_kind = target_kind,
            target_guid = target and P.units.guid(target) or nil,
            -- The pet has its own global cooldown: an order to it never
            -- takes the player's lane, and never stops the rotation.
            lane = spec.lane or ((kind == "pet_spell" or kind == "pet_send" or kind == "pet_recall") and "pet")
                or def.lane,
            event_key = spec.event_key,
            handled_for = spec.handled_for or def.handled_for,
            why = spec.why,
            channel = spec.channel or def.channel or false,
            cast_time = spec.cast_time or 0,
            -- A ground-targeted spell's spot (a Flare where a rogue vanished,
            -- 1.81.0); its target_kind is "ground".
            position = spec.position,
            offensive = (spec.offensive == nil) and def.offensive or spec.offensive,
            score = def.priority,
            reasons = { { def.priority, "base: " .. def.name } },
            order = def.order * 100 + #cands,
        }, CAND)
        cands[#cands + 1] = c
        return c
    end
    E.offer = offer

    --- The simple rule shape: condition(W) and an action, which may be a
    --- name, a list of names (the first ready one is used), or a function
    --- returning either.
    local function simple_propose(def, W)
        if def.condition and not def.condition(W) then return end
        local action = def.action
        if type(action) == "function" then action = action(W) end
        if action == nil then return end
        local names = type(action) == "table" and action or { action }
        local pick, first_known = nil, nil
        for i = 1, #names do
            local name = names[i]
            if (def.kind or "spell") ~= "spell" or book.known(name) then
                first_known = first_known or name
                if (def.kind or "spell") ~= "spell" or book.ready(name) then pick = name break end
            end
        end
        pick = pick or first_known
        if not pick then return end
        offer({ name = pick })
    end

    -- --- safety validation ------------------------------------------------------------

    local function can_attack(W, unit)
        local player = W.player.unit
        if not player or not unit then return false end
        local ok, yes = pcall(player.can_attack, player, unit)
        return ok and yes == true
    end

    local function alive(unit)
        if not unit then return false end
        local ok_v, valid = pcall(unit.is_valid, unit)
        if not ok_v or valid ~= true then return false end
        local ok_d, dead = pcall(unit.is_dead, unit)
        return not (ok_d and dead == true)
    end

    --- Catalogue range says what kind of target the ability takes.
    local function catalog_says(name)
        local catalog = P.catalog
        local row = catalog and catalog.ability and catalog.ability(name) or nil
        if not row then return nil end
        local r = row.range
        if r == "self" then return "self" end
        if r == "pet" then return "pet" end
        if r == "party" then return "ally" end
        if r == "ranged" or r == "melee" or type(r) == "number" or type(r) == "table" then return "enemy" end
        return nil
    end

    --- Why this candidate must not be executed now, or nil when it may.
    ---@param c table
    ---@param W table
    ---@return string|nil
    function E.validate(c, W)
        local def = c.rule
        if c.kind == "hold" then return nil end

        -- The engine's own refusals: the moment, and the memory.
        if c.offensive and W.bailout and not W.fight_on then return "bail-out: no attacks" end
        if c.offensive and W.hold_fire and c.target ~= nil and c.target == W.target.unit then
            return "holding fire: target not engaged"
        end
        local handled, note, left = memory.handled(c.event_key)
        if handled then
            return string.format("already handled (%s, %.1fs)", note or c.event_key, left)
        end
        local hold = def.retry.hold or 0
        if hold > 0 then
            local since = memory.since(c.name)
            if since < hold then
                local waiting = memory.waiting(c.name, c.target_guid)
                return string.format("%s %.1fs ago, %s", c.name, since,
                    waiting and "waiting for the result" or "holding before another")
            end
        end
        local fails, backoff_left, last_why = memory.failures(c.name)
        if backoff_left > 0 then
            return string.format("failed %d time(s) (%s); retry in %.1fs",
                fails, last_why or "?", backoff_left)
        end

        -- The target.
        local t, tk = c.target, c.target_kind
        if tk == "enemy" then
            if not t or t == W.player.unit then return "no enemy target (would self-cast)" end
            if not alive(t) then return "target is gone" end
            if not can_attack(W, t) then return "target is not hostile" end
        elseif tk == "self" then
            if t ~= W.player.unit then return "self-cast aimed elsewhere" end
        elseif tk == "pet" then
            if not W.pet.alive or t ~= W.pet.unit then return "no pet" end
        elseif tk == "ally" then
            if not alive(t) then return "ally is gone" end
            if can_attack(W, t) then return "ally target is hostile" end
        end

        if c.kind == "spell" then
            if not book.known(c.name) then return "not trained" end
            local says = catalog_says(c.name)
            if says == "self" and tk == "enemy" then return "catalogue: self-only, not cast on an enemy" end
            if says == "enemy" and tk == "self" then return "catalogue: needs an enemy, refusing to self-cast" end
            local H = P.rotation and P.rotation.helpers
            if H and H.key_allows and not H.key_allows(c.name) then return "its key is not held" end
            if not book.ready(c.name) then return "not ready (cooldown or resources)" end
            if H and H.channel_active and H.channel_active(c.name) then return "its channel is running" end
            local rot = P.rotation
            if rot and rot.press_blocked then
                local why = rot.press_blocked(c.name, W.s, t)
                if why then return why end
            end
            -- Our last cast is still on its way: anything not clearly more
            -- important waits for it rather than cutting it off.
            local p = W.pending
            if c.lane == "gcd" and p and c.score < (p.score or 0) + 10 then
                return string.format("waiting for %s to start", p.name)
            end
            -- Busy with something more important: the cast in progress is a
            -- reaction of ours that scored higher.
            if c.lane == "gcd" and W.player.busy then
                local row = memory.in_progress(W.player.casting_id)
                -- A channel that gives way (E.yielding) may be cut by
                -- anything that beats the rotation.
                local gives_way = W.yield ~= nil and (row == nil or row.name == W.yield.name)
                if row and not gives_way and c.score < (row.score or 0) + 10 then
                    return string.format("busy: %s (score %d) in progress", row.name, floor((row.score or 0) + 0.5))
                end
                if W.player.casting_id and W.player.casting_id == book.id(c.name) then
                    return "already casting it"
                end
            end
        elseif c.kind == "pet_spell" then
            if not W.pet.alive then return "no pet" end
            if not (P.pet and P.pet.knows and P.pet.knows(c.name)) then return "the pet does not know it" end
            -- Nothing selected: the pet stays with you (1.87.1, pet.lua).
            if tk == "enemy" and P.pet.home and P.pet.home() then return "nothing selected: the pet stays with you" end
        elseif c.kind == "item" then
            local have = c.item and P.hardcore and P.hardcore.item and P.hardcore.item(c.item)
            if not have then return "none in the bags" end
            if W.player[c.item] == false then return "not usable yet (cooldown)" end
        elseif c.kind == "named_item" then
            -- Any carried item by its name (1.79.0): a trinket, a potion.
            local hc = P.hardcore
            if not (hc and hc.named_ready) then return "items by name need the Hardcore module" end
            local ok, why = hc.named_ready(c.item)
            if not ok then return (c.item or "the item") .. ": " .. tostring(why or "not usable") end
        elseif c.kind == "pet_send" then
            if not W.pet.alive then return "no pet" end
            if not alive(t) then return "target is gone" end
            if P.pet and P.pet.home and P.pet.home() then return "nothing selected: the pet stays with you" end
        elseif c.kind == "pet_recall" then
            if not W.pet.alive then return "no pet" end
            if not (P.pet and P.pet.recall) then return "the pet cannot be called back here" end
        elseif c.kind == "aspect" then
            local A = P.aspects
            if not (A and A.can_switch and A.switch_to) then return "no Aspects window here" end
            local why = A.can_switch(c.name)
            if why then return why end
        elseif c.kind == "set_target" then
            -- A target switch (1.81.0: off a player in Divine Shield).
            if not (P.targeting and P.targeting.switch_to) then return "no targeting here" end
            if rawequal(t, W.target.unit) then return "already the target" end
        end
        if tk == "ground" and not c.position then return "no spot to cast it on" end

        if def.validate then
            local ok, why = pcall(def.validate, W, c)
            if not ok then return "validate raised: " .. tostring(why) end
            if why then return why end
        end
        return nil
    end

    -- --- execution -------------------------------------------------------------------

    local function band_for(def)
        if def.band then return def.band end
        local PR = ctx.PRIORITY or {}
        local cat = def.category
        if cat == "survival" or cat == "bailout" or cat == "escape" or cat == "defensive" then
            return PR.EMERGENCY or 255
        end
        if cat == "interrupt" then return PR.INTERRUPT or 150 end
        if cat == "cc" then return PR.DEFENSIVE or 200 end
        if cat == "pet" or cat == "threat" or cat == "utility" or cat == "resource" then
            return PR.UTILITY or 100
        end
        if cat == "buff" then return (PR.ROTATION or 50) + 5 end
        return PR.FILLER or 30
    end

    ---@param c table
    ---@param W table
    ---@return boolean sent
    function E.execute(c, W)
        local def = c.rule
        local reason = string.format("react: %s (%s)", c.name, def.name)
        local ok, id = false, nil

        if c.kind == "spell" then
            id = book.id(c.name)
            if not id then return false end
            ctx.cast({
                spell_id = id, target = c.target, position = c.position, priority = band_for(def),
                reason = reason, fast = c.lane == "fast", direct = def.direct == true,
            })
            ok = true
        elseif c.kind == "set_target" then
            ok = P.targeting and P.targeting.switch_to and P.targeting.switch_to(c.target) == true or false
        elseif c.kind == "pet_spell" then
            ok = P.pet and P.pet.cast and P.pet.cast(c.name, c.target) == true or false
            id = ok and P.pet.spell_id and P.pet.spell_id(c.name) or nil
        elseif c.kind == "item" then
            ok = P.hardcore and P.hardcore.use_item and P.hardcore.use_item(c.item, def.name) == true or false
        elseif c.kind == "named_item" then
            ok = P.hardcore and P.hardcore.use_named and P.hardcore.use_named(c.item, def.name) == true or false
        elseif c.kind == "pet_send" then
            -- Pinned for a few seconds where the pet module has an
            -- assignment to give, so its own assist pass does not send the pet
            -- straight back to our target on its next tick.
            if P.pet and P.pet.assign then
                ok = P.pet.assign(c.target, def.name, c.pin or 5) == true
            else
                ok = P.pet and P.pet.send and P.pet.send(c.target, def.name, true) == true or false
            end
        elseif c.kind == "pet_recall" then
            -- Called back, and kept off that mob for a while: the pet
            -- module's assist pass would otherwise send it straight back.
            ok = P.pet and P.pet.recall and P.pet.recall(def.name, c.target_guid, 8) == true or false
        elseif c.kind == "aspect" then
            -- The Aspects window owns aspects (modules/aspects.lua, 1.49.0):
            -- the switch moves with the cast, so the window shows what was
            -- done and its keeper does not put the old aspect back.
            local A = P.aspects
            ok = A and A.switch_to and A.switch_to(c.name, c.why or def.name, band_for(def)) == true or false
            id = ok and book.id(c.name) or nil
        end
        if not ok then
            journal("reject", string.format("%s: the %s call did not go through", c.name, c.kind),
                "exec:" .. c.name)
            return false
        end

        memory.attempt({
            name = c.name, id = id, kind = c.kind, target_guid = c.target_guid,
            event_key = c.event_key, rule = def.name, score = c.score, lane = c.lane,
            cast_time = c.cast_time, unique = def.unique == true, channel = c.channel,
        })
        if c.event_key then
            local ttl = c.handled_for
            if type(ttl) == "function" then
                local ok_ttl, value = pcall(ttl, W, c)
                ttl = ok_ttl and value or nil
            end
            memory.handle(c.event_key, ttl or 2.0, def.name .. ": " .. c.name)
        end
        if def.on_execute then pcall(def.on_execute, W, c) end
        -- For the Reactions window: how often each reaction went out.
        def.fired_n = (def.fired_n or 0) + 1
        def.fired_at = W.now
        def.fired_name = c.name
        return true
    end

    -- --- one decision ------------------------------------------------------------------

    local function rule_error(def, err)
        errors[def.name] = (errors[def.name] or 0) + 1
        if errors[def.name] == 1 or errors[def.name] % 100 == 0 then
            journal("error", string.format("%s raised: %s", def.name, tostring(err)), "err:" .. def.name)
        end
    end

    local function by_score(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.order < b.order
    end

    --- Runs the pipeline up to (not including) execution.
    ---@param W table
    ---@return table decision { cands, gcd, fast, deferred, holds, rejected }
    function E.decide(W)
        local now = W.now
        cands = {}
        current_W = W

        for i = 1, #rules do
            local def = rules[i]
            if enabled(def, W) and needs_ok(def, W) and due(def, now) then
                current_def = def
                local ok, err
                if def.propose then
                    ok, err = pcall(def.propose, W, offer)
                else
                    ok, err = pcall(simple_propose, def, W)
                end
                if not ok then rule_error(def, err) else errors[def.name] = nil end
            end
        end
        current_def = nil

        -- Score: the rule's own view, then the moment's, then the memory's.
        local mode_mods = MODE_MODS[W.mode or "NORMAL"] or {}
        local ctx_mods = W.context and CONTEXT_MODS[W.context] or nil
        for i = 1, #cands do
            local c = cands[i]
            local def = c.rule
            if def.score then
                local ok, err = pcall(def.score, W, c)
                if not ok then rule_error(def, err) end
            end
            local m = mode_mods[def.category]
            if m then c:add(m, "mode " .. tostring(W.mode)) end
            if ctx_mods and ctx_mods[def.category] then
                c:add(ctx_mods[def.category], "context " .. W.context)
            end
            if c.kind ~= "hold" then
                local fails, backoff_left = memory.failures(c.name)
                if backoff_left > 0 then
                    c:add(-50, string.format("failed %d time(s) recently", fails))
                elseif fails > 0 then
                    c:add(-10 * fails, "failed recently")
                end
            end
        end
        table.sort(cands, by_score)

        -- Select, per lane.
        local decision = { cands = cands, gcd = nil, fast = nil, pet = nil, deferred = nil,
                           holds = {}, rejected = {} }
        local tried = { gcd = 0, fast = 0, pet = 0 }
        -- One event, one answer: once a cast is being kicked in one lane, the
        -- pet's kick for the same cast in another lane stands down.
        local claimed = {}
        for i = 1, #cands do
            local c = cands[i]
            if c.kind == "hold" then
                decision.holds[#decision.holds + 1] = c
                c.state = "hold"
            elseif c.hold then
                c.state, c.rejected = "waiting", c.hold
            elseif c.event_key and claimed[c.event_key] then
                c.state = "answered by " .. claimed[c.event_key]
            elseif decision[c.lane] then
                c.state = "outscored"
            elseif tried[c.lane] >= VALIDATE_PER_LANE then
                c.state = "not checked"
            else
                tried[c.lane] = tried[c.lane] + 1
                local why = E.validate(c, W)
                if why then
                    c.state, c.rejected = "rejected", why
                    decision.rejected[#decision.rejected + 1] = c
                elseif c.score >= E.ROTATION_SCORE then
                    c.state = "selected"
                    decision[c.lane] = c
                    if c.event_key then claimed[c.event_key] = c.name end
                elseif not decision.deferred and c.lane == "gcd" then
                    c.state = "deferred"
                    decision.deferred = c
                else
                    c.state = "below the rotation"
                end
            end
        end
        return decision
    end

    return E
end

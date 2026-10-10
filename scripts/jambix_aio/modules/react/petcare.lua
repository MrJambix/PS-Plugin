-- Jambix AIO / react / petcare -- is a pet heal worth standing still for?
--
-- Mend Pet (and a warlock's Health Funnel) is a CHANNEL: five seconds rooted
-- to the spot, no shots, no stepping out of melee. "Is the pet under the
-- line?" was the whole question until 1.66.0. Now it has three parts, and
-- each one is a prediction rather than a percentage:
--
--   WILL IT MATTER?  The pet's seconds to live at the rate it is losing,
--                    against the seconds until what it is holding dies. A pet
--                    that outlives the fight is topped up after it instead.
--
--   WILL IT WORK?    What the channel heals a second (its tooltip over the
--                    pet's bar, a guess until that reads) against what the pet
--                    is losing. A pet that dies inside the channel anyway is
--                    not healed into its grave while the mob goes untouched.
--
--   CAN WE AFFORD TO STAND STILL?  What happens to US over the channel: our
--                    health at its end at the rate it is falling, our seconds
--                    to live with every mob on us counted, a mob in melee or
--                    arriving inside it, ground about to be hit, a bail-out,
--                    and the mana the way out needs. Whatever would get us
--                    killed is a veto; the lesser costs take points off.
--
-- What the pet is worth is weighed too: the tank when solo (rules/core.lua),
-- much of a Beast Mastery hunter's damage, and with Improved Mend Pet a
-- cleanse -- the one way to free a feared or sleeping pet.
--
-- A channel already running is asked the same question with the time it has
-- left (M.yield). Once standing still would get us killed it gives way: any
-- reaction may cut it, and the rotation's cast gate opens so the walk and the
-- kite can move (engine.yielding, rotation.lua cast_gate_busy).

return function(P)
    local ctx = P.ctx
    local units = P.units
    local book = P.spellbook
    local huge, min, max, floor = math.huge, math.min, math.max, math.floor

    local M = {}

    -- Mend Pet is five seconds when the catalogue does not say.
    local DEFAULT_CHANNEL = 5
    -- Before its tooltip has been read, a heal is taken to restore about a
    -- third of the pet's bar over the channel: Mend Pet does, at every rank,
    -- at the level it is learned.
    local GUESS_SHARE = 0.33
    -- A GUESSED heal never calls a pet hopeless on its own: it is taken this
    -- much bigger before the pet is given up on.
    local GUESS_DOUBT = 1.5
    -- The pet outlives the fight when it would last this many times as long
    -- as what it is holding, and a second more.
    local OUTLIVE_MARGIN, OUTLIVE_SPARE = 1.3, 1.0
    -- Under this health a mob in melee with us, or arriving inside the
    -- channel, is a veto: five seconds of it standing still is too many.
    local STAND_HP = 0.5
    -- Seconds left over after the channel to do something about the fight.
    local TTL_SPARE = 2.0
    -- Improved Mend Pet's chance per tick to cleanse, by rank (Classic).
    local CLEANSE_CHANCE = { 0.15, 0.50 }
    -- Debuffs that take the pet out of the fight. Matched inside the name, so
    -- the creatures' own versions ("Crystal Sleep", "Terrifying Screech")
    -- count too.
    local CONTROL_WORDS = {
        "Fear", "Terrify", "Terror", "Scream", "Screech", "Sleep", "Hibernate",
        "Polymorph", "Seduction", "Charm", "Mind Control", "Banish", "Hex",
        "Hammer of Justice", "Stun", "Freezing", "Petrif", "Paralyz", "Wyvern Sting",
    }

    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    local function channel_of(name)
        local catalog = P.catalog
        local row = catalog and catalog.ability and catalog.ability(name) or nil
        local secs = row and tonumber(row.channel) or nil
        return (secs and secs > 0) and secs or DEFAULT_CHANNEL
    end
    M.channel_of = channel_of

    local function talent(name)
        local t = P.talents
        if not (t and t.rank) then return 0 end
        local ok, r = pcall(t.rank, name)
        return ok and tonumber(r) or 0
    end

    -- --- what the heal does -------------------------------------------------------

    --- What a pet heal's tooltip says it restores: health points a second,
    --- or a share of the pet's bar a second.
    ---@param text string|nil
    ---@return number|nil points_per_second
    ---@return number|nil share_per_second
    function M.parse_heal(text)
        if type(text) ~= "string" or text == "" then return nil, nil end
        local t = text:gsub(",", "")
        -- "Heals your pet for 25% of its total health over 10 sec."
        local p, s = t:match("(%d+)%%%s*of its total health over (%d+) sec")
        if p and tonumber(s) > 0 then return nil, tonumber(p) / 100 / tonumber(s) end
        -- "Gives 12 health to the caster's pet every second for 10 sec ..."
        local each = t:match("(%d+) health to .-pet every second")
        if each then return tonumber(each), nil end
        -- "Heals your pet for 100 health over 5 sec."
        local total, secs = t:match("(%d+) health over (%d+) sec")
        if total and tonumber(secs) > 0 then return tonumber(total) / tonumber(secs), nil end
        return nil, nil
    end

    local tooltips = {}             -- spell id -> { per_sec, share } or false

    local function tooltip(name)
        local id = book and book.id and book.id(name) or nil
        if not id then return nil end
        local hit = tooltips[id]
        if hit == nil then
            local text = nil
            local sb = core.spell_book
            if type(sb) == "table" and type(sb.get_spell_description) == "function" then
                local ok, value = pcall(sb.get_spell_description, id)
                if ok then text = value end
            end
            local per_sec, share = M.parse_heal(text)
            hit = (per_sec or share) and { per_sec = per_sec, share = share } or false
            -- Spell data loads late: an empty answer is asked again next time.
            if hit or (type(text) == "string" and text ~= "") then tooltips[id] = hit end
        end
        return hit or nil
    end
    if ctx and ctx.on then
        ctx.on("jambix.aio.spells_changed", function() tooltips = {} end)
    end

    --- The share of the pet's bar the heal restores a second, and where that
    --- figure came from ("tooltip" or "guess").
    local function heal_rate(name, pet_unit)
        local tip = tooltip(name)
        if tip and tip.share then return tip.share, "tooltip" end
        if tip and tip.per_sec and pet_unit and units and units.max_health then
            local ok, most = pcall(units.max_health, pet_unit)
            if ok and type(most) == "number" and most > 0 then
                return min(1, tip.per_sec / most), "tooltip"
            end
        end
        return GUESS_SHARE / channel_of(name), "guess"
    end

    --- The pet over the channel: how long it lasts without the heal, how it
    --- ends with it, whether it outlives what it is holding anyway, and
    --- whether it dies inside the channel whatever we do.
    ---@param W table
    ---@param name string "Mend Pet" | "Health Funnel"
    ---@return table F
    function M.forecast(W, name)
        local pet, tg = W.pet, W.target
        local F = { name = name, channel = channel_of(name) }
        F.loss = max(0, -(pet.hp_rate or 0))
        F.heal_rate, F.heal_src = heal_rate(name, pet.unit)
        F.pet_ttl = F.loss > 0.001 and ((pet.hp or 0) / F.loss) or huge
        F.after = min(1, max(0, (pet.hp or 0) + (F.heal_rate - F.loss) * F.channel))
        local trusted = F.heal_src == "guess" and F.heal_rate * GUESS_DOUBT or F.heal_rate
        F.futile = F.loss > trusted and (F.loss - trusted) * F.channel >= (pet.hp or 0)

        -- When what the pet is holding will be dead. One mob that is our
        -- target: its own time to die. More than one: the fight's time to
        -- clear, from the plan. A mob that runs at low health lies about it.
        local left = nil
        if (pet.attackers or 0) <= 1 and pet.target_guid ~= nil and pet.target_guid == tg.guid
            and type(tg.ttd) == "number" and tg.ttd > 0 and tg.ttd < huge and not tg.runs then
            left = tg.ttd
        elseif W.plan and W.plan.live and type(W.plan.ttc) == "number" and W.plan.ttc < huge then
            left = W.plan.ttc
        end
        F.fight_left = left
        F.outlives = left ~= nil and F.loss > 0.005
            and F.pet_ttl > left * OUTLIVE_MARGIN + OUTLIVE_SPARE
        return F
    end

    -- --- the talents -------------------------------------------------------------------

    local removable_types = nil
    local function removable(kind)
        if not removable_types then
            local types = P.enums and P.enums.buff_type
            if not types then return false end
            removable_types = {}
            for _, n in ipairs({ "MAGIC", "CURSE", "DISEASE", "POISON", "MAGIC_CURSE_DISEASE_POISON" }) do
                if type(types[n]) == "number" then removable_types[types[n]] = true end
            end
        end
        return kind ~= nil and removable_types[kind] == true
    end

    local function controls(name)
        for i = 1, #CONTROL_WORDS do
            if name:find(CONTROL_WORDS[i], 1, true) then return true end
        end
        return false
    end

    -- The pet's debuffs are one client call, so they are read twice a second
    -- at most, and only for a hunter who has the talent.
    local seen = { at = -huge, guid = nil, best = nil }

    local function worst_debuff(W)
        local pet = W.pet
        if not pet.unit then return nil end
        if seen.guid == pet.guid and (W.now - seen.at) < 0.5 then return seen.best end
        seen.guid, seen.at, seen.best = pet.guid, W.now, nil
        local ok, list = pcall(pet.unit.get_debuffs, pet.unit)
        if not ok or type(list) ~= "table" then return nil end
        local best = nil
        for _, d in pairs(list) do
            if type(d) == "table" and removable(d.type) then
                local n = type(d.buff_name) == "string" and d.buff_name or "a debuff"
                local control = controls(n)
                if not best or (control and not best.control) then
                    best = { name = n, id = d.buff_id, control = control }
                end
            end
        end
        seen.best = best
        return best
    end

    --- What Improved Mend Pet would clear: the worst removable debuff on the
    --- pet (one that takes it out of the fight first) and the chance one
    --- channel clears it. nil without the talent or the debuff.
    ---@param W table
    ---@param name string
    ---@return table|nil { name, id, control, chance, rank }
    function M.cleanse(W, name)
        if name ~= "Mend Pet" then return nil end
        local rank = talent("Improved Mend Pet")
        if rank <= 0 then return nil end
        local d = worst_debuff(W)
        if not d then return nil end
        local per_tick = CLEANSE_CHANCE[min(rank, #CLEANSE_CHANCE)]
        local ticks = max(1, floor(channel_of(name) + 0.5))
        d.rank = rank
        d.chance = 1 - (1 - per_tick) ^ ticks
        return d
    end

    --- What the pet is worth beyond its health bar, as points with reasons.
    ---@param W table
    ---@param add fun(points: number, why: string)
    function M.worth(W, add)
        if not (W.class and W.class.key == "hunter" and W.pet.target) then return end
        local t = P.talents
        if not (t and t.points) then return end
        local ok, bm = pcall(t.points)
        bm = ok and tonumber(bm) or 0
        if bm >= 11 then
            add(min(6, floor(bm / 31 * 6 + 0.5)),
                string.format("Beast Mastery (%d points): the pet is much of your damage", bm))
        end
    end

    -- --- can we stand still ------------------------------------------------------------

    --- Mana held back for the way out: the class's first escape that is
    --- ready and costs mana (a hunter's Feign Death).
    local function escape_reserve(W)
        local auto = P.auto
        if not (auto and auto.cost) or W.player.power_kind ~= "MANA" then return nil end
        local list = W.class and W.class.escapes or {}
        for i = 1, #list do
            local e = list[i]
            if book.known(e) and book.ready(e) then
                local ok, mana = pcall(auto.cost, e)
                if ok and type(mana) == "number" and mana > 0 then return mana, e end
            end
        end
        return nil
    end

    local function spend(name, seconds)
        local auto = P.auto
        if not (auto and auto.cost) then return 0 end
        local ok, mana, per_sec = pcall(auto.cost, name)
        if not ok or type(mana) ~= "number" then return 0 end
        return mana + (tonumber(per_sec) or 0) * seconds
    end

    --- Would standing still for `seconds` get us killed?
    ---@param W table
    ---@param name string the heal
    ---@param seconds number how long we would stand there
    ---@param running? boolean the channel is already paid for and running
    ---@return string|nil veto why not, when it would
    ---@return table|nil costs { {points, why}, ... } for what it costs short of that
    function M.danger(W, name, seconds, running)
        local pl, en, sit = W.player, W.enemies, W.sit
        local costs = nil
        local function cost(points, why)
            costs = costs or {}
            costs[#costs + 1] = { points, why }
        end

        if W.bailout and not W.fight_on then return "bail-out: leaving, not standing still" end
        if W.mode == "ESCAPE" then return "escaping: no time to stand still" end

        -- Ground about to be hit: a channel would hold us in it.
        local tele = ctx and ctx.telegraphs
        if tele and tele.on_me then
            local ok, list = pcall(tele.on_me)
            local t = ok and type(list) == "table" and list[1] or nil
            if t then return string.format("standing in %s: move first", t.name or "danger") end
        end

        -- Us, at the end of it.
        local line = W.thresholds.defensive_hp or 0.35
        local on_me = en.on_me or 0
        local falling = min(0, pl.hp_rate or 0)
        if on_me > 0 or falling < -0.01 then
            local at_end = (pl.hp or 1) + falling * seconds
            if at_end < line then
                return string.format("you would end it at %d%%%s", pct(max(0, at_end)),
                    falling < 0 and string.format(" (falling %.0f%%/s)", -falling * 100) or "")
            end
            local plan = W.plan
            local ttl = min(pl.ttl or huge, (plan and plan.live and plan.ttl) or huge)
            if on_me > 0 and ttl < seconds + TTL_SPARE then
                return string.format("%.0fs to live with %d on you", ttl, on_me)
            end
        end

        -- In melee, or about to be: hits push a channel back, and a channel
        -- cannot step out of reach.
        local melee = en.melee_on_me or 0
        local arriving, eta, who = 0, huge, nil
        local list, n = en.list or {}, en.count or 0
        for i = 1, n do
            local r = list[i]
            if r and r.targeting_me and not r.control and (r.dist or huge) > 8 then
                local reach = tonumber(r.time_to_reach) or huge
                if reach < seconds then
                    arriving = arriving + 1
                    if reach < eta then
                        eta = reach
                        who = units and units.name and r.obj and units.name(r.obj) or nil
                    end
                end
            end
        end
        if (melee > 0 or arriving > 0) and (pl.hp or 1) < STAND_HP then
            if melee > 0 then
                return string.format("%d in melee with you at %d%%", melee, pct(pl.hp))
            end
            return string.format("%s reaches you in %.1fs and you are at %d%%", who or "a mob", eta, pct(pl.hp))
        end
        if melee > 0 then
            cost(-min(16, melee * 8), string.format("%d in melee with you: hits cut the channel short, and you cannot step out", melee))
        end
        if arriving > 0 then
            cost(-min(10, arriving * 5), string.format("%s reaches you in %.1fs", who or "a mob", eta))
        end
        if sit.incoming then cost(-6, "a big cast is coming at you") end

        -- The mana for the way out, while there is something to get out of.
        if not running and (on_me > 0 or sit.outnumbered) then
            local reserve, escape = escape_reserve(W)
            if reserve then
                local left = (pl.power or 0) - spend(name, seconds)
                if left < reserve then
                    return string.format("it leaves %d mana and %s needs %d", floor(max(0, left)), escape, floor(reserve))
                end
            end
        end
        return nil, costs
    end

    --- A heal channel already running: should it give way? Asked with the
    --- time it has left; the mana is spent by then, so that is not asked.
    ---@param W table
    ---@param name string
    ---@return string|nil why
    function M.yield(W, name)
        local left = W.player.cast_remaining or 0
        -- Nearly done: the last tick lands before anything could.
        if left <= 0.5 then return nil end
        return (M.danger(W, name, left, true))
    end

    return M
end

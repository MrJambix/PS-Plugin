-- Jambix AIO / react / damage -- what each of our skills actually does.
--
-- The rotation chooses between skills; to choose well it has to know what each
-- one is WORTH, and a priority list written by hand only knows what somebody
-- thought it was worth at some level with some gear. The client knows better,
-- twice over:
--
--   MEASURED   the combat log (COMBAT_LOG_EVENT_UNFILTERED, relayed by JCore)
--              reports every point of damage we deal, by spell. Each cast of
--              ours opens a window; the damage that spell deals inside it --
--              the hit, the crit, every damage-over-time tick, every missile
--              -- is that cast's worth. Averaged over the last few casts.
--   PRIOR      until a skill has been measured twice, its tooltip says what it
--              should do ("13 to 18 Shadow damage", "40 damage over 12 sec"),
--              read from core.spell_book.get_spell_description once per rank.
--
-- Nothing here chooses. adapt.lua weighs the rotation's candidates with it.

return function(P, ctx)
    local units = P.units
    local book = P.spellbook

    local D = {}
    local huge, max, min = math.huge, math.max, math.min

    -- --- measured ---------------------------------------------------------------

    local KEEP = 8                 -- casts averaged, newest weighted most
    local stats = {}               -- name -> { casts, avg, open = { at, total, until_at } }

    local function window_for(name)
        local catalog = P.catalog
        local row = catalog and catalog.ability and catalog.ability(name) or nil
        local dur = row and (tonumber(row.duration) or tonumber(row.channel)) or nil
        if dur and dur > 0 then return dur + 1.5 end
        local prior = D.prior(name)
        if prior and prior.duration then return prior.duration + 1.5 end
        return 3.0                 -- a hit and its travel time
    end

    local function close(st)
        local open = st.open
        st.open = nil
        if not open or open.total <= 0 then return end
        st.casts = st.casts + 1
        local weight = 1 / min(st.casts, KEEP)
        st.avg = st.avg and (st.avg + (open.total - st.avg) * weight) or open.total
    end

    --- A cast of ours went out: its damage starts counting from here.
    ---@param name string
    function D.cast(name)
        if type(name) ~= "string" then return end
        local now = core.time()
        local st = stats[name]
        if not st then
            st = { casts = 0, avg = nil, open = nil, last_cast = -huge }
            stats[name] = st
        end
        -- The success event and the cast hook can both report one cast.
        if (now - st.last_cast) < 0.2 then return end
        st.last_cast = now
        close(st)
        st.open = { at = now, total = 0, until_at = now + window_for(name) }
    end

    --- Damage dealt by one of our spells, from the combat log.
    ---@param name string
    ---@param amount number
    function D.damage(name, amount)
        local st = stats[name]
        if not st or not st.open then return end
        local now = core.time()
        if now > st.open.until_at then
            close(st)
            return
        end
        st.open.total = st.open.total + amount
    end

    -- --- dealt: everything we did to each mob ----------------------------------
    --
    -- Threat is, for most of what a damage dealer does, the damage itself. The
    -- client says how close we are to pulling a mob as a percent; what that
    -- percent will be after the NEXT spell needs what we have put on it so
    -- far. Every hit counts, a melee swing and an Auto Shot included.

    local dealt = {}               -- mob guid -> { total, at }
    local DEALT_KEEP = 60          -- seconds without a hit before a mob's tally goes

    --- Damage of ours that landed on a mob.
    ---@param guid string|nil
    ---@param amount number
    function D.dealt_to(guid, amount)
        if type(guid) ~= "string" or type(amount) ~= "number" or amount <= 0 then return end
        local now = core.time()
        local d = dealt[guid]
        if not d or (now - d.at) > DEALT_KEEP then
            d = { total = 0, at = now }
            dealt[guid] = d
        end
        d.total, d.at = d.total + amount, now
    end

    --- Everything we have dealt this mob, this fight.
    ---@param guid string|nil
    ---@return number
    function D.dealt(guid)
        local d = guid and dealt[guid]
        if not d or (core.time() - d.at) > DEALT_KEEP then return 0 end
        return d.total
    end

    --- A fight ended: every tally goes.
    function D.reset_dealt()
        for k in pairs(dealt) do dealt[k] = nil end
    end

    --- Closes windows that ran out, so an average does not wait for the next cast.
    function D.tick()
        local now = core.time()
        for _, st in pairs(stats) do
            if st.open and now > st.open.until_at then close(st) end
        end
    end

    --- The measured damage of one cast, and how many casts it is averaged over.
    ---@param name string
    ---@return number|nil
    ---@return integer casts
    function D.measured(name)
        local st = stats[name]
        if not st or not st.avg then return nil, 0 end
        return st.avg, st.casts
    end

    -- --- prior: the tooltip --------------------------------------------------------

    local prior_cache = {}         -- spell id -> parsed (or false)

    --- What the tooltip text says a spell does.
    ---@param text string
    ---@return table|nil { direct?, dot?, duration? }
    function D.parse(text)
        if type(text) ~= "string" or text == "" then return nil end
        local t = text:gsub(",", "")
        local out = {}
        -- "40 Shadow damage over 12 sec", "40 damage over 12 sec"
        local total, secs = t:match("(%d+)%s+%a+%s+damage over (%d+) sec")
        if not total then total, secs = t:match("(%d+)%s+damage over (%d+) sec") end
        if total then
            out.dot = tonumber(total)
            out.duration = tonumber(secs)
        end
        -- "13 to 18 Shadow damage" (the first range is the hit)
        local lo, hi = t:match("(%d+) to (%d+)")
        if lo then
            out.direct = (tonumber(lo) + tonumber(hi)) / 2
        elseif not total then
            local single = t:match("(%d+)%s+%a+%s+damage") or t:match("(%d+)%s+damage")
            if single then out.direct = tonumber(single) end
        end
        if not out.direct and not out.dot then return nil end
        return out
    end

    --- The tooltip's word on a spell, by name (its current rank).
    ---@param name string
    ---@return table|nil
    function D.prior(name)
        local id = book and book.id and book.id(name) or nil
        if not id then return nil end
        local hit = prior_cache[id]
        if hit ~= nil then return hit or nil end
        local text = nil
        local sb = core.spell_book
        if type(sb) == "table" and type(sb.get_spell_description) == "function" then
            local ok, value = pcall(sb.get_spell_description, id)
            if ok then text = value end
        end
        local parsed = D.parse(text)
        prior_cache[id] = parsed or false
        return parsed
    end

    -- A new rank, a new tooltip.
    if ctx and ctx.on then
        ctx.on("jambix.aio.spells_changed", function() prior_cache = {} end)
    end

    --- What one cast of this spell is worth against a target with `ttd`
    --- seconds to live: the measured average once it exists, the tooltip
    --- until then. Damage over time counts only the part it lives to take.
    ---@param name string
    ---@param ttd number|nil
    ---@return number|nil damage
    ---@return string|nil source "measured" | "tooltip"
    function D.expected(name, ttd)
        local measured, casts = D.measured(name)
        local prior = D.prior(name)
        local value, source
        if measured and casts >= 2 then
            value, source = measured, "measured"
            -- A measured DoT is its whole window; scale to what the target lives through.
            local window = window_for(name) - 1.5
            if type(ttd) == "number" and ttd > 0 and ttd < window and window > 3 then
                value = value * max(0.15, ttd / window)
            end
        elseif prior then
            value, source = prior.direct or 0, "tooltip"
            if prior.dot then
                local share = 1
                if type(ttd) == "number" and ttd > 0 and prior.duration and ttd < prior.duration then
                    share = ttd / prior.duration
                end
                value = value + prior.dot * share
            end
        end
        if not value or value <= 0 then return nil, nil end
        return value, source
    end

    --- What is left of a unit, in health points.
    ---@param unit game_object|nil
    ---@return number|nil
    function D.remaining(unit)
        if not unit or not units.health then return nil end
        local ok, hp = pcall(units.health, unit)
        if ok and type(hp) == "number" and hp > 0 then return hp end
        return nil
    end

    function D.stats() return stats end

    return D
end

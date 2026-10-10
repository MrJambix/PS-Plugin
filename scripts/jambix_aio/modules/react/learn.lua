-- Jambix AIO / react / learn -- what this session's fights have taught us.
--
-- The catalogue says what a spell does in general. The client says, every
-- fight, what it did HERE -- and until 1.37.0 nothing kept the answer. Since
-- 1.35.2 the rotation's own presses are never backed off (a back-off held
-- Auto Shot for seconds after the mob walked into range), so a spell the mob
-- is immune to would be pressed again every second, and an immune hit still
-- costs the mana and the global cooldown. This remembers, by mob NAME -- every
-- Savannah Prowler is the same size and immune to the same things -- and the
-- rotation and the reactions ask it before the next press:
--
--   IMMUNE   the combat log's *_MISSED with IMMUNE, or the client's "Immune"
--            after a press. One answer holds that spell on that one mob for
--            SUSPECT_FOR seconds; the same answer from a second mob of the
--            name, or from the same mob SETTLE_APART seconds later, learns it
--            for the name. Not when that mob was immune to something else in
--            the same moment -- that is a bubble, not what the mob is -- and
--            a hit from the spell on the name unlearns it.
--   RANGE    "Target too close" at a reading of d yards moves that mob's
--            inside edge out to d + 0.5; "Out of range" at d, where the
--            catalogue said it reaches, moves that spell's outside edge on
--            that mob in to d - 0.5. Only from a steady gap (a mob running
--            in moves its own reading) and never by more than RANGE_CAP.
--   EVADE    *_MISSED with EVADE: the mob is going home and nothing lands.
--            Held EVADE_HOLD seconds after the last one. The pet's own misses
--            count too: it is usually the one still hitting it.
--   RUNNERS  most humanoids run at about a fifth of their health and come
--            back with company. A mob of the name seen fleeing while low says
--            the name runs; two of the name that went under 15% and died where
--            they stood say it does not. Until then the creature type decides.
--
-- Everything is for the session: a reload starts over, which is also the
-- way out of anything learned wrong.

return function(P)
    local units = P.units

    local L = {}

    local SUSPECT_FOR = 12        -- one immune answer: that spell, that mob, this long
    local PLAYER_SUSPECT = 4      -- a player's: its bubble, read again this soon (1.81.0)
    local SETTLE_APART = 12       -- the same mob immune again this much later is no bubble
    local BUBBLE_WINDOW = 3       -- immune to two different spells this close together: a bubble
    local EVADE_HOLD = 4
    local RANGE_CAP = 3           -- yards a learned edge may move from the catalogue's
    local STEADY = 1.0            -- yards a second: a gap moving faster is not read

    local RUN_LOW, HELD_LOW = 0.35, 0.15
    local GONE_AFTER = 3          -- seconds unseen: dead, or out of reach

    local mobs = {}               -- name -> { immune = { [spell] = entry }, too_close = d, out = { [spell] = d } }
    local watched = {}            -- guid -> { name, low, fled, seen }
    local runs = {}               -- name -> { fled, held }
    local suspect = {}            -- guid -> { [spell] = until }
    local last_immune = {}        -- guid -> { spell, at }
    local evading = {}            -- guid -> at
    local news = {}               -- learned since the journal last read, oldest first

    local function now() return core.time() end

    --- The name a mob's lessons are kept under. The client's own on Era;
    --- on Forever, where get_name reads "" for units, init.lua swaps in one
    --- that knows the names our casts reported.
    function L.name_of(unit)
        return units.name(unit)
    end

    local function mob(name)
        local m = mobs[name]
        if not m then
            m = { immune = {}, too_close = nil, out = {} }
            mobs[name] = m
        end
        return m
    end

    local function say(text)
        news[#news + 1] = text
        if #news > 10 then table.remove(news, 1) end
    end

    -- --- what the client answered ------------------------------------------------

    --- A miss of ours in the combat log.
    ---@param guid string|nil the mob
    ---@param name string|nil the mob's name
    ---@param spell string|nil
    ---@param miss string|nil the miss type: IMMUNE, EVADE, RESIST, DODGE...
    function L.on_miss(guid, name, spell, miss)
        if type(guid) ~= "string" then return end
        local t = now()
        if miss == "EVADE" then
            if not evading[guid] or (t - evading[guid]) > EVADE_HOLD then
                say(string.format("%s is evading: nothing lands until it is back", name or "the mob"))
            end
            evading[guid] = t
            return
        end
        if miss ~= "IMMUNE" or type(spell) ~= "string" or type(name) ~= "string" then return end

        -- A PLAYER'S IMMUNITY IS A BUFF (1.81.0): Divine Shield, Ice Block,
        -- Blessing of Protection. Held on that one player for a moment and
        -- never learned for the name: a paladin who bubbled twice twelve
        -- seconds apart is not immune to Sinister Strike for the session.
        -- react/pvp.lua reads the buff itself.
        if guid:find("^Player%-") then
            local held = suspect[guid] or {}
            suspect[guid] = held
            held[spell] = t + PLAYER_SUSPECT
            return
        end

        -- Immune to two different spells inside a moment: a bubble on this
        -- one mob, which says nothing about the rest of its name.
        local prev = last_immune[guid]
        local bubble = prev ~= nil and prev.spell ~= spell and (t - prev.at) <= BUBBLE_WINDOW
        last_immune[guid] = { spell = spell, at = t }

        local held = suspect[guid] or {}
        suspect[guid] = held
        held[spell] = t + SUSPECT_FOR
        if bubble then
            -- The first answer of the pair was the bubble too: it counts for nothing.
            local m = mobs[name]
            local pe = m and m.immune[prev.spell]
            if pe and not pe.learned and pe.guid == guid and pe.n <= 1 then m.immune[prev.spell] = nil end
            return
        end

        local e = mob(name).immune[spell]
        if not e then
            e = { learned = false, guid = guid, at = t, n = 0 }
            mob(name).immune[spell] = e
        end
        e.n = e.n + 1
        if not e.learned and (e.guid ~= guid or (t - e.at) >= SETTLE_APART) then
            e.learned = true
            say(string.format("%s is immune to %s", name, spell))
        end
    end

    --- A hit of ours: whatever was learned about that spell on that name was wrong.
    ---@param name string|nil
    ---@param spell string|nil
    function L.on_hit(name, spell)
        local m = name and mobs[name]
        local e = m and spell and m.immune[spell]
        if not e then return end
        m.immune[spell] = nil
        if e.learned then say(string.format("%s took %s after all: not immune", name, spell)) end
    end

    --- The client's red text after a press of ours, with where the mob was.
    ---@param kind string "too_close" | "out_of_range" | "immune"
    ---@param spell string
    ---@param unit game_object|nil the press's target
    ---@param distance number|nil centre to centre, now
    ---@param closing number|nil yards a second, towards us
    ---@param reach number|nil the spell's catalogue reach, for out of range
    ---@param inner number|nil the spell's catalogue minimum, for too close
    function L.on_error(kind, spell, unit, distance, closing, reach, inner)
        if not unit then return end
        local name = L.name_of(unit)
        if type(name) ~= "string" or name == "" then return end
        if kind == "immune" then
            L.on_miss(units.guid(unit), name, spell, "IMMUNE")
            return
        end
        if type(distance) ~= "number" or math.abs(closing or 0) > STEADY then return end
        local m = mob(name)
        if kind == "too_close" and type(inner) == "number" and inner > 0 then
            -- Too close at d: the edge is past d. Never more than the cap past the catalogue's.
            local d = math.min(distance, inner + RANGE_CAP - 0.5)
            if d >= inner - 1 and (not m.too_close or d > m.too_close) then
                m.too_close = d
                say(string.format("%s: too close at %.1fy -- its dead zone reaches %.1fy", name, distance, d + 0.5))
            end
        elseif kind == "out_of_range" and type(reach) == "number" and reach > 0 then
            -- Out of range at d, inside the reach: the edge is short of d.
            if distance <= reach + 1 and distance >= reach - RANGE_CAP then
                local was = m.out[spell]
                if not was or distance < was then
                    m.out[spell] = distance
                    say(string.format("%s: %s out of range at %.1fy -- it reaches %.1fy on this mob",
                        name, spell, distance, distance - 0.5))
                end
            end
        end
    end

    -- --- what the rotation and the reactions ask -----------------------------------

    --- Why this spell will not land on this unit, from what the fights taught, or nil.
    ---@param spell string
    ---@param unit game_object|nil
    ---@return string|nil
    function L.blocks(spell, unit)
        if not unit then return nil end
        local guid = units.guid(unit)
        local t = now()
        local at = guid and evading[guid]
        if at and (t - at) <= EVADE_HOLD then return "it is evading: nothing lands" end
        local name = L.name_of(unit)
        local m = name and mobs[name]
        local e = m and m.immune[spell]
        if e and e.learned then return string.format("learned: %s is immune to it", name) end
        local held = guid and suspect[guid]
        local until_at = held and held[spell]
        if until_at and t < until_at then
            local held_for = guid:find("^Player%-") and PLAYER_SUSPECT or SUSPECT_FOR
            return string.format("it was immune to it %.0fs ago", held_for - (until_at - t))
        end
        return nil
    end

    --- The range edges for a spell on this unit, moved by what was learned.
    ---@param spell string
    ---@param unit game_object|nil
    ---@param min number the catalogue's minimum
    ---@param max number the catalogue's reach
    ---@return number min
    ---@return number max
    ---@return boolean learned
    function L.range(spell, unit, min, max)
        local name = unit and L.name_of(unit)
        local m = name and mobs[name]
        if not m then return min, max, false end
        local learned = false
        if min > 0 and m.too_close and m.too_close + 0.5 > min then
            min, learned = math.min(m.too_close + 0.5, min + RANGE_CAP), true
        end
        local out = m.out[spell]
        if out and out - 0.5 < max then
            max, learned = math.max(out - 0.5, max - RANGE_CAP), true
        end
        return min, max, learned
    end

    --- One tick of the fight's rows: who is low, who is running.
    ---@param rows table[]|nil the enemies rows (obj, guid, hp, engaged, activity)
    ---@param n integer|nil
    function L.observe(rows, n)
        local t = now()
        for i = 1, n or 0 do
            local row = rows[i]
            if row and row.guid and row.engaged then
                local w = watched[row.guid]
                if not w then
                    local name = row.obj and L.name_of(row.obj)
                    if type(name) == "string" and name ~= "" then
                        w = { name = name, low = 1, fled = false, seen = t }
                        watched[row.guid] = w
                    end
                end
                if w then
                    w.seen = t
                    local hp = tonumber(row.hp) or 1
                    if hp < w.low then w.low = hp end
                    if row.activity == "fleeing" and hp < RUN_LOW and not w.fled then
                        w.fled = true
                        local r = runs[w.name] or { fled = 0, held = 0 }
                        runs[w.name] = r
                        r.fled = r.fled + 1
                        if r.fled == 1 then say(string.format("%s runs when it is low", w.name)) end
                    end
                end
            end
        end
        -- Gone. Low and never ran: it stood its ground.
        for guid, w in pairs(watched) do
            if (t - w.seen) > GONE_AFTER then
                if not w.fled and w.low < HELD_LOW then
                    local r = runs[w.name] or { fled = 0, held = 0 }
                    runs[w.name] = r
                    r.held = r.held + 1
                    if r.held == 2 and r.fled == 0 then
                        say(string.format("%s fights to the end: no slow kept for it", w.name))
                    end
                end
                watched[guid] = nil
            end
        end
    end

    --- Does a mob of this name run when it is low? nil until the fights have said.
    ---@param name string|nil
    ---@return boolean|nil
    function L.runs(name)
        local r = name and runs[name]
        if not r then return nil end
        if r.fled > 0 then return true end
        if r.held >= 2 then return false end
        return nil
    end

    --- Is this mob going home?
    ---@param guid string|nil
    ---@return boolean
    function L.evading(guid)
        local at = guid and evading[guid]
        return at ~= nil and (now() - at) <= EVADE_HOLD
    end

    --- What was learned since the last call, for the journal.
    ---@return string[]
    function L.drain()
        if #news == 0 then return news end
        local out = news
        news = {}
        return out
    end

    --- One line for the readout.
    ---@return string|nil
    function L.summary()
        local parts = {}
        for name, m in pairs(mobs) do
            for spell, e in pairs(m.immune) do
                if e.learned then parts[#parts + 1] = string.format("%s immune to %s", name, spell) end
            end
            if m.too_close then parts[#parts + 1] = string.format("%s dead zone %.1fy", name, m.too_close + 0.5) end
            for spell, d in pairs(m.out) do
                parts[#parts + 1] = string.format("%s %s reaches %.1fy", name, spell, d - 0.5)
            end
        end
        for name, r in pairs(runs) do
            if r.fled > 0 then
                parts[#parts + 1] = string.format("%s runs", name)
            elseif r.held >= 2 then
                parts[#parts + 1] = string.format("%s stands", name)
            end
        end
        if #parts == 0 then return nil end
        table.sort(parts)
        return table.concat(parts, "; ", 1, math.min(#parts, 4))
    end

    --- A fight ended: the per-mob holds go; what was learned by name stays.
    function L.combat_end()
        for k in pairs(suspect) do suspect[k] = nil end
        for k in pairs(last_immune) do last_immune[k] = nil end
        for k in pairs(evading) do evading[k] = nil end
    end

    return L
end

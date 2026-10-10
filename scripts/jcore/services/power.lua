-- JCore / power -- the player's resources where the client cannot read them
-- (JCore 1.6.0; Jambix AIO's modules/forever_power.lua until AIO 1.55.0).
--
-- player.power() and player.max_power() hand their raw read here on Forever
-- and answer what comes back; on every other client they never call it, and
-- this service reads nothing, registers nothing that runs, answers nothing.
--
-- THE EVIDENCE (the JCore API recorder, 2026-10-02: a rogue on the Forever
-- beta, 18 sessions). get_power answered 0 on every one of its 164,586 calls
-- while energy was spent and combo points built, and get_max_power answered 0
-- too. What DOES work there: the cast events (UNIT_SPELLCAST_SUCCEEDED),
-- get_spell_costs (Sinister Strike: 45, cost_type 3), get_base_power_regen,
-- is_usable_spell, the client's "Not enough energy" red text, and the
-- tooltips. (A later hunter recording read its mana: a read that answers is
-- used as it is.)
--
-- So a resource is TRUSTED the moment its read says anything but 0. Until then:
--   COMBO POINTS  counted from our own casts. A builder adds what its tooltip
--                 awards ("Awards 1 combo point", Cheap Shot's 2), a finisher
--                 ("Finishing move") spends them all. Ten seconds out of
--                 combat starts again at 0. A finisher the client calls
--                 usable means at least one; the client's "requires combo
--                 points" means none. A new target keeps them (1.8.12):
--                 Forever's guides say combo points no longer drop on a
--                 target change, and zeroing them there lost points the
--                 player still had. Were the guides wrong, the first finisher
--                 is refused with that red text and the count goes to 0.
--   ENERGY, RAGE  spent by each cast's own cost, energy regenerating at the
--                 client's rate, rage building in combat at RAGE_GAIN a second
--                 (an estimate) and fading out of it. Corrected both ways by
--                 the client: a spell it calls usable means at least its cost;
--                 "Not enough energy" after a press means less. Every known
--                 spell is such a probe from the start (else a warrior's rage
--                 stayed 0 and Heroic Strike never came). Entering Bear or Cat
--                 Form starts that form's bar at 0.
--   MANA          not counted: no maximum is readable. The read stays 0 of 0,
--                 and unread() says the bar is fine -- or, for a few seconds
--                 after "Not enough mana", dry, until a spell that costs mana
--                 is usable again.

local IDS = { MANA = 0, RAGE = 1, FOCUS = 2, ENERGY = 3, COMBOPOINTS = 4 }
local KIND_OF = {}
for k, v in pairs(IDS) do KIND_OF[v] = k end
local MODEL_MAX = { ENERGY = 100, RAGE = 100, COMBOPOINTS = 5 }
local RAGE_FADE = 1.25         -- a second, out of combat
local RAGE_GAIN = 3.5          -- a second, in combat: an estimate the client corrects
local CP_FADE_AFTER = 10       -- seconds out of combat before the points go
local DRY_FOR = 8              -- seconds "Not enough mana" holds
local PROBES = 3               -- usability checks per read, at most
local NOT_ENOUGH = { energy = "ENERGY", rage = "RAGE", mana = "MANA" }
-- A druid's form starts its own bar: Bear Form at 0 rage, Cat Form at 0 energy.
local FORM_BAR = { ["Bear Form"] = "RAGE", ["Dire Bear Form"] = "RAGE", ["Cat Form"] = "ENERGY" }

return function(rt)
    local log = rt.log.for_tag("JCore/power")
    local events = rt.events

    local M = {}
    M.IDS = IDS

    local forever = nil
    local function on_forever()
        if forever ~= nil then return forever end
        local world = rt.world
        if not (world and world.client) then return false end
        local ok, c = pcall(world.client)
        if not ok or type(c) ~= "table" then return false end
        forever = c.forever == true
        return forever
    end

    local trusted = {}             -- kind -> true once the read said anything but 0
    local model = {}               -- kind -> { value, at }
    local costs = {}               -- spell_id -> { [kind] = cost }
    local probes = {}              -- kind -> { spell_id -> cost }
    local awards = {}              -- spell_id -> combo points it awards (0 if none), -1 a finisher
    local last_press = nil         -- { id, at }: what "Not enough X" is about
    local left_combat_at = nil
    local dry_until = 0
    local seeded = false
    local stats = { casts = 0, corrected = 0, refused = 0 }

    local function now() return core.time() end

    local function in_combat()
        local combat = rt.combat
        local ok, v = pcall(function() return combat and combat.in_combat and combat.in_combat() end)
        return ok and v == true
    end

    local function kind_of(power_type)
        if type(power_type) == "string" then return power_type end
        return KIND_OF[tonumber(power_type) or -1]
    end

    -- --- what a spell costs and does --------------------------------------------

    local function costs_of(spell_id)
        local c = costs[spell_id]
        if c then return c end
        c = {}
        local ok, list = pcall(core.spell_book.get_spell_costs, spell_id)
        if ok and type(list) == "table" then
            for i = 1, #list do
                local row = list[i]
                local kind = type(row) == "table" and KIND_OF[tonumber(row.cost_type)]
                local cost = type(row) == "table" and (tonumber(row.min_cost) or tonumber(row.cost)) or nil
                if kind and cost and cost > 0 then c[kind] = cost end
            end
        end
        costs[spell_id] = c
        return c
    end

    --- What a spell does to combo points, from its tooltip: N awarded, a
    --- finisher (-1), or nothing (0). Read once per spell.
    local function award_of(spell_id)
        local a = awards[spell_id]
        if a ~= nil then return a end
        a = 0
        local ok, text = pcall(core.spell_book.get_spell_description, spell_id)
        if ok and type(text) == "string" then
            local lower = text:lower()
            if lower:find("finishing move", 1, true) then
                a = -1
            else
                a = tonumber(lower:match("awards (%d+) combo point")) or 0
            end
        end
        awards[spell_id] = a
        return a
    end

    local function add_probe(kind, spell_id, need)
        probes[kind] = probes[kind] or {}
        probes[kind][spell_id] = need
    end

    --- Every known spell's cost (and every finisher) as a probe, so the
    --- client's usable answers correct a counted bar before anything is cast.
    local function seed()
        seeded = true
        local ok, list = pcall(core.spell_book.get_spells)
        if not ok or type(list) ~= "table" then return end
        local seen = {}
        local function consider(id)
            if type(id) ~= "number" or id <= 0 or seen[id] then return end
            seen[id] = true
            local ok_k, known = pcall(core.spell_book.is_spell_known, id)
            if not ok_k or not known then return end
            for kind, cost in pairs(costs_of(id)) do add_probe(kind, id, cost) end
            if award_of(id) < 0 then add_probe("COMBOPOINTS", id, 1) end
        end
        for k, v in pairs(list) do
            consider(k)
            consider(v)
        end
    end

    -- --- the model ---------------------------------------------------------------

    local function state(kind)
        local m = model[kind]
        if not m then
            m = { value = (kind == "ENERGY") and MODEL_MAX[kind] or 0, at = now() }
            model[kind] = m
        end
        return m
    end

    local function regen_rate(kind)
        if kind == "ENERGY" then
            local ok, rate = pcall(core.spell_book.get_base_power_regen)
            rate = ok and tonumber(rate) or nil
            if rate and rate > 0 and rate < 100 then return rate end
            return 10
        elseif kind == "RAGE" then
            return in_combat() and RAGE_GAIN or -RAGE_FADE
        end
        return 0
    end

    --- Brings a counted resource up to now: regeneration, the fade out of
    --- combat, and a new target for combo points.
    local function advance(kind)
        local m = state(kind)
        local t = now()
        local dt = t - m.at
        m.at = t
        if kind == "COMBOPOINTS" then
            if not in_combat() then
                left_combat_at = left_combat_at or t
                if (t - left_combat_at) > CP_FADE_AFTER then m.value = 0 end
            else
                left_combat_at = nil
            end
        elseif dt > 0 then
            m.value = m.value + regen_rate(kind) * dt
        end
        local top = MODEL_MAX[kind] or 0
        if m.value > top then m.value = top end
        if m.value < 0 then m.value = 0 end
        return m
    end

    local function usable_now(spell_id)
        local spells = rt.spells
        if spells and spells.usable then return pcall(spells.usable, spell_id) end
        return pcall(core.spell_book.is_usable_spell, spell_id)
    end

    --- The client's own word: a spell it calls usable means we have at least
    --- its cost (or, for a finisher, at least one point).
    local function correct(kind, m)
        local list = probes[kind]
        if not list then return end
        local asked = 0
        for spell_id, need in pairs(list) do
            if m.value < need then
                local ok, usable = usable_now(spell_id)
                asked = asked + 1
                if ok and usable == true then
                    m.value = need
                    stats.corrected = stats.corrected + 1
                end
                if asked >= PROBES then return end
            end
        end
    end

    -- --- the reads -----------------------------------------------------------------

    --- The player's current value of a resource, given the client's read.
    ---@param power_type integer|string
    ---@param raw number
    ---@return number
    function M.read(power_type, raw)
        if not on_forever() then return raw end
        local kind = kind_of(power_type)
        if not kind or trusted[kind] then return raw end
        if type(raw) == "number" and raw ~= 0 then
            trusted[kind] = true
            log.fmt("info", "the client reads %s (%s): using it", kind, tostring(raw))
            return raw
        end
        if not MODEL_MAX[kind] then return raw end
        if not seeded then seed() end
        local m = advance(kind)
        correct(kind, m)
        return math.floor(m.value + 0.5)
    end

    ---@param power_type integer|string
    ---@param raw number the client's maximum
    ---@return number
    function M.max(power_type, raw)
        if not on_forever() then return raw end
        local kind = kind_of(power_type)
        if not kind or trusted[kind] or (type(raw) == "number" and raw > 0) then return raw end
        return MODEL_MAX[kind] or raw
    end

    --- For a resource with no readable maximum (mana on Forever): 1 while
    --- nothing says otherwise, low for a moment after the client said there
    --- was not enough. nil when the read works, or on any other client.
    ---@param power_type integer|string
    ---@return number|nil
    function M.unread(power_type)
        if not on_forever() then return nil end
        local kind = kind_of(power_type)
        if not kind or trusted[kind] or MODEL_MAX[kind] then return nil end
        if now() < dry_until then
            local list = probes[kind]
            if list then
                for spell_id in pairs(list) do
                    local ok, usable = usable_now(spell_id)
                    if ok and usable == true then
                        dry_until = 0
                        return 1
                    end
                end
            end
            return 0.05
        end
        return 1
    end

    --- Is this resource counted rather than read?
    ---@param power_type integer|string
    ---@return boolean
    function M.counted(power_type)
        if not on_forever() then return false end
        local kind = kind_of(power_type)
        return kind ~= nil and not trusted[kind] and MODEL_MAX[kind] ~= nil
    end

    --- One line for a readout.
    ---@return string
    function M.summary()
        if not on_forever() then return "read by the client" end
        local parts = {}
        for _, kind in ipairs({ "ENERGY", "RAGE", "COMBOPOINTS", "MANA" }) do
            if trusted[kind] then
                parts[#parts + 1] = kind:lower() .. " read"
            elseif model[kind] then
                parts[#parts + 1] = string.format("%s counted (%d)", kind:lower(), math.floor(model[kind].value + 0.5))
            end
        end
        if #parts == 0 then parts[1] = "nothing read or counted yet" end
        return table.concat(parts, ", ")
    end

    function M.stats() return stats end

    -- --- the events (Forever only) ---------------------------------------------------

    local opts = { owner = "jcore", priority = 0 }

    events.on("jcore.game_event.SPELLS_CHANGED", function()
        if on_forever() and seeded then seed() end
    end, opts)

    events.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
        if not on_forever() then return end
        if type(args) ~= "table" or args[1] ~= "player" then return end
        local spell_id = tonumber(args[3])
        if not spell_id or spell_id <= 0 then return end
        stats.casts = stats.casts + 1
        local ok_name, name = pcall(core.spell_book.get_spell_name, spell_id)
        local bar = ok_name and FORM_BAR[name]
        if bar and not trusted[bar] then
            local m = advance(bar)
            m.value = 0
        end
        for kind, cost in pairs(costs_of(spell_id)) do
            add_probe(kind, spell_id, cost)
            if MODEL_MAX[kind] and not trusted[kind] then
                local m = advance(kind)
                m.value = math.max(0, m.value - cost)
            end
        end
        if not trusted.COMBOPOINTS then
            local a = award_of(spell_id)
            if a ~= 0 then
                local m = advance("COMBOPOINTS")
                if a < 0 then
                    m.value = 0
                    add_probe("COMBOPOINTS", spell_id, 1)
                else
                    m.value = math.min(MODEL_MAX.COMBOPOINTS, m.value + a)
                end
            end
        end
    end, opts)

    events.on("jcore.cast.sent", function(request)
        if on_forever() and type(request) == "table" and request.spell_id then
            last_press = { id = request.spell_id, at = now() }
        end
    end, opts)

    events.on("jcore.game_event.UI_ERROR_MESSAGE", function(args)
        if not on_forever() or type(args) ~= "table" then return end
        local text = type(args[2]) == "string" and args[2]:lower() or ""
        -- "That ability requires combo points": there are none (1.8.12).
        if text:find("requires combo point", 1, true) and not trusted.COMBOPOINTS then
            stats.refused = stats.refused + 1
            advance("COMBOPOINTS").value = 0
            return
        end
        local word = text:match("not enough (%a+)")
        local kind = word and NOT_ENOUGH[word]
        if not kind or trusted[kind] then return end
        stats.refused = stats.refused + 1
        if kind == "MANA" then
            dry_until = now() + DRY_FOR
            return
        end
        if last_press and (now() - last_press.at) < 1.0 then
            local cost = costs_of(last_press.id)[kind]
            if cost then
                local m = advance(kind)
                if m.value >= cost then m.value = cost - 1 end
            end
        end
    end, opts)

    events.on("jcore.combat.leave", function()
        if on_forever() then left_combat_at = now() end
    end, opts)

    return M
end

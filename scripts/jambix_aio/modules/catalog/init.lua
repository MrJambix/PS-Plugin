-- Jambix AIO / catalog -- what each ability IS, for anything that wants to ask.
--
-- Until this existed nothing in the plugin or the core knew what a skill did.
-- The core knows a spell's cooldown, range, cost and whether it is usable;
-- the rotation knows what to press because a class file says so, one rule at
-- a time. "Serpent Sting is a damage-over-time effect" lived only as a tag
-- somebody typed on a rule; "Concussive Shot slows" lived only in the fact
-- that a rule fires it at runners. Nothing could answer "which of my spells
-- slow", and a trained ability no rule named was invisible.
--
-- The catalogue is one data file per class (modules/catalog/<class>.lua)
-- describing every ability -- role, kind, resource, range, what it needs,
-- what it applies, what it does, how it works with the others -- every
-- talent and what it changes, and the combinations that only exist between
-- abilities. This module loads the right one for the character, indexes it,
-- and merges it with what is LIVE: whether each ability is trained, the
-- rank of each talent. The coverage check on the Debug page names every
-- trained ability the catalogue does not describe, which is what keeps the
-- data honest as characters level.
--
-- What it does NOT do: decide anything. The class rule lists still say what
-- to press and when. This says what things are, so those lists -- and the
-- weave, the enemies reader -- can ask instead of restating.

return function(P)
    local ctx, log = P.ctx, P.log

    local M = {}

    -- Class key -> data file. A class with no file simply has no catalogue,
    -- and everything below answers nil or empty for it.
    local FILES = {
        hunter = "modules/catalog/hunter",
    }

    local loaded = {}   -- key -> data | false

    --- Loads and indexes one class's data file, once.
    ---@param key string
    ---@return table|nil
    local function load(key)
        local have = loaded[key]
        if have ~= nil then return have or nil end

        local file = FILES[key]
        if not file then
            loaded[key] = false
            return nil
        end

        local ok, data = pcall(P.load, file)
        if not ok or type(data) ~= "table" or type(data.abilities) ~= "table" then
            loaded[key] = false
            log.fmt("warn", "catalogue for %s failed to load: %s", key, tostring(data))
            return nil
        end

        -- WHICH CLIENT. One file describes Era and Forever: `client =
        -- "forever"` marks a row only Forever has, `client = "era"` a row
        -- Forever lacks, and a row's `forever` table holds what Forever
        -- changes, laid over the row there. Both fields are read here and
        -- removed, so a row reaches its readers as it would from a file
        -- written for that client alone -- on Era, exactly the rows it
        -- always had.
        local other = P.forever and "era" or "forever"
        for _, rows in ipairs({ data.abilities, data.talents or {} }) do
            for name, row in pairs(rows) do
                if row.client == other then
                    rows[name] = nil
                else
                    if P.forever and type(row.forever) == "table" then
                        for field, value in pairs(row.forever) do row[field] = value end
                    end
                    row.client, row.forever = nil, nil
                end
            end
        end

        data.by_lower = {}
        data.by_role = {}
        data.count = 0
        for name, row in pairs(data.abilities) do
            row.name = name
            data.by_lower[name:lower()] = row
            data.count = data.count + 1
            for i = 1, #(row.roles or {}) do
                local role = row.roles[i]
                local list = data.by_role[role]
                if not list then
                    list = {}
                    data.by_role[role] = list
                end
                list[#list + 1] = row
            end
        end
        data.talent_count = 0
        for name, talent in pairs(data.talents or {}) do
            talent.name = name
            data.talent_count = data.talent_count + 1
        end

        loaded[key] = data
        log.fmt("info", "catalogue: %s -- %d abilities, %d talents, %d combos",
            data.label or key, data.count, data.talent_count, #(data.combos or {}))
        return data
    end

    -- --- which catalogue ----------------------------------------------------

    --- The catalogue for a class key ("hunter"), or nil.
    ---@param key string
    ---@return table|nil
    function M.for_class(key)
        return key and load(key) or nil
    end

    --- The catalogue for the character being played, or nil.
    ---
    --- The class module's key when the rotation has resolved one, and the
    --- detected class name lowered before that -- "HUNTER" -> "hunter" --
    --- so the Debug page can answer before the first rotation tick.
    ---@return table|nil
    function M.current()
        local rotation = P.rotation
        if not rotation then return nil end
        local class_module = rotation.active_class()
        local key = class_module and class_module.key
        if not key then
            local name = rotation.detect_class()
            key = type(name) == "string" and name:lower() or nil
        end
        return key and load(key) or nil
    end

    -- --- abilities ----------------------------------------------------------

    --- The row for an ability by name, case-insensitive, or nil.
    ---@param name string
    ---@return table|nil
    function M.ability(name)
        local data = M.current()
        if not data or type(name) ~= "string" then return nil end
        return data.by_lower[name:lower()]
    end

    --- Every catalogued ability with a role, optionally only the ones the
    --- character has trained. "Which of my spells slow?" is this call.
    ---@param role string
    ---@param known_only? boolean
    ---@return table[] rows
    function M.with_role(role, known_only)
        local data = M.current()
        if not data then return {} end
        local out = {}
        local list = data.by_role[role] or {}
        for i = 1, #list do
            local row = list[i]
            if not known_only or P.spellbook.known(row.name) then out[#out + 1] = row end
        end
        return out
    end

    --- Does this ability have this role?
    ---@param name string
    ---@param role string
    ---@return boolean
    function M.has_role(name, role)
        local row = M.ability(name)
        if not row then return false end
        for i = 1, #(row.roles or {}) do
            if row.roles[i] == role then return true end
        end
        return false
    end

    --- The aura an ability puts on its target (or on you), or nil.
    ---@param name string
    ---@return string|nil aura
    ---@return string|nil on "target" | "self" | "pet" | "party" | "ground"
    function M.applies(name)
        local row = M.ability(name)
        local applies = row and row.applies
        if type(applies) ~= "table" then return nil, nil end
        return applies.aura, applies.on
    end

    --- The combinations an ability takes part in.
    ---@param name string
    ---@return table[] combos
    function M.combos_using(name)
        local data = M.current()
        if not data or type(name) ~= "string" then return {} end
        local out = {}
        local lowered = name:lower()
        for i = 1, #(data.combos or {}) do
            local combo = data.combos[i]
            for j = 1, #(combo.uses or {}) do
                if combo.uses[j]:lower() == lowered then
                    out[#out + 1] = combo
                    break
                end
            end
        end
        return out
    end

    -- --- talents ------------------------------------------------------------

    --- A talent's catalogue row merged with its live rank.
    ---@param name string
    ---@return table|nil { name, tree, tier, max, effect, affects, rank }
    function M.talent(name)
        local data = M.current()
        local row = data and data.talents and data.talents[name]
        if not row then return nil end
        local rank = P.talents and P.talents.rank(name) or 0
        return {
            name = name, tree = row.tree, tier = row.tier, max = row.max,
            effect = row.effect, affects = row.affects, expansion = row.expansion,
            rank = rank, taken = rank > 0,
        }
    end

    --- Every talent that changes an ability, with the live rank of each.
    --- "What do my talents do to Serpent Sting?" is this call.
    ---@param ability_name string
    ---@param taken_only? boolean
    ---@return table[]
    function M.talents_affecting(ability_name, taken_only)
        local data = M.current()
        if not data or type(ability_name) ~= "string" then return {} end
        local out = {}
        local lowered = ability_name:lower()
        for name, row in pairs(data.talents or {}) do
            local hits = false
            for i = 1, #(row.affects or {}) do
                if row.affects[i]:lower() == lowered then hits = true break end
            end
            if hits then
                local merged = M.talent(name)
                if merged and (not taken_only or merged.taken) then out[#out + 1] = merged end
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end

    -- --- coverage -----------------------------------------------------------

    --- What the character knows against what the catalogue describes.
    ---@return table|nil { class, described, known, missing = string[], known_described }
    function M.coverage()
        local data = M.current()
        if not data then return nil end
        local names = P.spellbook.names()
        local missing, matched = {}, 0
        for i = 1, #names do
            if data.by_lower[names[i]:lower()] then
                matched = matched + 1
            else
                missing[#missing + 1] = names[i]
            end
        end
        return {
            class = data.label or data.class,
            described = data.count,
            known = #names,
            known_described = matched,
            missing = missing,
        }
    end

    --- One line for the Debug page.
    ---@return string
    function M.status_line()
        local c = M.coverage()
        if not c then return "Catalogue: none for this class" end
        local line = string.format("Catalogue: %s, %d described, %d/%d trained abilities covered",
            c.class, c.described, c.known_described, c.known)
        if #c.missing > 0 then
            local shown = {}
            for i = 1, math.min(#c.missing, 4) do shown[i] = c.missing[i] end
            line = line .. "; undescribed: " .. table.concat(shown, ", ")
            if #c.missing > 4 then line = line .. string.format(" (+%d)", #c.missing - 4) end
        end
        return line
    end

    --- A short human description of an ability, for readouts and logs.
    ---@param name string
    ---@return string|nil
    function M.describe(name)
        local row = M.ability(name)
        if not row then return nil end
        local parts = { table.concat(row.roles or {}, "/") }
        if row.kind then parts[#parts + 1] = row.kind end
        if type(row.range) == "table" then
            parts[#parts + 1] = string.format("%d-%dy", row.range.min or 0, row.range.max or 0)
        elseif row.range then
            parts[#parts + 1] = tostring(row.range)
        end
        if row.cooldown and row.cooldown ~= 0 then parts[#parts + 1] = tostring(row.cooldown) .. "s cd" end
        if row.duration then parts[#parts + 1] = tostring(row.duration) .. "s" end
        if row.applies and row.applies.aura then parts[#parts + 1] = "applies " .. row.applies.aura end
        return row.name .. ": " .. table.concat(parts, ", ")
    end

    function M.stats()
        local c = M.coverage()
        return {
            class = c and c.class or nil,
            described = c and c.described or 0,
            known = c and c.known or 0,
            covered = c and c.known_described or 0,
            missing = c and #c.missing or 0,
        }
    end

    return M
end

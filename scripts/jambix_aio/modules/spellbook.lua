-- Jambix AIO / spellbook -- resolve abilities by NAME, rank-aware.
--
-- WHY BY NAME AND NOT BY ID
--
-- Classic and TBC abilities have a separate spell id per rank. Heroic Strike
-- alone has ten. A rotation written against hard-coded ids therefore needs a
-- rank table for every ability, that table has to be correct for two game
-- versions, and every entry is a number somebody typed from memory. One wrong
-- digit produces an ability that silently never fires, which is close to
-- undiagnosable from inside a priority list.
--
-- So nothing here is hard-coded. The player's own spellbook is walked, each id
-- resolved to its name, and the highest known rank of each name kept. That
-- gives three things for free:
--
--   * Rank up while levelling and the rotation follows on the next refresh.
--   * An ability you have not trained yet simply does not resolve, so the
--     rotation skips it -- which is exactly the right behaviour at level 12.
--   * It works on Vanilla, TBC and a private server with custom ranks alike.
--
-- NOT LEARNED MEANS NOT HERE (1.52.1). On Forever a false from
-- is_spell_known is final: has_spell may still vouch for a spell the book
-- shows but the character has not learned, and anything that asks known()
-- would press it. Every refresh that changes the answer writes one recorder
-- trace line -- "spellbook: N known: ...", then the names only has_spell
-- vouched for and the ones left out as not learned -- so the next session
-- shows exactly what the client called learned.
--
-- LOCALISATION
-- The lookup keys are English spell names. On a non-English client nothing
-- resolves and the rotation does nothing. That is a visible, diagnosable
-- failure -- the Rotation page lists every unresolved ability -- rather than a
-- subtly wrong one, which is the trade being made here.

return function(P)
    local ctx, log = P.ctx, P.log

    local M = {}

    -- lowercase name -> { best = id, ids = { every known rank id } }
    local by_name = {}

    --- The lookup key for a name: lowercased, with a typographic apostrophe
    --- (U+2019, as some clients spell "Hunter’s Mark") folded to the plain
    --- one the class files use. One character of difference is one ability
    --- that silently never resolves.
    ---@param name string
    ---@return string
    local function key_of(name)
        return (name:lower():gsub("\226\128\153", "'"))
    end
    M.key_of = key_of

    -- ONE NAME, TWO FORMS (1.77.3). Resolving by name keeps the highest id,
    -- which is the best rank only while every id under a name is one spell
    -- line. The client's tables have two names over a cat AND a bear spell
    -- (the only collisions in any class's book, Era and Forever):
    --   Swipe   bear ranks 769..9908 (rage); 411128 the cat Swipe (energy),
    --           Era's rune and Forever's, which outranks them all
    --   Mangle  Season of Discovery's rune: 407993 cat (energy), 407995 bear
    --           (rage). Forever names 407995 Primal Bite, so nothing moves there
    -- so a bear's Swipe pressed the cat's, and a cat's Mangle the bear's; the
    -- client refuses both in the wrong form, and the rule never fired. These
    -- ids are filed under their form's name instead -- only while the client
    -- still calls them by the shared one.
    local FORM_NAMES = {
        [411128] = { shared = "swipe", name = "Swipe (Cat)" },
        [407993] = { shared = "mangle", name = "Mangle (Cat)" },
        [407995] = { shared = "mangle", name = "Mangle (Bear)" },
    }
    M.FORM_NAMES = FORM_NAMES

    -- RANKS WHOSE IDS DO NOT RISE (1.88.1). The best rank was the highest
    -- id, on the belief that a later rank always has the higher one. The
    -- client's own tables say otherwise, on Era and Forever alike: Battle
    -- Shout's rank 1 is 6673 and its ranks 2 and 3 are 5242 and 6192, so a
    -- warrior of 12 to 31 shouted rank 1; Seal of the Crusader's rank 1
    -- (21082) and Consecration's (26573) are above every later rank;
    -- Hammer of Wrath runs backwards; Devotion Aura, Mark of the Wild,
    -- Inner Fire, Sap, Swipe and Holy Fire each have one rank out of place;
    -- Distracting Shot's rank 1 (20736) is above ranks 2 to 6; and Forever
    -- added Trueshot Aura ranks at 25 and 32 (1299346, 1299348) above the
    -- 40 to 60 ones. modules/rank_order.lua (written by
    -- tools/jcheck/ranks_extract.js) gives every id of each such line its
    -- level, per client. Two ranks with levels are compared by level, then
    -- id; anything else by id, as before. Only Era and Forever have a table;
    -- every other client keeps the old order.
    local RANK_LEVEL = {}
    do
        local world = ctx.world
        local ok_c, client = false, nil
        if world and type(world.client) == "function" then ok_c, client = pcall(world.client) end
        local version = ok_c and type(client) == "table" and tostring(client.version or ""):lower() or ""
        local load = P.load or function(path) return require("jambix_aio/" .. path) end
        local ok, data = pcall(load, "modules/rank_order")
        local mine = ok and type(data) == "table" and data[version] or nil
        if type(mine) == "table" and type(mine.levels) == "table" then RANK_LEVEL = mine.levels end
    end

    --- Is rank `a` a better rank than `b` of the same spell?
    ---@param a integer
    ---@param b integer
    ---@return boolean
    local function better(a, b)
        local la, lb = RANK_LEVEL[a], RANK_LEVEL[b]
        if la and lb and la ~= lb then return la > lb end
        return a > b
    end
    M.better = better

    local resolved_count = 0
    local last_refresh = 0
    local last_line = nil       -- the last trace line written, so only a change is written

    --- Rebuilds the name map from the live spellbook.
    ---
    --- get_spells is documented as table<number, number> without saying which
    --- side is the id, and it has differed between builds. Both the key and
    --- the value are treated as candidate ids and validated by asking for a
    --- name, which costs one extra lookup per entry once per refresh and
    --- removes the guess entirely.
    function M.refresh()
        local ok, spells = pcall(core.spell_book.get_spells)
        if not ok or type(spells) ~= "table" then
            log.once("warn", "no_spellbook", "could not read the spellbook")
            return
        end

        local fresh = {}
        local seen = {}
        -- For the trace line: "Name id" of every spell only has_spell
        -- vouched for, and of every spell left out as not learned.
        local vouched, left_out = {}, {}

        ---@param id any
        ---@param position boolean an array position rather than an id: still
        --- tried, since the doc does not say which side is the id, but never
        --- reported -- positions 1..N name GM spells nobody has.
        local function consider(id, position)
            if type(id) ~= "number" or id <= 0 or seen[id] then return end
            seen[id] = true

            local ok_name, name = pcall(core.spell_book.get_spell_name, id)
            if not ok_name or type(name) ~= "string" or name == "" then return end

            -- JCore decides (spells.learned, 1.6.0): is_spell_known's yes;
            -- on Forever its no is final (the recorder has it answering every
            -- id there, never raising); elsewhere has_spell may vouch, on
            -- builds where is_spell_known is not implemented for some ids.
            local learned, how
            local spells = ctx.spells
            if spells and spells.learned then
                learned, how = spells.learned(id)
            else
                local ok_known, known = pcall(core.spell_book.is_spell_known, id)
                if ok_known and known then
                    learned, how = true, "known"
                else
                    local ok_has, has = pcall(core.spell_book.has_spell, id)
                    learned, how = ok_has and has == true, "has_spell"
                end
            end
            if not learned then
                if how == "refused" and not position then left_out[#left_out + 1] = name .. " " .. id end
                return
            end
            if how == "has_spell" then vouched[#vouched + 1] = name .. " " .. id end

            local form = FORM_NAMES[id]
            if form and key_of(name) == form.shared then name = form.name end
            local key = key_of(name)
            local row = fresh[key]
            if not row then
                row = { best = id, ids = { id }, name = name }
                fresh[key] = row
            else
                row.ids[#row.ids + 1] = id
                -- A later rank has the higher id, except on the lines
                -- RANK_LEVEL knows, where the level decides (1.88.1).
                if better(id, row.best) then row.best = id end
            end
        end

        local count = #spells
        for k, v in pairs(spells) do
            consider(k, type(k) == "number" and k >= 1 and k <= count)
            consider(v, false)
        end

        by_name = fresh
        resolved_count = 0
        for _ in pairs(by_name) do resolved_count = resolved_count + 1 end
        last_refresh = core.time()

        log.fmt("debug", "spellbook: %d distinct ability name(s)", resolved_count)
        ctx.emit("jambix.aio.spellbook_refreshed", resolved_count)

        -- What the client called learned, written when it changes.
        local names = M.names()
        table.sort(vouched)
        table.sort(left_out)
        local line = string.format("spellbook: %d known: %s", #names, table.concat(names, ", "))
        if #vouched > 0 then
            line = line .. "; known only by has_spell: " .. table.concat(vouched, ", ")
        end
        if #left_out > 0 then
            line = line .. "; not learned, left out: " .. table.concat(left_out, ", ")
        end
        if line ~= last_line then
            last_line = line
            pcall(ctx.emit, "jcore.recorder.trace", line)
        end
    end

    --- Every distinct ability name the character knows, as the client
    --- spells it, sorted. For the catalogue's coverage check.
    ---@return string[]
    function M.names()
        local out = {}
        for _, row in pairs(by_name) do out[#out + 1] = row.name end
        table.sort(out)
        return out
    end

    --- Highest known rank of `name`, or nil when it is not trained.
    ---@param name string English spell name.
    ---@return integer|nil
    function M.id(name)
        local row = by_name[key_of(name)]
        return row and row.best or nil
    end

    --- Highest known spell whose name STARTS with `prefix`.
    ---
    --- THE BUG THIS FIXES. Almost every ability in this game keeps one name
    --- across its ranks, which is why resolving by name works at all. The
    --- conjuring spells do not:
    ---
    ---     Create Healthstone (Minor)   Create Soulstone (Minor)
    ---     Create Healthstone (Lesser)  Create Soulstone (Lesser)
    ---     Create Healthstone           Create Soulstone
    ---     Create Healthstone (Greater) Create Soulstone (Greater)
    ---     Create Healthstone (Major)   Create Soulstone (Major)
    ---
    --- An exact lookup for "Create Healthstone" therefore resolves for exactly
    --- one rank out of five and answers nil for a warlock of any other level --
    --- silently, like every other resolution failure. The rule that used it
    --- has been in the plugin for several versions and would have worked
    --- between levels 42 and 53 and at no other point.
    ---
    --- The best rank is chosen as everywhere else (`better`). Era's
    --- Create Healthstone is one of the lines out of id order: plain
    --- Create Healthstone (5699, level 34) is below (Minor) and (Lesser)
    --- (6201, 6202), so until 1.88.1 a warlock of 34 to 45 made Lesser ones.
    ---@param prefix string
    ---@return integer|nil
    function M.id_prefix(prefix)
        local needle = key_of(prefix)
        local best = nil
        for key, row in pairs(by_name) do
            if key:sub(1, #needle) == needle then
                if not best or better(row.best, best) then best = row.best end
            end
        end
        return best
    end

    ---@param prefix string
    ---@return boolean
    function M.knows_prefix(prefix)
        return M.id_prefix(prefix) ~= nil
    end

    --- ready(), for a spell line whose ranks are named differently.
    ---@param prefix string
    ---@return boolean
    function M.ready_prefix(prefix)
        local id = M.id_prefix(prefix)
        if not id then return false end
        return P.ctx.spells.ready(id)
    end

    --- Every known rank id for `name`. Auras are applied by the rank that was
    --- cast, so a debuff check has to match the whole set, not just the best.
    ---@param name string
    ---@return integer[]|nil
    function M.ids(name)
        local row = by_name[key_of(name)]
        return row and row.ids or nil
    end

    ---@param name string
    ---@return boolean
    function M.known(name)
        return by_name[key_of(name)] ~= nil
    end

    -- LOCKED BY AN AURA ON YOU (1.77.1). A class module may say a spell
    -- cannot go while an aura is on the player (`locked_by`): the paladin's
    -- Forbearance, after Divine Shield, Divine Protection or Blessing of
    -- Protection. Whether the client's usable answer folds that in was never
    -- recorded, and where it does not, everything that asks ready() offered
    -- the locked spell: the defensive reaction pressed Divine Protection
    -- after a bubble every six seconds and never got to Lay on Hands below
    -- it, and the escape count kept the bubble as a way out. Read off the
    -- aura rows by id and by name, since the lockout is no spell of ours.
    ---@param name string
    ---@return boolean
    local function locked(name)
        local rotation = P.rotation
        local class_module = rotation and rotation.active_class and rotation.active_class() or nil
        local by = class_module and class_module.locked_by
        local lock = type(by) == "table" and by[name] or nil
        if type(lock) ~= "table" then return false end
        local units = P.units
        local player = units and units.player and units.player()
        if not player or not units.aura_index then return false end
        local ok, index = pcall(units.aura_index, player)
        if not ok or type(index) ~= "table" then return false end
        for _, id in ipairs(lock.ids or {}) do
            if index[id] then return true end
        end
        if lock.name then
            for _, row in pairs(index) do
                if type(row) == "table" and row.buff_name == lock.name then return true end
            end
        end
        return false
    end
    M.locked = locked

    --- Ready to press right now: trained, off cooldown, and usable. Usability
    --- is the client's own answer, so it already accounts for rage, stance and
    --- required-aura gates such as Overpower's dodge window and Revenge's
    --- block window. That is why no stance logic appears in the rotation
    --- rules themselves. A lockout the class names (`locked_by`) is added.
    ---@param name string
    ---@return boolean
    function M.ready(name)
        local id = M.id(name)
        if not id then return false end
        if not P.ctx.spells.ready(id) then return false end
        return not locked(name)
    end

    --- Ready, and in range and line of sight of `target`.
    ---@param name string
    ---@param target game_object
    ---@return boolean
    ---@param opts? { skip_range?: boolean } skip_range when the caller has
    --- checked the range itself (from the catalogue) and does not want the
    --- client's own range data consulted.
    function M.castable(name, target, opts)
        local id = M.id(name)
        if not id then return false end
        if not P.ctx.spells.ready(id) or locked(name) then return false end
        return P.ctx.spells.castable(id, target, {
            skip_facing = true,
            skip_range = opts ~= nil and opts.skip_range == true,
        })
    end

    ---@param name string
    ---@return number seconds
    function M.cooldown(name)
        local id = M.id(name)
        if not id then return math.huge end
        return P.ctx.spells.cooldown(id)
    end

    --- Names from `list` that did not resolve. The Rotation page shows this,
    --- and on a non-English client it is the whole list, which is the clue.
    ---@param list string[]
    ---@return string[]
    function M.missing(list)
        local out = {}
        for i = 1, #list do
            if not M.known(list[i]) then out[#out + 1] = list[i] end
        end
        return out
    end

    function M.stats()
        return { names = resolved_count, age = core.time() - last_refresh }
    end

    -- A new rank, a new ability from a trainer, or a talent that grants one all
    -- arrive as SPELLS_CHANGED.
    ctx.on("jambix.aio.spells_changed", function() M.refresh() end)
    ctx.every(10.0, function() M.refresh() end)
    M.refresh()

    return M
end

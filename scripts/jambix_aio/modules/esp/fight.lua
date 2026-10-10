-- Jambix AIO / esp/fight -- how a thing fights: melee, ranged, or caster.
--
-- The question that decides how a pull goes. A melee mob can be kited and
-- has to reach you; a ranged one shoots from where it stands and is pulled
-- round a corner; a caster can be interrupted, and stands still to cast.
-- The overlay used to answer only "has a mana pool" -- which cannot see an
-- archer at all, and calls every paladin-type mob a caster.
--
-- THE ANSWER IS WHAT IT DOES. JCore's enemy tracker reads every hostile's
-- casts already and announces each one ("jcore.enemy.casting"). A cast
-- whose spell is PHYSICAL and reaches past melee -- Shoot, Throw -- is a
-- ranged attack; a cast in any magic school is a spell. Every sighting is
-- counted against the creature's npc id and KEPT ACROSS SESSIONS, so the
-- first Razormane Hunter seen shooting settles it for all of them, today
-- and next week.
--
-- BEFORE IT HAS DONE ANYTHING, a guess, said to be one: the words in its
-- name ("Archer", "Rifleman" / "Geomancer", "Shadowcaster"), the class the
-- client gives it (a mage-class NPC casts), a mana pool, and its creature
-- type (a beast bites). Three degrees of sure, so the mark can say which:
--
--   "seen"    it has been seen doing it          RANGED
--   "likely"  its name or class says so          RANGED
--   "guess"   only a mana pool, or nothing       RANGED?
--
-- Players come from their spec instead: a hunter is ranged, a mage a caster,
-- an Enhancement shaman melee -- as sure as the role behind it.

return function(P)
    local ctx, cfg = P.ctx, P.cfg

    local M = {}

    -- npc id (as a string: JSON keys) -> { r = ranged casts, c = spell casts },
    -- in a store JCore saves to scripts_data, so it outlives the session.
    --
    -- CLASSIC AND FOREVER LEARN APART (1.47.0). Classic keeps
    -- jambix.aio.fight.json, exactly as before; Forever keeps its own,
    -- jambix.aio.forever_fight.json, so what a mob was seen doing on one
    -- client never decides a mark on the other. Until 1.47.0 both wrote the
    -- one file. Forever's first load takes over the creatures only Forever
    -- has (ids from FOREVER_NPC_IDS up) from it, and leaves that file as it
    -- was: it is only read here, never written.
    local FOREVER_NPC_IDS = 250000
    local store
    if P.forever then
        store = (ctx.store and ctx.store("forever_fight")) or nil
        if store and type(store.data.npcs) ~= "table" then
            store.data.npcs = {}
            local shared = ctx.store("fight")
            local old = shared and type(shared.data.npcs) == "table" and shared.data.npcs or {}
            for key, row in pairs(old) do
                if (tonumber(key) or 0) >= FOREVER_NPC_IDS and type(row) == "table" then
                    store.data.npcs[key] = { r = tonumber(row.r) or 0, c = tonumber(row.c) or 0 }
                end
            end
            store:touch()
        end
    else
        store = (ctx.store and ctx.store("fight")) or nil
        if store and type(store.data.npcs) ~= "table" then store.data.npcs = {} end
    end
    local seen = store and store.data.npcs or {}

    M.PHYSICAL = 1
    -- A physical cast that reaches no further than this is a melee special
    -- with a cast time, not a ranged attack.
    local MELEE_REACH = 8

    -- Spell facts never change for an id: one read each, for the session.
    local spell_facts = {}

    local function facts(spell_id)
        local f = spell_facts[spell_id]
        if f then return f end
        f = { school = 0, range = 0 }
        local book = type(core) == "table" and core.spell_book or nil
        if book then
            local ok, school = pcall(book.get_spell_school, spell_id)
            if ok and type(school) == "number" then f.school = school end
            local ok_r, range = pcall(book.get_spell_max_range, spell_id)
            if ok_r and type(range) == "number" then f.range = range end
        end
        spell_facts[spell_id] = f
        return f
    end

    --- What a cast says about its caster: "ranged", "caster", or nil for a
    --- melee special that happens to have a cast time.
    ---@param spell_id integer
    ---@return string|nil
    function M.kind_of_cast(spell_id)
        if type(spell_id) ~= "number" or spell_id <= 0 then return nil end
        local f = facts(spell_id)
        if f.school == 0 then return nil end
        if f.school == M.PHYSICAL then
            if f.range > 0 and f.range <= MELEE_REACH then return nil end
            return "ranged"
        end
        return "caster"
    end

    --- Counts one cast against a creature.
    ---@param npc_id integer|nil
    ---@param spell_id integer|nil
    function M.observe(npc_id, spell_id)
        if type(npc_id) ~= "number" or npc_id <= 0 then return end
        local kind = M.kind_of_cast(spell_id)
        if not kind then return end
        local key = tostring(npc_id)
        local row = seen[key]
        if not row then
            row = { r = 0, c = 0 }
            seen[key] = row
        end
        if kind == "ranged" then row.r = row.r + 1 else row.c = row.c + 1 end
        if store then store:touch() end
    end

    --- What has been seen of a creature: "ranged", "caster", or nil. The more
    --- frequent wins; a tie goes to the caster, because the thing worth
    --- knowing about it -- that it can be interrupted -- is true either way.
    function M.seen(npc_id)
        local row = type(npc_id) == "number" and seen[tostring(npc_id)] or nil
        if not row or (row.r + row.c) == 0 then return nil end
        return row.c >= row.r and "caster" or "ranged"
    end

    -- The tracker announces every cast it reads, hostile only. The npc id
    -- comes from the classifier's cache when it has the unit, which it
    -- almost always has: no native call for the answer.
    if ctx.on then
        ctx.on("jcore.enemy.casting", function(row, cast)
            if type(row) ~= "table" or type(cast) ~= "table" then return end
            local npc_id
            local classify = P.esp_classify
            local info = classify and classify.cached and classify.cached(row.guid) or nil
            if info then
                if info.is_player then return end
                npc_id = info.npc_id
            elseif row.obj then
                local ok, id = pcall(row.obj.get_npc_id, row.obj)
                if ok then npc_id = id end
            end
            M.observe(npc_id, cast.spell_id)
        end)
    end

    -- --- a guess before it has done anything --------------------------------

    local RANGED_WORDS, CASTER_WORDS = {}, {}
    for i = 1, #cfg.FIGHT_RANGED_WORDS do RANGED_WORDS[cfg.FIGHT_RANGED_WORDS[i]] = true end
    for i = 1, #cfg.FIGHT_CASTER_WORDS do CASTER_WORDS[cfg.FIGHT_CASTER_WORDS[i]] = true end

    -- name -> "ranged" | "caster" | false, for the session
    local name_memo = {}

    --- What a name says, or nil.
    function M.from_name(name)
        if type(name) ~= "string" or name == "" then return nil end
        local known = name_memo[name]
        if known ~= nil then return known or nil end
        local lower = name:lower()
        local answer = false
        for i = 1, #cfg.FIGHT_CASTER_PHRASES do
            if lower:find(cfg.FIGHT_CASTER_PHRASES[i], 1, true) then answer = "caster" end
        end
        if not answer then
            for word in lower:gmatch("[%a']+") do
                if CASTER_WORDS[word] then answer = "caster" break end
                for i = 1, #cfg.FIGHT_CASTER_SUFFIXES do
                    local suffix = cfg.FIGHT_CASTER_SUFFIXES[i]
                    if #word > #suffix and word:sub(-#suffix) == suffix then answer = "caster" break end
                end
                if answer then break end
                if RANGED_WORDS[word] then answer = "ranged" break end
            end
        end
        name_memo[name] = answer
        return answer or nil
    end

    local MAGE_CLASS = cfg.CLASS_IDS.MAGE
    local PALADIN_CLASS = cfg.CLASS_IDS.PALADIN
    local MELEE_TYPES = { [1] = true, [8] = true, [9] = true }   -- beast, critter, mechanical

    --- How a unit fights, and how sure that is.
    ---@param info table The classifier's row for the unit.
    ---@return string|nil fight "melee", "ranged" or "caster"
    ---@return string|nil sure "seen", "likely" or "guess"
    function M.role(info)
        if type(info) ~= "table" then return nil, nil end

        if info.is_player then
            local fight = info.spec and cfg.FIGHT_SPEC[info.spec] or nil
            if not fight then return nil, nil end
            return fight, info.role_certain and "likely" or "guess"
        end

        local learned = M.seen(info.npc_id)
        if learned then return learned, "seen" end

        if MELEE_TYPES[info.creature_type] then return "melee", "likely" end

        local by_name = M.from_name(info.name)
        if by_name then return by_name, "likely" end

        if info.class_id == MAGE_CLASS then return "caster", "likely" end
        if info.class_id == PALADIN_CLASS then return "melee", "likely" end
        if info.caster == true then return "caster", "guess" end
        return "melee", "guess"
    end

    function M.stats()
        local n = 0
        for _ in pairs(seen) do n = n + 1 end
        return { creatures_seen = n }
    end

    return M
end

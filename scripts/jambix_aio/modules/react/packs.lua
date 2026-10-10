-- Jambix AIO / react / packs -- starter reactions for dungeons and the open
-- world (1.78.0).
--
-- The user, 2026-10-05: "Default Reaction for Dungeon and World open". Two
-- halves: the built-in reactions set up for each place (custom.lua and
-- custom_data's DEFAULT_PLACES, a column each in the window), and these:
-- ready-made reactions of your own, a Dungeon pack and an Open world pack
-- for every class.
--
-- WHAT THEY ARE FOR. Each answers something the built-in reactions do not
-- watch: a death in the group, threat on one mob, an enraged mob, a player
-- in melee, several mobs on you before the fight is lost. The built-ins
-- keep their own triggers; these add the place's.
--
-- ONCE ADDED, a pack reaction is yours like any other: in My reactions,
-- switched on, its Where set to its place, edited, switched off or deleted
-- as you like. It keeps where it came from (source.pack), so the pack shows
-- it as added, and it is not added twice while you keep it.
--
-- ADDING. One at a time, or "Add the pack": every one with at least one
-- action you can use (an item, or a spell you know). One whose spells you
-- have not learned stays in the list with what it needs, for later.
--
-- GUI rows only, so every one runs on a loader without Lua.

-- --- building blocks -------------------------------------------------------------

local function cond(key, op, value) return { mode = "gui", key = key, op = op, value = value } end
local function spell(name, target) return { mode = "gui", kind = "spell", spell = name, target = target or "target" } end
local function item(kind) return { mode = "gui", kind = "item", item = kind } end

--- The tank is dead and a mob is on you. "Group members dead" as well: a
--- group with no roles set has no tank to read, and must not count as one
--- that lost it.
local function wipe_coming()
    return { cond("g_group", "is"), cond("g_dead", ">=", 1), cond("g_tank", "not"), cond("me_attackers", ">=", 1) }
end

--- Someone died, no healer is standing, and you are under `hp` percent.
local function healer_down(hp)
    return { cond("g_group", "is"), cond("g_dead", ">=", 1), cond("g_healer", "not"), cond("me_hp", "<", hp) }
end

local DUNGEONS = { "dungeon", "raid" }
local DUNGEON_ONLY = { "dungeon" }
local WORLD = { "world", "world_pvp" }
local WORLD_ONLY = { "world" }
local WORLD_PVP = { "world_pvp" }

-- --- the packs ---------------------------------------------------------------------
--
--   key        permanent: an added reaction remembers it
--   name       the reaction's name once added
--   what       one line for the window
--   importance custom_data's IMPORTANCE key; wait, match, combat_only as the editor's
--   places     where it acts once added (custom_data's ENV keys)

local PLACES = {
    { key = "dungeon", label = "Dungeon pack",
      sub = "In a group: a death, a healer gone, threat on one mob, an enraged mob. Most also act in raids." },
    { key = "world", label = "Open world pack",
      sub = "On your own: several mobs on you, low health, a player in melee." },
}

--- Every class gets these first.
local ANY = {
    dungeon = {
        { key = "any_no_healer_drink", name = "Healer down: drink early", importance = "survival",
          what = "Someone died and no healer is standing: a healthstone, else a healing potion, at half health instead of the last moment.",
          conds = healer_down(50), actions = { item("healthstone"), item("potion") }, places = DUNGEONS },
    },
    world = {
        { key = "any_outnumbered_drink", name = "Outnumbered: drink early", importance = "survival",
          what = "Three or more mobs on you: a healthstone, else a healing potion, at half health, before it is a race.",
          conds = { cond("me_attackers", ">=", 3), cond("me_hp", "<", 50) },
          actions = { item("healthstone"), item("potion") }, places = WORLD },
    },
}

local CLASS = {
    HUNTER = {
        dungeon = {
            { key = "hunter_wipe_fd", name = "Wipe coming: Feign Death", importance = "escape", wait = 5,
              what = "The tank is dead and a mob is on you: Feign Death before the wipe reaches you.",
              conds = wipe_coming(), actions = { spell("Feign Death", "self") }, places = DUNGEONS },
            { key = "hunter_tranq", name = "Frenzy: Tranquilizing Shot", importance = "utility", wait = 2, match = "any",
              what = "Your target goes into a Frenzy or an Enrage: Tranquilizing Shot takes it off.",
              conds = { cond("t_aura", "is", "Frenzy"), cond("t_aura", "is", "Enrage") },
              actions = { spell("Tranquilizing Shot") }, places = DUNGEONS },
        },
        world = {
            { key = "hunter_panic_fd", name = "Panic: Feign Death onto the pet", importance = "survival", wait = 10,
              what = "Under 25% with two or more mobs on you and the pet out: Feign Death leaves them to the pet.",
              conds = { cond("me_hp", "<", 25), cond("me_attackers", ">=", 2), cond("pet_exists", "is") },
              actions = { spell("Feign Death", "self") }, places = WORLD_ONLY },
            { key = "hunter_pvp_clip", name = "Player in melee: Wing Clip", importance = "cc", wait = 4,
              what = "In open world PvP, a player in melee with you and not slowed by you: Wing Clip, to get your range back.",
              conds = { cond("t_player", "is"), cond("t_distance", "<", 5), cond("t_my_aura", "not", "Wing Clip") },
              actions = { spell("Wing Clip") }, places = WORLD_PVP },
        },
    },
    WARRIOR = {
        dungeon = {
            { key = "warrior_no_healer_stand", name = "Healer down: Last Stand", importance = "defensive",
              what = "Someone died, no healer is standing and you are under 30%: Last Stand, else Shield Wall.",
              conds = healer_down(30), actions = { spell("Last Stand", "self"), spell("Shield Wall", "self") },
              places = DUNGEONS },
            { key = "warrior_demo", name = "Pack: Demoralizing Shout", importance = "utility", wait = 6,
              what = "Three or more mobs in the group's fight and your target without it: Demoralizing Shout, so they all hit softer.",
              conds = { cond("g_group", "is"), cond("f_engaged", ">=", 3), cond("t_aura", "not", "Demoralizing Shout") },
              actions = { spell("Demoralizing Shout", "self") }, places = DUNGEON_ONLY },
        },
        world = {
            { key = "warrior_swarmed_shout", name = "Swarmed and hurt: Intimidating Shout", importance = "cc", wait = 10,
              what = "Two or more in melee with you and you are under 40%: Intimidating Shout sends them running.",
              conds = { cond("me_melee", ">=", 2), cond("me_hp", "<", 40) },
              actions = { spell("Intimidating Shout") }, places = WORLD_ONLY },
            { key = "warrior_pvp_hamstring", name = "Player in melee: Hamstring", importance = "cc", wait = 3,
              what = "In open world PvP, a player in melee with you and not slowed: Hamstring.",
              conds = { cond("t_player", "is"), cond("t_distance", "<", 5), cond("t_aura", "not", "Hamstring") },
              actions = { spell("Hamstring") }, places = WORLD_PVP },
        },
    },
    ROGUE = {
        dungeon = {
            { key = "rogue_feint", name = "Threat high: Feint", importance = "threat", wait = 3,
              what = "With a tank in the group and your threat at 90% of its: Feint, before the mob turns to you. Needs the client's threat (not read on Forever).",
              conds = { cond("g_group", "is"), cond("g_tank", "is"), cond("t_threat", ">=", 90) },
              actions = { spell("Feint") }, places = DUNGEONS },
            { key = "rogue_aggro_evasion", name = "Pulled aggro: Evasion", importance = "defensive", wait = 5,
              what = "With a tank in the group, your target turned on you and you are under 70%: Evasion until the tank takes it back.",
              conds = { cond("g_group", "is"), cond("g_tank", "is"), cond("t_on_me", "is"), cond("me_hp", "<", 70) },
              actions = { spell("Evasion", "self") }, places = DUNGEONS },
            { key = "rogue_wipe_vanish", name = "Wipe coming: Vanish", importance = "escape", wait = 5,
              what = "The tank is dead and a mob is on you: Vanish before the wipe reaches you.",
              conds = wipe_coming(), actions = { spell("Vanish", "self") }, places = DUNGEONS },
        },
        world = {
            { key = "rogue_panic_vanish", name = "Panic: Vanish", importance = "survival", wait = 10,
              what = "Under 20% with two or more mobs on you: Vanish.",
              conds = { cond("me_hp", "<", 20), cond("me_attackers", ">=", 2) },
              actions = { spell("Vanish", "self") }, places = WORLD_ONLY },
            { key = "rogue_two_evasion", name = "Two on me: Evasion", importance = "defensive", wait = 5,
              what = "Two or more mobs on you and you are under 60%: Evasion.",
              conds = { cond("me_attackers", ">=", 2), cond("me_hp", "<", 60) },
              actions = { spell("Evasion", "self") }, places = WORLD },
        },
    },
    MAGE = {
        dungeon = {
            { key = "mage_aggro_barrier", name = "Mob on me: Ice Barrier", importance = "defensive", wait = 3,
              what = "In a group, a mob is on you and Ice Barrier is down: put it up while the tank takes the mob back.",
              conds = { cond("g_group", "is"), cond("me_attackers", ">=", 1), cond("me_buff", "not", "Ice Barrier") },
              actions = { spell("Ice Barrier", "self") }, places = DUNGEONS },
            { key = "mage_aggro_block", name = "Pulled aggro and hurt: Ice Block", importance = "survival", wait = 10,
              what = "With a tank in the group, a mob is on you and you are under 30%: Ice Block, and let the tank take it back.",
              conds = { cond("g_group", "is"), cond("g_tank", "is"), cond("me_attackers", ">=", 1), cond("me_hp", "<", 30) },
              actions = { spell("Ice Block", "self") }, places = DUNGEONS },
        },
        world = {
            { key = "mage_two_nova", name = "Two in melee: Frost Nova", importance = "escape", wait = 4,
              what = "Two or more in melee with you: Frost Nova roots them; with Nova on its cooldown, Blink away.",
              conds = { cond("me_melee", ">=", 2) },
              actions = { spell("Frost Nova", "self"), spell("Blink", "self") }, places = WORLD },
            { key = "mage_panic_block", name = "Panic: Ice Block", importance = "survival", wait = 10,
              what = "Under 15% with a mob on you: Ice Block.",
              conds = { cond("me_hp", "<", 15), cond("me_attackers", ">=", 1) },
              actions = { spell("Ice Block", "self") }, places = WORLD },
        },
    },
    PRIEST = {
        dungeon = {
            { key = "priest_aggro_fade", name = "Pulled aggro: Fade", importance = "threat", wait = 3,
              what = "With a tank in the group, a mob is hitting you: Fade, so it goes back to the tank.",
              conds = { cond("g_group", "is"), cond("g_tank", "is"), cond("me_attackers", ">=", 1) },
              actions = { spell("Fade", "self") }, places = DUNGEONS },
            { key = "priest_no_healer_shield", name = "Healer down: shield myself", importance = "survival", wait = 2,
              what = "Someone died, no healer is standing and you are under 50%: Power Word: Shield yourself.",
              conds = { cond("g_group", "is"), cond("g_dead", ">=", 1), cond("g_healer", "not"), cond("me_hp", "<", 50),
                        cond("me_buff", "not", "Power Word: Shield"), cond("me_buff", "not", "Weakened Soul") },
              actions = { spell("Power Word: Shield", "self") }, places = DUNGEONS },
        },
        world = {
            { key = "priest_two_scream", name = "Two in melee: Psychic Scream", importance = "cc", wait = 8,
              what = "Two or more in melee with you and you are under 50%: Psychic Scream sends them running.",
              conds = { cond("me_melee", ">=", 2), cond("me_hp", "<", 50) },
              actions = { spell("Psychic Scream", "self") }, places = WORLD_ONLY },
            { key = "priest_panic_prayer", name = "Panic: Desperate Prayer", importance = "survival", wait = 10,
              what = "Under 25% with a mob on you: Desperate Prayer (human and dwarf priests).",
              conds = { cond("me_hp", "<", 25), cond("me_attackers", ">=", 1) },
              actions = { spell("Desperate Prayer", "self") }, places = WORLD },
        },
    },
    PALADIN = {
        dungeon = {
            { key = "paladin_wipe_shield", name = "Wipe coming: Divine Shield", importance = "escape", wait = 5,
              what = "The tank is dead and a mob is on you: Divine Shield, else Divine Protection.",
              conds = wipe_coming(), actions = { spell("Divine Shield", "self"), spell("Divine Protection", "self") },
              places = DUNGEONS },
            { key = "paladin_no_healer_loh", name = "Healer down: Lay on Hands", importance = "survival", wait = 10,
              what = "Someone died, no healer is standing and you are under 20%: Lay on Hands on yourself.",
              conds = healer_down(20), actions = { spell("Lay on Hands", "self") }, places = DUNGEONS },
        },
        world = {
            { key = "paladin_panic_shield", name = "Panic: Divine Shield", importance = "survival", wait = 10,
              what = "Under 20% with a mob on you: Divine Shield, else Divine Protection.",
              conds = { cond("me_hp", "<", 20), cond("me_attackers", ">=", 1) },
              actions = { spell("Divine Shield", "self"), spell("Divine Protection", "self") }, places = WORLD },
            { key = "paladin_two_hammer", name = "Two on me: Hammer the other", importance = "cc", wait = 6,
              what = "Two or more mobs on you and you are under 50%: Hammer of Justice on one you are not fighting.",
              conds = { cond("me_attackers", ">=", 2), cond("me_hp", "<", 50) },
              actions = { spell("Hammer of Justice", "attacker") }, places = WORLD_ONLY },
        },
    },
    SHAMAN = {
        dungeon = {
            { key = "shaman_no_healer_heal", name = "Healer down: heal myself", importance = "survival", wait = 3,
              what = "Someone died, no healer is standing and you are under 40%: Lesser Healing Wave on yourself, else Healing Wave.",
              conds = healer_down(40), actions = { spell("Lesser Healing Wave", "self"), spell("Healing Wave", "self") },
              places = DUNGEONS },
            { key = "shaman_casters_grounding", name = "Casters: Grounding Totem", importance = "utility", wait = 10,
              what = "Two or more enemies casting near you: Grounding Totem takes the next spell.",
              conds = { cond("f_casters", ">=", 2) },
              actions = { spell("Grounding Totem", "self") }, places = DUNGEONS },
        },
        world = {
            { key = "shaman_two_stoneclaw", name = "Two on me: Stoneclaw Totem", importance = "defensive", wait = 10,
              what = "Two or more mobs on you: Stoneclaw Totem draws them off you for a few seconds.",
              conds = { cond("me_attackers", ">=", 2) },
              actions = { spell("Stoneclaw Totem", "self") }, places = WORLD_ONLY },
            { key = "shaman_panic_heal", name = "Panic: heal myself", importance = "survival", wait = 3,
              what = "Under 30% with a mob on you: Lesser Healing Wave on yourself, else Healing Wave.",
              conds = { cond("me_hp", "<", 30), cond("me_attackers", ">=", 1) },
              actions = { spell("Lesser Healing Wave", "self"), spell("Healing Wave", "self") }, places = WORLD },
        },
    },
    WARLOCK = {
        dungeon = {
            { key = "warlock_aggro_coil", name = "Pulled aggro: Death Coil", importance = "defensive", wait = 5,
              what = "With a tank in the group, your target turned on you and you are under 60%: Death Coil sends it running while the tank takes it back.",
              conds = { cond("g_group", "is"), cond("g_tank", "is"), cond("t_on_me", "is"), cond("me_hp", "<", 60) },
              actions = { spell("Death Coil") }, places = DUNGEONS },
        },
        world = {
            { key = "warlock_panic_coil", name = "Panic: Death Coil", importance = "survival", wait = 5,
              what = "Under 30% and your target is on you: Death Coil, for the heal and the horror.",
              conds = { cond("me_hp", "<", 30), cond("t_on_me", "is") },
              actions = { spell("Death Coil") }, places = WORLD },
            { key = "warlock_swarmed_howl", name = "Swarmed: Howl of Terror", importance = "cc", wait = 10,
              what = "Two or more in melee with you and you are under 50%: Howl of Terror.",
              conds = { cond("me_melee", ">=", 2), cond("me_hp", "<", 50) },
              actions = { spell("Howl of Terror", "self") }, places = WORLD_ONLY },
        },
    },
    DRUID = {
        dungeon = {
            { key = "druid_no_healer_heal", name = "Healer down: Regrowth myself", importance = "survival", wait = 3,
              what = "Someone died, no healer is standing and you are under 40%: Regrowth on yourself, else Healing Touch (out of an animal form).",
              conds = healer_down(40), actions = { spell("Regrowth", "self"), spell("Healing Touch", "self") },
              places = DUNGEONS },
            { key = "druid_bear_regen", name = "Tanking low: Frenzied Regeneration", importance = "defensive", wait = 5,
              what = "In a group, a mob on you and you are under 40%: Frenzied Regeneration (Bear Form) turns rage into health.",
              conds = { cond("g_group", "is"), cond("me_attackers", ">=", 1), cond("me_hp", "<", 40) },
              actions = { spell("Frenzied Regeneration", "self") }, places = DUNGEONS },
        },
        world = {
            { key = "druid_panic_regrowth", name = "Panic: Regrowth myself", importance = "survival", wait = 3,
              what = "Under 30% with a mob on you: Regrowth on yourself, else Healing Touch (out of an animal form).",
              conds = { cond("me_hp", "<", 30), cond("me_attackers", ">=", 1) },
              actions = { spell("Regrowth", "self"), spell("Healing Touch", "self") }, places = WORLD },
            { key = "druid_two_roots", name = "Two on me: root the other", importance = "cc", wait = 6,
              what = "Two or more mobs on you and you are under 60%: Entangling Roots on one you are not fighting.",
              conds = { cond("me_attackers", ">=", 2), cond("me_hp", "<", 60) },
              actions = { spell("Entangling Roots", "attacker") }, places = WORLD_ONLY },
        },
    },
}

return function(C, P, D, h)
    local log = P.log
    local book = P.spellbook

    local S = { PLACES = PLACES, ANY = ANY, CLASS = CLASS }

    local LABEL_OF = {}
    for _, p in ipairs(PLACES) do LABEL_OF[p.key] = p.label end
    S.label_of = function(key) return LABEL_OF[key] end

    local function known(name)
        return book ~= nil and book.known ~= nil and book.known(name) == true
    end

    --- Where an item acts once added: its places, nowhere else.
    local function env_of(it)
        local env = C.fresh_env()
        for _, e in ipairs(D.ENV) do env[e.key] = false end
        for _, k in ipairs(it.places or {}) do env[k] = true end
        return env
    end
    S.env_of = env_of

    --- The pack's items for a class: every class's first, then the class's own.
    local function items_of(pack, cls)
        local out = {}
        for _, it in ipairs(ANY[pack] or {}) do out[#out + 1] = it end
        for _, it in ipairs((CLASS[cls or ""] or {})[pack] or {}) do out[#out + 1] = it end
        return out
    end
    S.items_of = items_of

    --- The reaction of yours that came from this item, while you keep it.
    local function added_id(pack, key)
        for _, r in ipairs(C.list()) do
            local s = r.source
            if type(s) == "table" and s.pack == pack and s.item == key then return r.id end
        end
        return nil
    end

    --- The spells an item needs that you have not learned, and whether one
    --- of its actions can go (an item, or a spell you know).
    local function needs(it)
        local missing, usable = {}, false
        for _, a in ipairs(it.actions or {}) do
            if a.kind == "spell" then
                if known(a.spell) then usable = true else missing[#missing + 1] = a.spell end
            else
                usable = true
            end
        end
        return missing, usable
    end

    --- The packs for your class, each item with how it stands: `id` once
    --- added (yours), `missing` spells, `usable` now.
    ---@param cls? string
    ---@return table[]
    function S.list(cls)
        cls = cls or C.class()
        local out = {}
        for _, p in ipairs(PLACES) do
            local rows, added, usable = {}, 0, 0
            for _, it in ipairs(items_of(p.key, cls)) do
                local missing, ok = needs(it)
                local id = added_id(p.key, it.key)
                if id then added = added + 1 end
                if ok then usable = usable + 1 end
                rows[#rows + 1] = {
                    key = it.key, name = it.name, what = it.what, importance = it.importance,
                    where = C.env_text(env_of(it)), missing = missing, usable = ok, id = id,
                }
            end
            out[#out + 1] = { key = p.key, label = p.label, sub = p.sub, items = rows, added = added, usable = usable }
        end
        return out
    end

    local function find(pack, key, cls)
        for _, it in ipairs(items_of(pack, cls)) do
            if it.key == key then return it end
        end
        return nil
    end

    local function unique_name(name)
        local taken = {}
        for _, r in ipairs(C.list()) do taken[(r.name or ""):lower()] = true end
        if not taken[name:lower()] then return name end
        for n = 2, 99 do
            local cand = name .. " (" .. n .. ")"
            if not taken[cand:lower()] then return cand end
        end
        return name
    end

    --- An item as a reaction of yours, not saved yet.
    function S.draft(pack, key, cls)
        local it = find(pack, key, cls or C.class())
        if not it then return nil end
        local imp = D.IMPORTANCE_BY_KEY[it.importance] or D.IMPORTANCE_BY_KEY.defensive
        return {
            name = unique_name(it.name), importance = imp.key, priority = imp.priority,
            wait = it.wait or 0, combat_only = it.combat_only ~= false, off_gcd = it.off_gcd == true,
            match = it.match == "any" and "any" or "all",
            conds = h.copy(it.conds), actions = h.copy(it.actions), env = env_of(it), on = true,
            source = { pack = pack, item = key },
        }
    end

    --- Adds one item to your reactions, switched on.
    ---@return integer|nil id
    ---@return string|nil err
    function S.add(pack, key)
        local cls = C.class()
        if not cls then return nil, "Your class is not known yet: log in with a character." end
        local have = added_id(pack, key)
        if have then return nil, "already in My reactions" end
        local r = S.draft(pack, key, cls)
        if not r then return nil, "no such reaction in the " .. tostring(LABEL_OF[pack] or pack) end
        local id = C.save(r)
        if id then log.fmt("info", "reactions: added %s from the %s", r.name, LABEL_OF[pack] or pack) end
        return id
    end

    --- Adds every item of a pack you can use now and do not have yet.
    ---@return table done { added, already, waiting = { names } }
    function S.add_all(pack)
        local cls = C.class()
        local done = { added = 0, already = 0, waiting = {} }
        if not cls then return done end
        for _, it in ipairs(items_of(pack, cls)) do
            local _, ok = needs(it)
            if added_id(pack, it.key) then
                done.already = done.already + 1
            elseif not ok then
                done.waiting[#done.waiting + 1] = it.name
            elseif S.add(pack, it.key) then
                done.added = done.added + 1
            end
        end
        return done
    end

    return S
end

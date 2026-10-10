-- Jambix AIO / react / pvp -- the other player (1.81.0, Classic Era).
--
-- A mob does the same thing every time. A player does not, and almost
-- everything a player does is an answer to something: a Polymorph so a
-- bandage can tick, an Ice Block to wait out a cooldown, Recklessness the
-- moment the healer is feared, the PvP trinket the moment a stun would cost
-- the fight. This module reads those moves off the client once a tick, so
-- rules/pvp.lua can answer them:
--
--   what controls me   our debuffs by name, else the loss-of-control spell:
--                      the mechanic, how long is left, whether damage breaks
--                      it, which dispel takes it, whether a player put it on
--   each enemy player  from its auras: immune to everything (Divine Shield,
--                      Ice Block), to physical (Blessing of Protection), to a
--                      mechanic (Berserker Rage: fear; Blessing of Freedom:
--                      roots and snares; a druid's form: Polymorph); bursting
--                      (Recklessness, Arcane Power); what a purge would take
--                      off it; and when it last used its own PvP trinket
--   our trinkets       which worn trinket breaks what. The Insignia of the
--                      Alliance / Horde is five different trinkets in Era,
--                      by class, and none of them breaks everything.
--
-- THE DATA IS THE CLIENT'S. Every mechanic, dispel type and immunity below
-- was read from the Era 1.15.9 client's own tables (SpellCategories,
-- SpellEffect, ItemEffect; tools/jcheck), not remembered. Some of it is not
-- what a player would guess:
--   * no Insignia breaks Blind, Sap, Gouge, a Freezing Trap, Wyvern Sting or
--     Death Coil (disorient, knockout, freeze, sleep, horror);
--   * a Warrior's, Hunter's or Shaman's Insignia breaks no Fear and no
--     Polymorph (root, snare, stun); a Rogue's or Warlock's breaks no stun;
--   * Psychic Scream and Intimidating Shout cannot be dispelled; the
--     warlock's Fear, Polymorph, Hammer of Justice and Seduction can;
--   * Blind and Wyvern Sting are poisons;
--   * Cat, Bear and Travel Form make a druid immune to Polymorph;
--   * Recklessness, Death Wish, Evasion, Adrenaline Rush, Divine Shield and
--     Ice Block cannot be purged; Blessing of Protection, Power Infusion,
--     Arcane Power, Innervate and Blessing of Freedom can.
--
-- Nothing here decides anything. The table it fills, W.pvp, is reused
-- between ticks like the rest of W: read it, do not keep it.

return function(P, world)
    local ctx, units = P.ctx, P.units
    local book = P.spellbook

    local M = {}

    local huge, min = math.huge, math.min

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        if ok then return value end
        return nil
    end

    local function clock() return core.time() end

    local function game_ms()
        if type(core.game_time) ~= "function" then return nil end
        local ok, value = pcall(core.game_time)
        return ok and type(value) == "number" and value or nil
    end

    --- Seconds left on an aura row; huge for one that does not run out.
    local function left_on(aura, now_ms)
        local expires = type(aura) == "table" and tonumber(aura.expire_time) or nil
        if not expires or expires <= 0 or not now_ms then return huge end
        return math.max(0, (expires - now_ms) / 1000)
    end

    -- ==========================================================================
    -- WHAT CONTROLS US
    -- ==========================================================================
    --
    -- By the debuff's name: the mechanic (Era's SpellCategories.Mechanic, or
    -- the aura effect's own), the dispel type, and whether damage ends it.
    -- HELPLESS mechanics leave nothing to press but what is made for it (the
    -- trinket, Will of the Forsaken, Blink out of a stun).

    local function c(mech, dispel, breaks) return { mech = mech, dispel = dispel, breaks = breaks == true } end

    M.CONTROL = {
        -- stuns
        ["Kidney Shot"] = c("stun"), ["Cheap Shot"] = c("stun"), ["Bash"] = c("stun"), ["Pounce"] = c("stun"),
        ["Intimidation"] = c("stun"), ["Charge Stun"] = c("stun"), ["Intercept Stun"] = c("stun"),
        ["Concussion Blow"] = c("stun"), ["Mace Stun Effect"] = c("stun"), ["War Stomp"] = c("stun"),
        ["Impact"] = c("stun"), ["Starfire Stun"] = c("stun"), ["Improved Concussive Shot"] = c("stun"),
        ["Stun"] = c("stun"), ["Hammer of Justice"] = c("stun", "MAGIC"), ["Blackout"] = c("stun", "MAGIC"),
        -- fears, charms, horror
        ["Fear"] = c("fear", "MAGIC", true), ["Howl of Terror"] = c("fear", "MAGIC", true),
        ["Psychic Scream"] = c("fear", nil, true), ["Intimidating Shout"] = c("fear", nil, true),
        ["Death Coil"] = c("horror", "MAGIC"),
        ["Seduction"] = c("charm", "MAGIC", true), ["Mind Control"] = c("charm", "MAGIC"),
        -- out of the fight until something hits
        ["Polymorph"] = c("polymorph", "MAGIC", true), ["Polymorph: Pig"] = c("polymorph", "MAGIC", true),
        ["Polymorph: Turtle"] = c("polymorph", "MAGIC", true),
        ["Blind"] = c("disorient", "POISON", true), ["Scatter Shot"] = c("disorient", nil, true),
        ["Sap"] = c("knockout", nil, true), ["Gouge"] = c("knockout", nil, true),
        ["Repentance"] = c("knockout", "MAGIC", true), ["Reckless Charge"] = c("knockout", "MAGIC"),
        ["Freezing Trap Effect"] = c("freeze", "MAGIC", true),
        ["Wyvern Sting"] = c("sleep", "POISON", true), ["Hibernate"] = c("sleep", "MAGIC", true),
        -- silences and disarms
        ["Silence"] = c("silence", "MAGIC"), ["Counterspell - Silenced"] = c("silence", "MAGIC"),
        ["Kick - Silenced"] = c("silence", "MAGIC"), ["Shield Bash - Silenced"] = c("silence", "MAGIC"),
        ["Spell Lock"] = c("silence"),
        ["Disarm"] = c("disarm"), ["Riposte"] = c("disarm"),
        -- roots
        ["Frost Nova"] = c("root", "MAGIC"), ["Entangling Roots"] = c("root", "MAGIC"),
        ["Frostbite"] = c("root", "MAGIC"), ["Entrapment"] = c("root", "MAGIC"),
        ["Improved Hamstring"] = c("root"), ["Improved Wing Clip"] = c("root"), ["Feral Charge Effect"] = c("root"),
        -- snares
        ["Hamstring"] = c("snare"), ["Wing Clip"] = c("snare"), ["Concussive Shot"] = c("snare", "MAGIC"),
        ["Crippling Poison"] = c("snare", "POISON"), ["Frostbolt"] = c("snare", "MAGIC"),
        ["Cone of Cold"] = c("snare", "MAGIC"), ["Frost Shock"] = c("snare", "MAGIC"),
        ["Earthbind"] = c("snare", "MAGIC"), ["Curse of Exhaustion"] = c("snare", "CURSE"),
        ["Chilled"] = c("snare", "MAGIC"), ["Piercing Howl"] = c("snare"), ["Mind Flay"] = c("snare"),
        ["Long Daze"] = c("snare"), ["Dazed"] = c("snare"),
    }

    M.HELPLESS = {
        stun = true, fear = true, charm = true, polymorph = true, sleep = true, knockout = true,
        disorient = true, freeze = true, horror = true,
    }

    --- Every mechanic that takes control: what "breaks everything" means.
    --- Silence and disarm are not on it (a full PvP trinket does not lift them).
    M.ALL_CONTROL = {
        stun = true, fear = true, charm = true, polymorph = true, sleep = true, knockout = true,
        disorient = true, freeze = true, horror = true, root = true, snare = true,
    }

    -- The loss-of-control type, when no debuff we know names the control.
    local LOC_MECH = {
        stun = "stun", stun_mechanic = "stun", fear = "fear", fear_mechanic = "fear", charm = "charm",
        posses = "charm", confuse = "disorient", root = "root", silence = "silence",
        pacify_silence = "silence", school_interrupt = "silence", disarm = "disarm", pacify = "disarm",
    }
    local loc_names = nil
    local function loc_mech(type_id)
        if not loc_names then
            loc_names = {}
            for name, id in pairs(P.loc_types or {}) do
                if type(id) == "number" then loc_names[id] = name:lower() end
            end
        end
        return LOC_MECH[loc_names[type_id] or ""]
    end

    -- ==========================================================================
    -- THE PVP TRINKET
    -- ==========================================================================
    --
    -- Era's ItemEffect: each Insignia's on-use spell. Its SpellEffect rows are
    -- mechanic immunities, which take off whatever of those mechanics is on
    -- you. By class: Warrior, Hunter, Shaman 5579; Rogue, Warlock 23273;
    -- Mage 23274; Priest, Paladin 23276; Druid 23277. 209611-209626 are
    -- Season of Discovery's Insignias, the same five; 216938, 216939, 228093
    -- and 233728 its "PvP Trinket", made to be used under any control.

    M.INSIGNIA = {
        [18834] = 5579, [18845] = 5579, [18846] = 5579, [18849] = 23273, [18850] = 23274, [18851] = 23276,
        [18852] = 23273, [18853] = 23277, [18854] = 5579, [18856] = 5579, [18857] = 23273, [18858] = 23273,
        [18859] = 23274, [18862] = 23276, [18863] = 23277, [18864] = 23276,
        [209611] = 5579, [209612] = 23273, [209613] = 23276, [209614] = 23276, [209615] = 23273,
        [209616] = 5579, [209617] = 23277, [209618] = 23274, [209619] = 5579, [209620] = 23273,
        [209621] = 23276, [209622] = 23273, [209623] = 23274, [209624] = 23277, [209625] = 5579,
        [209626] = 5579,
        [216938] = 438273, [216939] = 438273, [228093] = 438273, [233728] = 474386,
    }

    M.BREAKS = {
        [5579] = { root = true, snare = true, stun = true },             -- Immune Root/Snare/Stun
        [23273] = { charm = true, fear = true, polymorph = true },       -- Immune Charm/Fear/Polymorph
        [23274] = { fear = true, polymorph = true, snare = true },       -- Immune Fear/Polymorph/Snare
        [23276] = { fear = true, polymorph = true, stun = true },        -- Immune Fear/Polymorph/Stun
        [23277] = { charm = true, fear = true, stun = true },            -- Immune Charm/Fear/Stun
        [28237] = { polymorph = true, fear = true, root = true },        -- Immune Poly/Fear/(Root)
        [438273] = M.ALL_CONTROL, [443630] = M.ALL_CONTROL, [474386] = M.ALL_CONTROL,  -- PvP Trinket
    }
    -- Its cooldown, for telling when an enemy's is back.
    M.TRINKET_CD = { [474386] = 120 }
    local TRINKET_CD_DEFAULT = 300

    -- The words in "Immune Fear/Polymorph/Stun": an Insignia this table does
    -- not list still says what it breaks.
    local WORD_MECH = { root = "root", snare = "snare", stun = "stun", charm = "charm", fear = "fear",
                        polymorph = "polymorph", poly = "polymorph" }

    local function breaks_from_name(name)
        if type(name) ~= "string" then return nil end
        if name == "PvP Trinket" then return M.ALL_CONTROL end
        local list = name:match("^Immune (.+)$")
        if not list then return nil end
        local out, any = {}, false
        for word in list:gmatch("[^/%s]+") do
            local mech = WORD_MECH[word:lower()]
            if mech then out[mech], any = true, true end
        end
        return any and out or nil
    end

    local TRINKET_SLOTS = { 13, 14 }
    local worn, worn_at = {}, -huge

    local function read_trinkets()
        local out = {}
        local player = units.player and units.player() or nil
        if not player then return out end
        for i = 1, #TRINKET_SLOTS do
            local slot = TRINKET_SLOTS[i]
            local ok, row = pcall(player.get_item_at_inventory_slot, player, slot)
            local object = ok and type(row) == "table" and row.object or nil
            local id = object and try(object.get_item_id, object)
            if type(id) == "number" and id > 0 then
                local name = try(object.get_name, object) or ("item " .. id)
                local spell_id = M.INSIGNIA[id]
                local spell_name = nil
                if not spell_id and core.quests and core.quests.get_item_spell then
                    local info = try(core.quests.get_item_spell, id)
                    if type(info) == "table" then spell_id, spell_name = tonumber(info.spell_id), info.spell_name end
                end
                local breaks = (spell_id and M.BREAKS[spell_id]) or breaks_from_name(spell_name)
                out[#out + 1] = {
                    slot = slot, id = id, name = name, spell_id = spell_id, breaks = breaks,
                    cd = (spell_id and M.TRINKET_CD[spell_id]) or TRINKET_CD_DEFAULT,
                }
            end
        end
        return out
    end

    --- The two worn trinkets: { slot, id, name, spell_id, breaks }, `breaks`
    --- set for a control breaker. Read every five seconds, and at once when
    --- the equipment changes.
    ---@return table[]
    function M.trinkets()
        local now = clock()
        if (now - worn_at) >= 5 then
            worn, worn_at = read_trinkets(), now
        end
        return worn
    end
    if ctx and ctx.on then
        ctx.on("jcore.game_event.PLAYER_EQUIPMENT_CHANGED", function() worn_at = -huge end)
    end

    --- Is this item a control breaker, to be kept for the control? The burst
    --- window asks before it presses a trinket (burst.lua).
    ---@param item_id integer
    ---@return boolean
    function M.keeps(item_id)
        if M.INSIGNIA[item_id] then return true end
        local list = M.trinkets()
        for i = 1, #list do
            if list[i].id == item_id and list[i].breaks then return true end
        end
        return false
    end

    --- The worn trinket that breaks this mechanic, or nil; and the worn
    --- control breaker that does not, for saying why it is kept.
    ---@param mech string
    ---@return table|nil breaker
    ---@return table|nil other
    function M.trinket_for(mech)
        local list = M.trinkets()
        local other = nil
        for i = 1, #list do
            local t = list[i]
            if t.breaks then
                if t.breaks[mech] then return t, nil end
                other = other or t
            end
        end
        return nil, other
    end

    --- "root, snare, stun": what a trinket breaks, for the readout.
    function M.breaks_text(breaks)
        local out = {}
        for _, mech in ipairs({ "stun", "fear", "charm", "polymorph", "sleep", "knockout", "disorient",
                               "freeze", "horror", "root", "snare" }) do
            if breaks and breaks[mech] then out[#out + 1] = mech end
        end
        return table.concat(out, ", ")
    end

    -- ==========================================================================
    -- WHAT EACH ENEMY PLAYER IS DOING
    -- ==========================================================================
    --
    --   immune   "all" or "physical": nothing (or nothing physical) lands
    --   mech     immune to these mechanics: a fear into Berserker Rage, a
    --            Hamstring into Blessing of Freedom, a Polymorph into Cat Form
    --   avoid    "melee" (Evasion) or "physical" (Deterrence): harder to hit
    --   burst    "physical" or "spell": what is coming at you, now
    --   purge    what taking it off is worth (Magic only: Purge, Dispel
    --            Magic, Devour Magic take it)

    local function e(t) return t end
    M.ENEMY = {
        ["Divine Shield"] = e({ immune = "all" }), ["Divine Protection"] = e({ immune = "all" }),
        ["Ice Block"] = e({ immune = "all" }),
        ["Blessing of Protection"] = e({ immune = "physical", purge = 30 }),
        ["Evasion"] = e({ avoid = "melee" }), ["Deterrence"] = e({ avoid = "physical" }),
        ["Berserker Rage"] = e({ mech = { fear = true, knockout = true } }),
        ["Death Wish"] = e({ mech = { fear = true }, burst = "physical" }),
        ["Recklessness"] = e({ mech = { fear = true }, burst = "physical" }),
        ["Will of the Forsaken"] = e({ mech = { fear = true, charm = true, sleep = true } }),
        ["Fear Ward"] = e({ mech = { fear = true }, purge = 15 }),
        ["Blessing of Freedom"] = e({ mech = { root = true, snare = true }, purge = 20 }),
        ["Free Action"] = e({ mech = { root = true, snare = true, stun = true }, purge = 20 }),
        ["Living Free Action"] = e({ mech = { root = true, snare = true, stun = true }, purge = 15 }),
        ["Cat Form"] = e({ mech = { polymorph = true } }), ["Bear Form"] = e({ mech = { polymorph = true } }),
        ["Dire Bear Form"] = e({ mech = { polymorph = true } }), ["Travel Form"] = e({ mech = { polymorph = true } }),
        -- what is coming at you
        ["Adrenaline Rush"] = e({ burst = "physical" }), ["Blade Flurry"] = e({ burst = "physical" }),
        ["Cold Blood"] = e({ burst = "physical" }), ["Rapid Fire"] = e({ burst = "physical", purge = 15 }),
        ["Arcane Power"] = e({ burst = "spell", purge = 25 }), ["Combustion"] = e({ burst = "spell", purge = 20 }),
        ["Power Infusion"] = e({ burst = "spell", purge = 30 }), ["Presence of Mind"] = e({ burst = "spell", purge = 20 }),
        ["Elemental Mastery"] = e({ burst = "spell", purge = 20 }),
        -- what a purge is worth
        ["Nature's Swiftness"] = e({ purge = 25 }), ["Innervate"] = e({ purge = 25 }),
        ["Divine Favor"] = e({ purge = 15 }), ["Inner Focus"] = e({ purge = 10 }),
        ["Power Word: Shield"] = e({ purge = 20 }), ["Ice Barrier"] = e({ purge = 20 }),
        ["Sacrifice"] = e({ purge = 15 }), ["Barkskin"] = e({ purge = 12 }), ["Mana Shield"] = e({ purge = 8 }),
        ["Blessing of Sacrifice"] = e({ purge = 8 }), ["Renew"] = e({ purge = 8 }),
        ["Rejuvenation"] = e({ purge = 8 }), ["Regrowth"] = e({ purge = 8 }),
    }

    -- The buff an enemy's own Insignia leaves on it for a moment: it has
    -- just used its trinket (Era's on-use spell ids, as M.BREAKS). By name
    -- only for the Insignias' slashed names: a Spider Belt's "Immune Root"
    -- is no trinket.
    local function trinket_buff(aura)
        local id = type(aura) == "table" and aura.buff_id or nil
        if id and M.BREAKS[id] then return id end
        local name = type(aura) == "table" and aura.buff_name or nil
        if type(name) == "string" and (name == "PvP Trinket" or name:find("^Immune [^/]+/")) then return -1 end
        return nil
    end

    -- Our crowd control by mechanic: a spell into its immunity is wasted.
    M.SPELL_MECH = {
        ["Polymorph"] = "polymorph", ["Polymorph: Pig"] = "polymorph", ["Polymorph: Turtle"] = "polymorph",
        ["Fear"] = "fear", ["Howl of Terror"] = "fear", ["Psychic Scream"] = "fear",
        ["Intimidating Shout"] = "fear", ["Seduction"] = "charm", ["Mind Control"] = "charm",
        ["Death Coil"] = "horror", ["Blind"] = "disorient", ["Scatter Shot"] = "disorient",
        ["Sap"] = "knockout", ["Gouge"] = "knockout", ["Repentance"] = "knockout",
        ["Kidney Shot"] = "stun", ["Cheap Shot"] = "stun", ["Bash"] = "stun", ["Pounce"] = "stun",
        ["Hammer of Justice"] = "stun", ["Concussion Blow"] = "stun", ["War Stomp"] = "stun",
        ["Wyvern Sting"] = "sleep", ["Hibernate"] = "sleep",
        ["Frost Nova"] = "root", ["Entangling Roots"] = "root",
        ["Hamstring"] = "snare", ["Wing Clip"] = "snare", ["Concussive Shot"] = "snare",
        ["Piercing Howl"] = "snare", ["Curse of Exhaustion"] = "snare",
    }

    local states = {}              -- guid -> the state, rebuilt once a tick
    local trinket_seen = {}        -- guid -> { at, cd, name }
    local state_sweep_at = -huge
    -- M.foe's (below), swept with the states.
    local HEALER_KEEP = 20         -- seconds a heal makes a healer
    local healer_at = {}           -- guid -> when it was last seen casting a heal
    local foes = {}                -- guid -> the read, rebuilt once a tick

    local function new_state()
        return { mech = {}, purge = {}, at = -huge }
    end

    --- One enemy player as the rules want it, read once a tick.
    ---@param unit game_object
    ---@param guid string|nil
    ---@return table|nil
    function M.state(unit, guid)
        guid = guid or (unit and units.guid(unit))
        if not unit or not guid then return nil end
        local now = clock()
        local st = states[guid]
        if st and st.at == now then return st end
        st = st or new_state()
        states[guid] = st
        st.at, st.guid = now, guid
        st.immune, st.immune_name, st.immune_left = nil, nil, 0
        st.avoid, st.avoid_name = nil, nil
        st.burst, st.burst_name, st.burst_left = nil, nil, 0
        for k in pairs(st.mech) do st.mech[k] = nil end
        for i = #st.purge, 1, -1 do st.purge[i] = nil end
        st.purge_best, st.purge_total = nil, 0

        local now_ms = game_ms()
        local index = units.aura_index and try(units.aura_index, unit) or nil
        if type(index) == "table" then
            for _, aura in pairs(index) do
                local name = type(aura) == "table" and aura.buff_name or nil
                local row = name and M.ENEMY[name]
                if row then
                    local left = left_on(aura, now_ms)
                    if row.immune == "all" or (row.immune == "physical" and st.immune ~= "all") then
                        st.immune, st.immune_name, st.immune_left = row.immune, name, left
                    end
                    if row.avoid then st.avoid, st.avoid_name = row.avoid, name end
                    if row.mech then
                        for mech in pairs(row.mech) do st.mech[mech] = name end
                    end
                    if row.burst and (not st.burst or left > st.burst_left) then
                        st.burst, st.burst_name, st.burst_left = row.burst, name, left
                    end
                    if row.purge then
                        st.purge[#st.purge + 1] = { name = name, value = row.purge }
                        st.purge_total = st.purge_total + row.purge
                        if not st.purge_best or row.purge > st.purge_best.value then
                            st.purge_best = st.purge[#st.purge]
                        end
                    end
                end
                local tid = trinket_buff(aura)
                if tid then
                    -- Its trinket's immunity holds for a moment: so does ours.
                    local set = M.BREAKS[tid] or breaks_from_name(name) or {}
                    for mech in pairs(set) do st.mech[mech] = st.mech[mech] or name end
                    local seen = trinket_seen[guid]
                    if not seen or (now - seen.at) > 30 then
                        trinket_seen[guid] = { at = now, cd = M.TRINKET_CD[tid] or TRINKET_CD_DEFAULT, name = name }
                    end
                end
            end
        end
        local seen = trinket_seen[guid]
        st.trinket_down = seen ~= nil and (now - seen.at) < seen.cd
        st.trinket_back = st.trinket_down and (seen.cd - (now - seen.at)) or 0

        -- Forgotten once nobody has looked for half a minute.
        if (now - state_sweep_at) > 10 then
            state_sweep_at = now
            for g, s in pairs(states) do
                if (now - s.at) > 30 then states[g] = nil end
            end
            for g, s in pairs(trinket_seen) do
                if (now - s.at) > s.cd then trinket_seen[g] = nil end
            end
            for g, f in pairs(foes) do
                if (now - f.at) > 30 then foes[g] = nil end
            end
            for g, at in pairs(healer_at) do
                if (now - at) > HEALER_KEEP then healer_at[g] = nil end
            end
        end
        return st
    end

    local function is_player(unit, guid)
        if not unit then return false end
        local f = world and world.facts and world.facts(unit, guid or units.guid(unit)) or nil
        if f then return f.player == true end
        return try(unit.is_player, unit) == true
    end
    M.is_player = is_player

    -- ==========================================================================
    -- WHO EACH ENEMY PLAYER IS (1.7.6)
    -- ==========================================================================
    --
    -- The PvP hunter (ALPHA/TEST) answers a warrior on it differently from a
    -- priest healing at thirty yards, so it has to know which it is facing:
    --
    --   class    the client's class id (1 warrior ... 11 druid)
    --   form     a druid's: cat, bear, travel, moonkin, aquatic
    --   role     melee (warriors, rogues, paladins, a druid in Cat or Bear),
    --            ranged (hunters), caster (the rest); "healer" once it has
    --            been seen casting a heal in the last 20 s, whatever its
    --            class -- Era's role guess is only the class
    --   mana     a mana bar a Viper Sting can drain (not a warrior or a
    --            rogue; a druid in Cat or Bear only once it shifts back)
    --   stealth  it can stealth: a rogue, a druid (Prowl)
    --
    -- Read once a tick per player, like the state above.

    local CLASS_BY_ID = {
        [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
        [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID",
    }
    M.CLASS_BY_ID = CLASS_BY_ID
    local FORMS = {
        ["Cat Form"] = "cat", ["Bear Form"] = "bear", ["Dire Bear Form"] = "bear",
        ["Travel Form"] = "travel", ["Moonkin Form"] = "moonkin", ["Aquatic Form"] = "aquatic",
    }
    local MELEE_CLASS = { WARRIOR = true, ROGUE = true, PALADIN = true }
    local NO_MANA = { WARRIOR = true, ROGUE = true }
    local STEALTH_CLASS = { ROGUE = true, DRUID = true }

    -- Classic's heals by name (as pvpmarks.lua): detect.lua's "heal" kind
    -- is read from the name, and "Holy Light" has no "heal" in it.
    local HEALS = {
        ["Heal"] = true, ["Greater Heal"] = true, ["Flash Heal"] = true, ["Lesser Heal"] = true,
        ["Renew"] = true, ["Prayer of Healing"] = true, ["Holy Light"] = true, ["Flash of Light"] = true,
        ["Healing Wave"] = true, ["Lesser Healing Wave"] = true, ["Chain Heal"] = true,
        ["Healing Touch"] = true, ["Regrowth"] = true, ["Rejuvenation"] = true, ["Tranquility"] = true,
    }

    --- Seen casting a heal: a healer for the next twenty seconds. Called by
    --- M.read for every enemy player's cast.
    local function saw_cast(guid, cast)
        if not guid or not cast then return end
        local name = cast.name or ""
        if HEALS[name] or (cast.kind == "heal" and not name:lower():find("health", 1, true)
            and name ~= "Mend Pet") then
            healer_at[guid] = clock()
        end
    end

    --- One enemy player as the PvP hunter wants it: { class, form, role,
    --- melee, caster, healer, mana, stealth }, or nil for a unit that is not
    --- a player.
    ---@param unit game_object
    ---@param guid string|nil
    ---@return table|nil
    function M.foe(unit, guid)
        guid = guid or (unit and units.guid(unit))
        if not unit or not guid or not is_player(unit, guid) then return nil end
        local now = clock()
        local f = foes[guid]
        if f and f.at == now then return f end
        f = f or {}
        foes[guid] = f
        f.at, f.guid = now, guid
        if not f.class then
            local id = tonumber(try(unit.get_class, unit))
            f.class = id and CLASS_BY_ID[id] or nil
        end
        f.form = nil
        local index = units.aura_index and try(units.aura_index, unit) or nil
        if type(index) == "table" then
            for _, aura in pairs(index) do
                local form = type(aura) == "table" and FORMS[aura.buff_name or ""] or nil
                if form then f.form = form break end
            end
        end
        local cls = f.class
        local seen = healer_at[guid]
        f.healer = seen ~= nil and (now - seen) <= HEALER_KEEP
        if cls == "DRUID" then
            f.melee = f.form == "cat" or f.form == "bear"
        else
            f.melee = MELEE_CLASS[cls or ""] == true
        end
        -- A paladin seen healing stands back to do it.
        if f.healer and cls == "PALADIN" then f.melee = false end
        f.ranged = cls == "HUNTER"
        f.caster = cls ~= nil and not f.melee and not f.ranged
        f.role = (f.healer and "healer") or (f.melee and "melee") or (f.ranged and "ranged")
            or (f.caster and "caster") or "unknown"
        f.mana = cls ~= nil and not NO_MANA[cls] and not (cls == "DRUID" and f.melee)
        f.stealth = STEALTH_CLASS[cls or ""] == true
        return f
    end

    --- "Rogue (melee)", for the readout.
    function M.foe_text(f)
        if not f then return "a player" end
        local cls = f.class and (f.class:sub(1, 1) .. f.class:sub(2):lower()) or "Player"
        local form = f.form and (", " .. f.form) or ""
        return string.format("%s (%s%s)", cls, f.role or "?", form)
    end

    --- Immune to everything right now (Divine Shield, Ice Block): never a
    --- target to pick or to press into. init.lua's out_of_fight asks it.
    ---@param unit game_object|nil
    ---@return boolean
    function M.immune_all(unit)
        if not unit or not is_player(unit) then return false end
        local st = M.state(unit)
        return st ~= nil and st.immune == "all"
    end

    -- --- is a spell of ours physical? ----------------------------------------
    -- The client's school (JCore's spells.info), else the attacks every
    -- weapon class has.
    local PHYSICAL = { ["Auto Shot"] = true, ["Attack"] = true }
    local school_cache = {}
    local function physical(name)
        local hit = school_cache[name]
        if hit ~= nil then return hit end
        local yes = PHYSICAL[name] == true
        local id = book and book.id and book.id(name) or nil
        local spells = ctx and ctx.spells
        if id and spells and spells.info then
            local info = try(spells.info, id)
            local school = type(info) == "table" and tonumber(info.school) or 0
            if school and school > 0 then
                local flags = P.enums and P.enums.spell_schools_flags
                local phys = flags and tonumber(flags.Physical) or 1
                yes = school == phys
                -- Kept only once the client has said: a spell learned later
                -- is asked again.
                school_cache[name] = yes
            end
        end
        return yes
    end

    -- Classes that have nothing but physical attacks: Blessing of Protection
    -- leaves them nothing to press.
    local PHYSICAL_ONLY = { WARRIOR = true, ROGUE = true }
    M.PHYSICAL_ONLY = PHYSICAL_ONLY

    --- Nothing of ours lands on this player right now: Divine Shield or Ice
    --- Block, or Blessing of Protection for a warrior or a rogue. The auto-
    --- target, the pet and the swing leave it alone (init.lua's out_of_fight).
    ---@param unit game_object|nil
    ---@return boolean
    function M.immune_to_us(unit)
        if not unit or not is_player(unit) then return false end
        local st = M.state(unit)
        if not st or not st.immune then return false end
        if st.immune == "all" then return true end
        local rot = P.rotation
        local cls = rot and rot.active_class and try(rot.active_class) or nil
        return PHYSICAL_ONLY[cls and cls.class_name or ""] == true
    end

    --- Why this spell of ours will not work on this enemy player now, or nil.
    --- The rotation's usable check and the reactions ask it.
    ---@param name string
    ---@param unit game_object|nil
    ---@return string|nil
    function M.blocks(name, unit)
        if type(name) ~= "string" or not unit or not is_player(unit) then return nil end
        local st = M.state(unit)
        if not st then return nil end
        if st.immune == "all" then
            return string.format("%s: immune to everything for %.0fs", st.immune_name, min(st.immune_left, 99))
        end
        if st.immune == "physical" and physical(name) then
            return string.format("%s: immune to physical attacks", st.immune_name)
        end
        local mech = M.SPELL_MECH[name]
        if mech and st.mech[mech] then
            return string.format("%s: immune to %s", st.mech[mech], mech)
        end
        return nil
    end

    -- ==========================================================================
    -- THE PICTURE, ONCE A TICK
    -- ==========================================================================

    local FLAGS = { ["Warsong Flag"] = true, ["Silverwing Flag"] = true }
    local HUNT = 40               -- yards: an enemy player this close is in the fight
    local VANISH_NEAR = 15        -- yards: one that disappears this close went into stealth
    local VANISH_KEEP = 3.0       -- seconds a vanish is news

    local V = { control = nil, root = nil, snare = nil, cast_at_me = nil, burster = nil, target = nil }
    M.V = V
    local last_players = {}       -- guid -> { at, x, y, z, dist, hp, on_me, name }
    local vanished = nil

    local function caster_player(aura)
        local caster = type(aura) == "table" and aura.caster or nil
        if not caster then return nil end
        local ok, yes = pcall(caster.is_player, caster)
        if ok then return yes == true end
        return nil
    end

    local function better(old, new)
        if not old then return true end
        return (new.remaining or 0) > (old.remaining or 0)
    end

    --- What controls us now: the worst helpless one (or a silence or a
    --- disarm), the longest root and the longest snare, each
    --- { name, mech, remaining, dispel, breaks, helpless, from_player }.
    local function read_control(W)
        local pl = W.player
        local control, root, snare = nil, nil, nil
        local now_ms = game_ms()
        local index = pl.unit and units.aura_index and try(units.aura_index, pl.unit) or nil
        if type(index) == "table" then
            for _, aura in pairs(index) do
                local name = type(aura) == "table" and aura.buff_name or nil
                local row = name and M.CONTROL[name]
                if row then
                    local entry = {
                        name = name, mech = row.mech, dispel = row.dispel, breaks = row.breaks,
                        remaining = left_on(aura, now_ms), helpless = M.HELPLESS[row.mech] == true,
                        from_player = caster_player(aura), id = aura.buff_id,
                    }
                    if row.mech == "root" then
                        if better(root, entry) then root = entry end
                    elseif row.mech == "snare" then
                        if better(snare, entry) then snare = entry end
                    elseif not control or (entry.helpless and not control.helpless)
                        or (entry.helpless == control.helpless and better(control, entry)) then
                        control = entry
                    end
                end
            end
        end
        -- The client's own word for a control no debuff of ours names.
        if not control and pl.control then
            local name = (ctx and ctx.spells and ctx.spells.name and try(ctx.spells.name, pl.control.spell_id)) or ""
            local row = M.CONTROL[name]
            local mech = row and row.mech or loc_mech(pl.control.type)
            if mech and mech ~= "root" and mech ~= "snare" then
                control = {
                    name = name ~= "" and name or mech, mech = mech, dispel = row and row.dispel or nil,
                    breaks = row and row.breaks or false, remaining = pl.control.remaining or 0,
                    helpless = M.HELPLESS[mech] == true, from_player = nil, id = pl.control.spell_id,
                }
            elseif mech == "root" and not root then
                root = { name = name ~= "" and name or "root", mech = "root", remaining = pl.control.remaining or 0,
                         helpless = false, dispel = row and row.dispel or nil }
            end
        end
        return control, root, snare
    end

    --- Fills W.pvp. Called by init.lua right after the world is built.
    ---@param W table
    ---@return table V
    function M.read(W)
        local now = W.now
        local pl = W.player
        V.players, V.attackers, V.melee_attackers = 0, 0, 0
        V.cast_at_me, V.burster = nil, nil

        local seen = {}
        local rows, n = W.enemies.list or {}, W.enemies.count or 0
        for i = 1, n do
            local r = rows[i]
            if r and r.obj and r.guid and not r.dead and (r.dist or huge) <= HUNT and is_player(r.obj, r.guid) then
                V.players = V.players + 1
                seen[r.guid] = true
                local st = M.state(r.obj, r.guid)
                if r.targeting_me then
                    V.attackers = V.attackers + 1
                    if (r.dist or huge) <= 8 then V.melee_attackers = V.melee_attackers + 1 end
                    if st and st.burst and (not V.burster or (r.dist or huge) < V.burster.dist) then
                        V.burster = { unit = r.obj, guid = r.guid, dist = r.dist or huge, st = st, row = r }
                    end
                end
                local was = last_players[r.guid] or {}
                was.at, was.dist = now, r.dist
                -- Where it stood, for a Flare on the spot once it is gone.
                was.pos = units.position and try(units.position, r.obj) or was.pos
                was.hp, was.on_me = r.hp, r.targeting_me == true
                was.engaged = r.engaged == true or r.targeting_me == true
                last_players[r.guid] = was
            end
        end
        -- One that was right here, alive and on us, and is gone without
        -- dying: Vanish, Stealth, Shadowmeld, Feign Death.
        for guid, was in pairs(last_players) do
            if not seen[guid] then
                local gone_for = now - was.at
                if gone_for <= 0.6 and was.engaged and (was.dist or huge) <= VANISH_NEAR
                    and (was.hp or 1) > 0 and not (vanished and vanished.guid == guid) then
                    local u = units.by_guid and units.by_guid(guid) or nil
                    local dead = u and try(u.is_dead, u) == true
                    if not dead then
                        vanished = { guid = guid, at = now, pos = was.pos, dist = was.dist }
                    end
                end
                if gone_for > 10 then last_players[guid] = nil end
            end
        end
        V.vanished = (vanished and (now - vanished.at) <= VANISH_KEEP) and vanished or nil

        -- A player casting something that matters at us. Every player's
        -- heal makes it a healer for a while (M.foe, 1.7.6).
        for i = 1, W.enemies.casting_n or 0 do
            local cast = W.enemies.casting[i]
            if cast.player then saw_cast(cast.guid, cast) end
            if cast.player and cast.at_me and (cast.danger or 0) > 0
                and (not V.cast_at_me or cast.remaining < V.cast_at_me.remaining) then
                V.cast_at_me = cast
            end
        end
        local tg = W.target
        if tg.player and tg.casting then saw_cast(tg.guid, tg.cast) end
        if tg.player and tg.casting and tg.targets_me and (tg.cast.danger or 0) > 0 then
            V.cast_at_me = tg.cast
        end

        V.control, V.root, V.snare = read_control(W)
        V.flag = false
        for name in pairs(pl.aura_names or {}) do
            if FLAGS[name] then V.flag = true break end
        end
        V.target = tg.player and tg.unit and M.state(tg.unit, tg.guid) or nil

        local from_player = (V.control and V.control.from_player) or (V.root and V.root.from_player)
            or (V.snare and V.snare.from_player)
        V.active = W.env.pvp == true or V.attackers > 0 or from_player == true
        return V
    end

    --- Forgets the vanish and the players seen, between fights.
    function M.reset()
        vanished = nil
        last_players = {}
    end

    return M
end

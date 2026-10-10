-- Jambix AIO / tame -- which beasts a hunter can tame, and what they teach.
--
-- WHAT THE CLIENT KNOWS (1.72.0)
--   tameable   its creature cache holds the server's type flags for every
--              creature it has described: bit 0 is TAMEABLE. JCore reads it
--              (ctx.creatures.beast, JCore 1.8.6), on Era as on Forever. The
--              client writes that file when it exits, so a beast first met
--              this session is known from the next one on.
--   family     the same record: cat, wolf, boar...
--   the skills a family can learn, and the level of every rank: the spell
--              tables (modules/beasts_data.lua). A beast of level L carries
--              the highest rank learned at L or below: a level 30 cat's Claw
--              is Claw 4.
-- WHAT IT DOES NOT: which of its family's skills one beast carries. Not every
-- cat has Prowl. The server knows; the client is never told. So a skill is
-- shown with "?" until this beast's kind (its npc id) has been SEEN using it
-- on you or your pet. The combat log names the skill (Era; on Classic it
-- carries no spell id, so the rank stays the level's), and what was seen is
-- kept between sessions (ctx.store("tame")).
--
-- NEW: higher than the rank your pet has of it now, or one your pet does not
-- have. What you learned through Beast Training but never taught this pet is
-- not readable: that window has no API here.
--
-- WHAT PETOPIA KNOWS (1.7.6). The user, 2026-10-09: "I'd like an ESP on
-- beasts as a Hunter class that shows me the image and name of the ability
-- and rank it is", with Petopia as the reference. Its pet ability pages list,
-- for every rank, the beasts known to teach it (modules/petopia_data.lua,
-- tools/jcheck/petopia_extract.js; /forever/ on Forever, /classic/ on Era).
-- So a skill now comes three ways:
--   petopia   Petopia lists this kind (npc id) for it: that rank, for sure
--   seen      this kind was seen using it (above): for sure, at its level's rank
--   guess     one of its family's skills nobody can vouch for, at its level's
--             rank, with "?": a rank Petopia knows no teacher for (all of
--             Forever's own skills so far: Dismember, Savage Rend, Web...), a
--             skill or rank it does not have at all, or any skill of a beast
--             Petopia never covers (Forever's and Season of Discovery's own
--             creatures: Petopia lists Classic npcs only, every id under
--             20000). A Classic beast Petopia does not list for a rank whose
--             teachers it knows does not teach it: no guess.
-- Without Petopia's file every family skill is a guess, as before.
-- Every skill carries the game's own icon: the client's (beasts_data's
-- `icon`, SpellMisc.SpellIconFileDataID; the art pack's "pet.<icon>" cell),
-- and the rank's spell id (its icon from the web, should a cell be missing).
-- Not Petopia's icon names: the user, 2026-10-10, "The Games own Skill Icon
-- like Bite should be Bites Icons". Petopia gives Bite the druid's Ferocious
-- Bite and Forever's Demoralizing Screech the bat's; the client does not.
--
-- Hunters only; nothing is read for anyone else.

return function(P)
    local ctx, units = P.ctx, P.units
    local floor, min = math.floor, math.min

    local M = {}

    local HUNTER = 3                  -- the client's class id
    local BEAST = 1                   -- the client's creature type
    local CACHE_FOR = 2.0             -- seconds a unit's answer is kept
    local MAX_SKILLS = 4              -- on one line
    -- Petopia lists Classic creatures only (every id under 20000 on
    -- 2026-10-09). Season of Discovery's start at 200000 and Forever's
    -- above 250000: a kind past this is one Petopia never looked at.
    local PETOPIA_NPC_MAX = 100000

    local function load_file(path)
        local load = P.load or function(p) return require("jambix_aio/" .. p) end
        local ok, d = pcall(load, path)
        if not ok or type(d) ~= "table" then return nil end
        return (P.forever and d.forever) or d.vanilla
    end

    local function data()
        local pets = P.pet
        local b = pets and pets.beasts and pets.beasts() or nil
        if b then return b end
        return load_file("modules/beasts_data")
    end

    -- Petopia's lists for this client, read once. P.petopia stands in for
    -- the file when set (false: none).
    local petopia_d = nil
    local function petopia()
        if petopia_d == nil then
            if P.petopia ~= nil then
                petopia_d = P.petopia
            else
                petopia_d = load_file("modules/petopia_data") or false
            end
        end
        return petopia_d or nil
    end

    -- --- is this a hunter? ------------------------------------------------------

    local hunter_at, is_hunter = -math.huge, false
    local function hunter(now)
        now = now or core.time()
        if (now - hunter_at) < 5 then return is_hunter end
        hunter_at = now
        local player = units.player and units.player() or nil
        local ok, id = false, nil
        if player then ok, id = pcall(player.get_class, player) end
        is_hunter = ok and id == HUNTER
        return is_hunter
    end
    M.hunter = hunter

    -- --- what was seen ------------------------------------------------------------

    local store = nil
    local seen = {}                   -- npc id (string) -> { [skill] = true }
    do
        local ok, s = pcall(function() return ctx.store and ctx.store("tame") end)
        if ok and s then
            store = s
            local ok_all, all = pcall(s.get, s, "seen", nil)
            if ok_all and type(all) == "table" then seen = all end
        end
    end

    local function npc_of_guid(guid)
        if type(guid) ~= "string" then return nil end
        local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
        if kind == "Creature" then return id end
        return nil
    end

    --- A beast was seen using a skill (the combat log names it). Kept per
    --- npc id, between sessions.
    ---@param npc string|integer
    ---@param skill string
    function M.saw(npc, skill)
        local key = tostring(npc)
        local row = seen[key]
        if row and row[skill] then return end
        if not row then
            row = {}
            seen[key] = row
        end
        row[skill] = true
        if store then
            pcall(store.set, store, "seen", seen)
        end
    end

    --- The skills a beast of this kind was seen using.
    function M.seen(npc) return seen[tostring(npc)] end

    -- Every family skill name, for the combat-log filter.
    local family_skill = nil
    local function is_family_skill(name)
        if not family_skill then
            family_skill = {}
            local d = data()
            if d then
                for _, fam in pairs(d.families or {}) do
                    if fam.hunter then
                        for i = 1, #fam.own do family_skill[fam.own[i]] = true end
                    end
                end
            end
            family_skill.Cower = true
        end
        return family_skill[name] == true
    end

    if ctx and ctx.on then
        ctx.on("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", function(a)
            if type(a) ~= "table" then return end
            local sub = a[2]
            if sub ~= "SPELL_CAST_SUCCESS" and sub ~= "SPELL_DAMAGE" and sub ~= "SPELL_AURA_APPLIED" then return end
            local name = a[13]
            if type(name) ~= "string" or not is_family_skill(name) then return end
            local npc = npc_of_guid(a[4])
            if not npc or not hunter() then return end
            M.saw(npc, name)
        end)
    end

    -- --- the answer for one unit ----------------------------------------------------

    --- The rank a beast of this level carries: the highest learned at or
    --- under it. nil when even the first is above it.
    local function rank_at(skill, level)
        local best, best_level = nil, nil
        for i = 1, #skill.ranks do
            local lv = skill.ranks[i][2] or 0
            if lv <= level then best, best_level = i, lv end
        end
        return best, best_level
    end

    --- The rank of a skill the current pet has, or 0.
    local function pet_rank(name, skill)
        local pets = P.pet
        local id = pets and pets.spell_id and pets.spell_id(name) or nil
        if not id then return 0 end
        for i = 1, #skill.ranks do
            if skill.ranks[i][1] == id then return i end
        end
        return 0
    end

    local cache = {}                  -- guid -> { at, answer }
    local cache_n = 0

    --- May this rank be shown as a guess? Not when Petopia knows who teaches
    --- it and this kind is one it would have listed (WHAT PETOPIA KNOWS).
    local function unvouched(pd, name, rank, npc)
        if not pd or npc > PETOPIA_NPC_MAX then return true end
        local skill = pd.skills and pd.skills[name]
        local r = skill and skill.ranks and skill.ranks[rank]
        return r == nil or r.from == "unknown"
    end

    -- Family id by name, for a beast Petopia lists that the creature cache
    -- has not described yet.
    local family_named = nil
    local function family_by_name(d, name)
        if not family_named then
            family_named = {}
            for id, fam in pairs(d.families or {}) do
                if fam.hunter then family_named[fam.name] = id end
            end
        end
        return family_named[name]
    end

    local HOW_ORDER = { petopia = 1, seen = 2, guess = 3 }

    local function describe(family, fam, level, npc, mine, listed)
        local d, pd = data(), petopia()
        local name_of_family = (fam and fam.name) or (listed and listed.family) or "Beast"
        local out = { family = family, family_name = name_of_family, level = level, skills = {}, listed = listed ~= nil }
        out.can_now = mine <= 0 or level <= mine
        local saw = seen[tostring(npc)]
        local have = {}

        local function add(name, rank, how)
            if have[name] or not rank then return end
            have[name] = true
            local skill = d.skills and d.skills[name]
            local s = {
                name = name, rank = rank, how = how, sure = how ~= "guess",
                seen = saw ~= nil and saw[name] == true,
                icon = skill and skill.icon or nil,
                spell = skill and skill.ranks[rank] and skill.ranks[rank][1] or nil,
            }
            if skill then s.new = rank > pet_rank(name, skill) else s.new = false end
            out.skills[#out.skills + 1] = s
        end

        -- What Petopia lists this kind for: that rank.
        if listed and listed.teaches then
            for name, rank in pairs(listed.teaches) do add(name, rank, "petopia") end
        end
        -- What this kind was seen using: the rank its level carries.
        if saw then
            for name in pairs(saw) do
                local skill = d.skills and d.skills[name]
                if skill then add(name, rank_at(skill, level), "seen") end
            end
        end
        -- Its family's other skills, where nobody can vouch either way.
        if fam then
            for i = 1, #fam.own do
                local name = fam.own[i]
                local skill = d.skills and d.skills[name]
                if not have[name] and skill and not skill.trainer then
                    local rank = rank_at(skill, level)
                    if rank and unvouched(pd, name, rank, npc) then add(name, rank, "guess") end
                end
            end
        end

        -- Sure first, then by name.
        table.sort(out.skills, function(a, b)
            if a.sure ~= b.sure then return a.sure end
            if a.how ~= b.how then return HOW_ORDER[a.how] < HOW_ORDER[b.how] end
            return a.name < b.name
        end)
        local parts = {}
        for i = 1, min(#out.skills, MAX_SKILLS) do
            local s = out.skills[i]
            parts[#parts + 1] = string.format("%s %d%s%s", s.name, s.rank, s.sure and "" or "?", s.new and " new" or "")
        end
        local head = name_of_family
        if not out.can_now then head = string.format("%s, tame at %d", name_of_family, level) end
        out.text = #parts > 0 and (head .. ": " .. table.concat(parts, ", ")) or head
        return out
    end

    --- The answer for a beast of this kind and level, kept per guid for
    --- CACHE_FOR seconds. The caller has checked it is a beast, alive, no
    --- player's and nobody's pet, and that you are a hunter.
    local function answer_for(npc, level, guid, now)
        local hit = guid and cache[guid]
        if hit and (now - hit.at) < CACHE_FOR then return hit.answer or nil end
        local answer = false
        local d = data()
        npc, level = tonumber(npc) or 0, tonumber(level) or 0
        if d and d.families and npc > 0 and level > 0 then
            local creatures = ctx and ctx.creatures
            local b = nil
            if creatures and creatures.beast then
                local ok, got = pcall(creatures.beast, npc)
                if ok and type(got) == "table" then b = got end
            end
            local pd = petopia()
            local listed = pd and pd.npcs and pd.npcs[npc] or nil
            local family, fam = nil, nil
            local tameable = false
            if b then
                -- The client's own word wins: it may say Forever changed one.
                if b.tameable then
                    family = b.family
                    fam = d.families[family]
                    tameable = fam ~= nil and fam.hunter == true
                end
            elseif listed then
                -- Not described yet, but Petopia says it can be tamed.
                family = family_by_name(d, listed.family)
                fam = family and d.families[family] or nil
                tameable = true
            end
            if tameable then
                local player = units.player and units.player() or nil
                local ok, mine = false, 0
                if player then ok, mine = pcall(player.get_level, player) end
                answer = describe(family, fam, level, npc, (ok and tonumber(mine)) or 0, listed)
            end
        end
        if guid then
            if cache_n > 400 then cache, cache_n = {}, 0 end
            if not cache[guid] then cache_n = cache_n + 1 end
            cache[guid] = { at = now, answer = answer }
        end
        return answer or nil
    end

    --- What a hunter would get from this ESP mark, or nil: { family_name,
    --- level, can_now, listed, skills = { { name, rank, how, sure, seen, new,
    --- icon, spell } }, text }. `how` is "petopia", "seen" or "guess" (WHAT
    --- PETOPIA KNOWS); `icon` the game's icon (a FileDataID), `spell` the rank's
    --- spell id.
    --- Asked per mark per frame: the cheap tests first, and the frame's own
    --- time (`now`) instead of a read of the clock per mark.
    ---@param e table an ESP entity (kind, guid, info, dead)
    ---@param now? number the frame's time
    ---@return table|nil
    function M.info(e, now)
        if not e or e.kind ~= "unit" or e.dead then return nil end
        local info = e.info
        if not info or info.creature_type ~= BEAST or info.is_player or info.pet then return nil end
        now = now or core.time()
        if not hunter(now) then return nil end
        return answer_for(info.npc_id, info.level, e.guid, now)
    end

    --- The same for the Forever ESP, which keeps its own facts per unit: a
    --- living beast's npc id and level. nil for anyone but a hunter.
    ---@param npc integer
    ---@param level integer
    ---@param guid? string
    ---@param now? number the frame's time
    ---@return table|nil
    function M.beast(npc, level, guid, now)
        now = now or core.time()
        if not hunter(now) then return nil end
        return answer_for(npc, level, guid, now)
    end

    --- The skills Petopia's file has for this client: { [name] = { wild,
    --- ranks } }, or nil without it.
    function M.petopia()
        local pd = petopia()
        return pd and pd.skills or nil
    end

    return M
end

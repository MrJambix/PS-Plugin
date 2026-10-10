-- JCore / threat -- the whole group's threat on every mob in the fight, ranked.
--
-- Depends on: util, log, events, cache, units, enemies, group.
--
-- WHERE THIS COMES FROM
-- Details!' Tiny Threat plugin asks the client one question per group member,
-- UnitDetailedThreatSituation(member, mob), sorts the answers and draws them
-- as bars for the current target. This asks the same question of the same
-- client table -- through enemies.situation, which works out which way round
-- the client wants get_threat_situation asked -- for every mob the group is
-- fighting rather than only the target, so a mark over ANY mob can say
-- "you are at 72%, second of five". The enemies service already reads the
-- player's own threat; what it cannot say is where that puts you, because
-- that needs everyone else's.
--
-- WHAT THE PERCENT MEANS
-- The client's scaled percent, the one Tiny Threat shows by default: 100 is
-- the point at which that member becomes the mob's target. The tank reads
-- 100, and a mage at 90 is ten points from pulling whatever the raw numbers
-- are, because the client has already folded in the 110% melee / 130% ranged
-- rule. Ranks go by that percent, so #2 is "next to pull" -- the question.
--
-- WHO IS TANKING
-- status >= 2, not is_tanking. Before the 2026-10-06 core both were wrong on
-- the classic builds: status always 0, and is_tanking compared a hardcoded
-- offset (the .api); only threat_percent was right. So with no one reporting
-- status 2 or 3, whoever the mob is hitting is taken as its tank (below).
-- That core fixed both on every classic build (is_tanking is status >= 2
-- now), and the same reads simply start agreeing. When nobody in the group
-- tanks and the mob is on somebody outside it -- an escort, a stranger who
-- tagged it -- that outsider holds rank 1, the way Tiny Threat's "Current
-- Tank" bar does, so your own rank is still honest.
--
-- WHO IS ASKED
-- The roster: you, your pet, every party member the client holds an object
-- for and their pets, and in a raid every raidN token that resolves. Rebuilt
-- every two seconds and on a roster event, not per tick. The raid tokens are
-- probed a few per tick rather than forty in one frame -- the freeze log in
-- the AIO README is the history of what forty natives in one frame costs.
--
-- WHICH MOBS
-- The enemies service's rows that are in combat AND fighting us: on one of
-- the roster, or holding some of your threat. The current target first, then
-- nearest, at most MAX_BOARDS. A mob that stops qualifying loses its board on
-- the same tick, so nothing is ever drawn from a fight that ended.
--
-- COST
-- One native per roster member per mob per read (two until enemies.situation
-- has settled which way round to ask): the target twice a second,
-- the rest once. A per-tick budget spreads them, and at least one whole board
-- is read every tick however large the raid, so nothing starves. Your own
-- answer comes from the enemies row when that is fresh, so a solo fight costs
-- no native at all.
--
-- EVENTS, ON TRANSITION ONLY
--   jcore.threat.gained   you became the mob's top threat  (board)
--   jcore.threat.lost     you stopped being it             (board)
--
-- A board handed out or carried on an event is LIVE: the next read rewrites
-- it in place. Read it, do not keep it.

return function(rt)
    local util = rt.util
    local events = rt.events
    local cache = rt.cache
    local units = rt.units
    local enemies = rt.enemies
    local group = rt.group
    local log = rt.log.for_tag("JCore/threat")

    local try = cache.try
    local huge = math.huge
    local situation = enemies.situation

    local M = {}

    -- --- tuning -------------------------------------------------------------

    local ROSTER_EVERY = 2.0        -- who can hold threat changes on a roster event, not per tick
    local RAID_TOKENS = 40
    local RAID_PROBES_PER_TICK = 8  -- forty tokens over five ticks
    local RAID_SWEEP_EVERY = 4.0    -- between passes over the raid tokens
    local TARGET_EVERY = 0.5        -- Tiny Threat's own default is once a second
    local OTHER_EVERY = 1.0
    local READS_PER_TICK = 24       -- natives; one whole board is read regardless
    local MAX_BOARDS = 10
    local RANGE = 60.0              -- the enemies service's detail range
    local OWN_FRESH = 0.6           -- your own enemies-row answer, if read this recently

    local RAID_TOKEN = {}
    for i = 1, RAID_TOKENS do RAID_TOKEN[i] = "raid" .. i end

    -- group.ROLE number -> the client's word, so a row from the party roster
    -- and the player's own role read the same.
    local ROLE_WORD = {}
    for name, value in pairs(group.ROLE or {}) do ROLE_WORD[value] = name end

    local enabled = true

    ---@param on boolean
    function M.set_enabled(on) enabled = on and true or false end

    -- --- roster -------------------------------------------------------------

    local roster = {}       -- actors, you first
    local roster_n = 0
    local by_guid = {}      -- guid -> actor
    local roster_at = -huge
    local roster_dirty = true

    local in_party = false
    local company = { players = 0, pet = false }
    local raid_found = {}   -- token index -> object, from the last probe of it
    local raid_count = 0
    local raid_cursor = 0   -- next token to probe; 0 between sweeps
    local raid_swept_at = -huge

    local function add_actor(obj, guid, name, opts)
        if not obj or not guid or by_guid[guid] then return nil end
        local actor = {
            obj = obj,
            guid = guid,
            name = name or "",
            is_me = opts.is_me == true,
            is_pet = opts.is_pet == true,
            mine = opts.mine == true,       -- you or your pet
            owner_guid = opts.owner_guid,
            role = opts.role or "NONE",
            class = opts.class,
        }
        roster_n = roster_n + 1
        roster[roster_n] = actor
        by_guid[guid] = actor
        return actor
    end

    local function valid(obj)
        return obj ~= nil and try(obj.is_valid, obj) == true
    end

    local function add_pet(owner, owner_guid, mine)
        local pet = try(owner.get_pet, owner)
        if not valid(pet) then return end
        add_actor(pet, units.guid(pet), units.name(pet),
            { is_pet = true, mine = mine, owner_guid = owner_guid })
    end

    local function rebuild_roster(now, player)
        local before = roster_n
        roster, by_guid, roster_n = {}, {}, 0
        company.players, company.pet = 0, false
        roster_at = now
        roster_dirty = false

        local my_guid = units.guid(player)
        add_actor(player, my_guid, units.name(player), {
            is_me = true, mine = true,
            role = ROLE_WORD[group.role(player)],
        })
        add_pet(player, my_guid, true)

        local members = group.members()
        in_party = #members > 0
        for i = 1, #members do
            local row = members[i]
            local obj = type(row) == "table" and row.object or nil
            if valid(obj) then
                local guid = units.guid(obj)
                if add_actor(obj, guid, row.name, { role = row.role, class = row.class_file }) then
                    add_pet(obj, guid, false)
                end
            end
        end

        -- A build whose roster rows carry no object still has the frames.
        local frames = group.party_frames()
        for i = 1, #frames do
            local obj = frames[i]
            if valid(obj) then
                local guid = units.guid(obj)
                if add_actor(obj, guid, units.name(obj), {}) then
                    add_pet(obj, guid, false)
                end
            end
        end
        if #frames > 0 then in_party = true end

        -- Raid members past your own party. No pets: Tiny Threat drops them
        -- in a raid too, and forty more natives per mob would buy little.
        for i = 1, RAID_TOKENS do
            local obj = raid_found[i]
            if obj and valid(obj) then
                add_actor(obj, units.guid(obj), units.name(obj), {})
            end
        end

        for i = 1, roster_n do
            local a = roster[i]
            if a.is_pet then
                if a.mine then company.pet = true end
            elseif not a.is_me then
                company.players = company.players + 1
            end
        end

        if roster_n ~= before then
            log.fmt("debug", "roster: %d who can hold threat (%d from raid tokens)", roster_n, raid_count)
        end
    end

    --- Probes the next few raid tokens. Nothing at all while not in a party:
    --- in a raid your own subgroup fills the party frames, and the one case
    --- that misses -- alone in your subgroup -- costs that raid its ranking
    --- and nothing worse.
    local function probe_raid(now)
        if not in_party then
            if raid_count > 0 then
                for i = 1, RAID_TOKENS do raid_found[i] = nil end
                raid_count = 0
                roster_dirty = true
            end
            raid_cursor = 0
            return
        end

        if raid_cursor == 0 then
            if (now - raid_swept_at) < RAID_SWEEP_EVERY then return end
            raid_cursor = 1
        end

        local last = math.min(RAID_TOKENS, raid_cursor + RAID_PROBES_PER_TICK - 1)
        for i = raid_cursor, last do
            raid_found[i] = units.by_guid(RAID_TOKEN[i])
        end

        if last >= RAID_TOKENS then
            raid_cursor = 0
            raid_swept_at = now
            local found = 0
            for i = 1, RAID_TOKENS do
                if raid_found[i] then found = found + 1 end
            end
            -- Objects are new wrappers per read, so "did it change" is not
            -- answerable by identity. A raid rebuilds its roster each sweep;
            -- a party with no raid tokens never does.
            if found > 0 or raid_count > 0 then roster_dirty = true end
            raid_count = found
        else
            raid_cursor = last + 1
        end
    end

    for _, event in ipairs({
        "GROUP_ROSTER_UPDATE", "PARTY_MEMBERS_CHANGED", "RAID_ROSTER_UPDATE",
        "UNIT_PET", "PLAYER_ENTERING_WORLD",
    }) do
        events.on("jcore.game_event." .. event, function()
            roster_dirty = true
            raid_swept_at = -huge
        end, { owner = "jcore", priority = 0 })
    end

    -- --- boards -------------------------------------------------------------

    local boards = {}       -- mob guid -> board
    local ordered = {}      -- this tick's boards: the target, then nearest
    local board_n = 0
    local reads_this_tick = 0
    local stats = { reads = 0, boards_read = 0, events = 0, asked = 0, answered = 0, inferred = 0 }

    local function new_board(row)
        return {
            guid = row.guid,
            obj = row.obj,
            at = -huge,             -- last read; -huge until the first
            entries = {},
            n = 0,                  -- entries: actors with any threat, ranked
            count = 0,              -- n, plus one for a tank outside the group
            tank = nil,             -- the entry holding it, when it is one of us
            outside_tank = false,
            me = nil,               -- your entry, or nil when you have no threat
            pet = nil,              -- your pet's entry
            my_rank = nil,
            my_percent = nil,
            next_percent = nil,     -- the highest percent of anyone NOT tanking
            is_target = false,
            had_aggro = false,
        }
    end

    local function ranked(a, b)
        if a.tanking ~= b.tanking then return a.tanking end
        if a.percent ~= b.percent then return a.percent > b.percent end
        if a.status ~= b.status then return a.status > b.status end
        return a.guid < b.guid
    end

    local function emit(name, ...)
        stats.events = stats.events + 1
        events.emit(name, ...)
    end

    --- Asks the client about every actor on the roster and ranks the answers.
    ---@return integer natives The native calls this read cost.
    local function read_board(board, row, now)
        local mob = row.obj
        local entries = board.entries
        local natives = 0
        local n = 0

        for i = 1, roster_n do
            local actor = roster[i]
            local status, percent = nil, nil

            local own = actor.is_me and row.threat or nil
            if own and (now - (row.threat_at or -huge)) <= OWN_FRESH then
                status, percent = own.status or 0, own.percent or 0
            else
                stats.asked = stats.asked + 1
                local t, cost
                if situation then
                    -- Asked the way round the client answers; see enemies.
                    t, cost = situation(mob, actor.obj, row.target_guid == actor.guid)
                else
                    t, cost = try(mob.get_threat_situation, mob, actor.obj), 1
                end
                natives = natives + (cost or 1)
                if type(t) == "table" then
                    stats.answered = stats.answered + 1
                    status, percent = t.status or 0, t.threat_percent or 0
                end
            end

            if status and (percent > 0 or status > 0) then
                n = n + 1
                local e = entries[n]
                if not e then
                    e = {}
                    entries[n] = e
                end
                e.guid = actor.guid
                e.name = actor.name
                e.obj = actor.obj
                e.is_me = actor.is_me
                e.is_pet = actor.is_pet
                e.mine = actor.mine
                e.role = actor.role
                e.class = actor.class
                e.status = status
                e.tanking = status >= 2
                -- The holder is at 100 by definition; a client that reports
                -- the raw figure for the tank would otherwise rank it below
                -- the people chasing it.
                e.percent = e.tanking and 100 or math.max(0, percent)
                e.rank = 0
                e.inferred = false
            end
        end

        -- The client said nothing about anyone, yet the mob is on one of
        -- us: a fight the threat table has not caught up with, or a client
        -- that does not answer for this mob. Whoever it is hitting holds it
        -- -- the same thing the status line says -- so the board is not
        -- empty while the fight plainly is not.
        if n == 0 and row.target_guid and by_guid[row.target_guid] then
            local actor = by_guid[row.target_guid]
            n = 1
            local e = entries[1]
            if not e then
                e = {}
                entries[1] = e
            end
            e.guid = actor.guid
            e.name = actor.name
            e.obj = actor.obj
            e.is_me = actor.is_me
            e.is_pet = actor.is_pet
            e.mine = actor.mine
            e.role = actor.role
            e.class = actor.class
            e.status = 3
            e.tanking = true
            e.percent = 100
            e.rank = 0
            e.inferred = true
            stats.inferred = stats.inferred + 1
        end
        for i = #entries, n + 1, -1 do entries[i] = nil end

        table.sort(entries, ranked)

        -- Nobody reports holding it. If the mob is on one of us anyway --
        -- a status the client has not caught up with -- that one is the
        -- tank. If it is on somebody else, an outsider holds rank 1.
        local outside = false
        if n > 0 and not entries[1].tanking and row.target_guid then
            local held = nil
            for i = 1, n do
                if entries[i].guid == row.target_guid then held = entries[i] break end
            end
            if held then
                held.tanking = true
                held.percent = 100
                table.sort(entries, ranked)
            elseif not by_guid[row.target_guid] then
                outside = true
            end
        end

        local offset = outside and 1 or 0
        board.obj = row.obj
        board.n = n
        board.count = n + offset
        board.outside_tank = outside
        board.tank = (n > 0 and entries[1].tanking) and entries[1] or nil
        board.me, board.pet, board.my_rank, board.my_percent = nil, nil, nil, nil
        board.next_percent = nil
        for i = 1, n do
            local e = entries[i]
            e.rank = i + offset
            if e.is_me then
                board.me = e
                board.my_rank = e.rank
                board.my_percent = e.percent
            elseif e.mine and e.is_pet then
                board.pet = e
            end
            if not e.tanking and board.next_percent == nil then
                board.next_percent = e.percent
            end
        end
        board.at = now

        local aggro = board.me ~= nil and board.me.tanking
        if aggro ~= board.had_aggro then
            board.had_aggro = aggro
            emit(aggro and "jcore.threat.gained" or "jcore.threat.lost", board)
        end

        stats.boards_read = stats.boards_read + 1
        return natives
    end

    --- Is this enemies row a fight the group is in?
    local function fighting_us(row)
        if not row.in_combat or row.dist > RANGE then return false end
        if row.target_guid and by_guid[row.target_guid] then return true end
        local own = row.threat
        if own and ((own.percent or 0) > 0 or (own.status or 0) > 0) then return true end
        local board = boards[row.guid]
        return board ~= nil and board.n > 0
    end

    local candidates = {}

    local function clear_all()
        for guid in pairs(boards) do boards[guid] = nil end
        for i = board_n, 1, -1 do ordered[i] = nil end
        board_n = 0
    end

    function M._poll()
        reads_this_tick = 0
        local player = enabled and units.player() or nil
        if not player then
            clear_all()
            return
        end

        local now = core.time()
        probe_raid(now)
        if roster_dirty or (now - roster_at) >= ROSTER_EVERY then
            rebuild_roster(now, player)
        end

        local rows = enemies.all()
        local n = 0
        for i = 1, #rows do
            local row = rows[i]
            if fighting_us(row) then
                n = n + 1
                candidates[n] = row
            end
        end
        for i = #candidates, n + 1, -1 do candidates[i] = nil end

        if n == 0 then
            clear_all()
            return
        end

        -- The target goes first: it is the board read most often, and the
        -- one a cap must never cut. One native, and only in a fight.
        local target = try(player.get_target, player)
        local target_guid = valid(target) and units.guid(target) or nil
        if target_guid then
            for i = 2, n do
                if candidates[i].guid == target_guid then
                    local row = candidates[i]
                    table.remove(candidates, i)
                    table.insert(candidates, 1, row)
                    break
                end
            end
        end

        local shown = math.min(n, MAX_BOARDS)
        local budget = READS_PER_TICK
        local read_any = false
        local listed = 0
        for i = 1, shown do
            local row = candidates[i]
            local board = boards[row.guid]
            if not board then
                board = new_board(row)
                boards[row.guid] = board
            end
            board.seen = now
            board.obj = row.obj
            board.is_target = row.guid == target_guid
            local every = board.is_target and TARGET_EVERY or OTHER_EVERY
            if (now - board.at) >= every and (budget >= roster_n or not read_any) then
                local cost = read_board(board, row, now)
                budget = budget - cost
                reads_this_tick = reads_this_tick + cost
                read_any = true
            end
            -- Listed once it has been read: a board with nothing in it yet
            -- would read as "nobody has threat", which is a claim.
            if board.at > -huge then
                listed = listed + 1
                ordered[listed] = board
            end
        end
        for i = board_n, listed + 1, -1 do ordered[i] = nil end
        board_n = listed

        for guid, board in pairs(boards) do
            if board.seen ~= now then boards[guid] = nil end
        end
        stats.reads = stats.reads + reads_this_tick
    end

    -- --- queries ------------------------------------------------------------

    --- The ranked board for a mob, or nil when the group is not fighting it
    --- or it has not been read yet.
    ---@param unit_or_guid game_object|string
    ---@return table|nil
    function M.get(unit_or_guid)
        local guid = type(unit_or_guid) == "string" and unit_or_guid or units.guid(unit_or_guid)
        local board = guid and boards[guid] or nil
        if board and board.at > -huge then return board end
        return nil
    end

    --- Your standing on a mob: percent, rank, how many are ranked, and
    --- whether you hold it. percent and rank are nil while you have no
    --- threat on it; everything is nil when there is no board.
    ---@param unit_or_guid game_object|string
    ---@return number|nil percent
    ---@return integer|nil rank
    ---@return integer|nil count
    ---@return boolean|nil tanking
    function M.mine(unit_or_guid)
        local board = M.get(unit_or_guid)
        if not board then return nil, nil, nil, nil end
        local me = board.me
        return board.my_percent, board.my_rank, board.count, me ~= nil and me.tanking
    end

    --- This tick's boards: the target first, then nearest. Rebuilt in place.
    ---@return table[]
    function M.boards() return ordered end

    ---@return integer
    function M.count() return board_n end

    --- Everyone who can hold threat, you first. Rebuilt every two seconds.
    ---@return table[]
    function M.roster() return roster end

    --- The board where you are nearest to pulling without already holding
    --- it, and your percent on it. What a "hold back" decision wants.
    ---@return table|nil board
    ---@return number percent
    function M.closest_to_pulling()
        local best, best_pct = nil, -1
        for i = 1, board_n do
            local board = ordered[i]
            local me = board.me
            if me and not me.tanking and me.percent > best_pct then
                best, best_pct = board, me.percent
            end
        end
        return best, math.max(0, best_pct)
    end

    --- Who else is with you: how many other players are on the roster, and
    --- whether you have a pet out. "Holding it" means something different
    --- solo than in a party.
    ---@return table { players = integer, pet = boolean }
    function M.company() return company end

    --- How many of the group's mobs you hold by threat.
    ---@return integer
    function M.holding()
        local n = 0
        for i = 1, board_n do
            local me = ordered[i].me
            if me and me.tanking then n = n + 1 end
        end
        return n
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        return {
            enabled = enabled,
            boards = board_n,
            roster = roster_n,
            raid = raid_count,
            reads = reads_this_tick,
            total_reads = stats.reads,
            boards_read = stats.boards_read,
            events = stats.events,
            -- Whether the client answers at all: asked against answered. A
            -- client that never answers shows here as 0 answered.
            asked = stats.asked,
            answered = stats.answered,
            inferred = stats.inferred,
            players = company.players,
            pet = company.pet,
        }
    end

    return M
end

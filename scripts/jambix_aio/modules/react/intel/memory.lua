-- Jambix AIO / react / intel / memory -- Stage 14 of PVP_INTEL_PLAN.md: the
-- players you have fought, remembered across sessions, and what your own
-- fights say about each class.
--
-- The predictor (predict.lua) counted each player's habits for the session
-- only: a rogue met again tomorrow started from nothing, and the shared
-- network (central.lua) needs two contributors before it says anything. So,
-- on this machine:
--
--   remember   when a fight with players closes (the debrief's), and on
--              logout, each player's pattern counts (chances taken, chances
--              not, by habit) go to jambix.aio.opponents.json under its guid
--              -- a character's guid is the same every session -- with its
--              name, class and when; the newest KM.keep players are kept
--   prior_for  when the predictor first counts a habit of a player: what you
--              remember of THAT player (its counts, faded by age: KM.half_
--              life_days), else what your own fights say of its CLASS (at
--              least KM.class_min chances over KM.class_players players),
--              else nil (the network's, then 0.5)
--
-- Memory moves where a habit starts, never past the evidence: a prior
-- weighs KP.prior_weight chances, and a prediction is "sure" only on
-- chances seen this session (predict.lua's min_samples). So a player
-- remembered as a Kidney Shot opener is expected to open with it, and is
-- predicted to once it does it again.

return function(P, lib, data, K)
    local floor, max, min, huge = math.floor, math.max, math.min, math.huge
    local KM, KP = K.MEMORY, K.PREDICT

    local M = {}

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end
    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end
    function M.enabled() return opt("intel_memory", true) == true end

    local FILE = "jambix.aio.opponents.json"
    local loaded, book = false, { players = {} }
    local by_class = nil                  -- built from the book when asked
    local function storage() local ctx = P.ctx return ctx and ctx.storage or nil end
    local function wall() return lib.wall_time and lib.wall_time() or 0 end

    local function load()
        if loaded then return end
        loaded = true
        local st = storage()
        local d = st and st.read_json and try(st.read_json, FILE) or nil
        if type(d) == "table" and type(d.players) == "table" then book = d end
        by_class = nil
    end
    local function save()
        local st = storage()
        if not (st and st.write_json) then return false end
        return try(st.write_json, FILE, book) == true
    end
    function M.book() load() return book end

    --- How much an old count still weighs: half each KM.half_life_days.
    local function fade(at, now_wall)
        if not at or now_wall <= 0 then return 1 end
        local days = max(0, (now_wall - at) / 86400)
        return 0.5 ^ (days / KM.half_life_days)
    end

    --- What your own fights say of a class, by habit: { [key] = { hits, total, players } }.
    local function class_rates()
        if by_class then return by_class end
        by_class = {}
        local now_wall = wall()
        for _, e in pairs(book.players) do
            if type(e) == "table" and e.class and type(e.cats) == "table" then
                local rows = by_class[e.class] or {}
                by_class[e.class] = rows
                local w = fade(e.at, now_wall)
                for key, c in pairs(e.cats) do
                    local r = rows[key] or { hits = 0, total = 0, players = 0 }
                    rows[key] = r
                    r.hits = r.hits + (tonumber(c.hits) or 0) * w
                    r.total = r.total + (tonumber(c.total) or 0) * w
                    if (tonumber(c.total) or 0) > 0 then r.players = r.players + 1 end
                end
            end
        end
        return by_class
    end

    --- The prior for a player's habit: the rate, the chances behind it, and
    --- where it comes from ("this player" / "its class"); nil when nothing
    --- of yours says.
    ---@return number|nil p
    ---@return number n
    ---@return string|nil source
    function M.prior_for(guid, class, key)
        if not M.enabled() then return nil, 0 end
        load()
        local e = guid and book.players[guid] or nil
        -- Written this session already: only what came before it (this
        -- session's own chances are the predictor's, never counted twice).
        local src = e and ((e.session == M.session_id) and e.base or e.cats) or nil
        local c = type(src) == "table" and src[key] or nil
        if c and (tonumber(c.total) or 0) > 0 then
            local w = fade(e.at, wall())
            local hits, total = (tonumber(c.hits) or 0) * w, (tonumber(c.total) or 0) * w
            if total >= KM.player_min then
                return (hits + KP.prior_weight * KP.prior) / (total + KP.prior_weight), total, "this player"
            end
        end
        local rows = class and class_rates()[class] or nil
        local r = rows and rows[key] or nil
        if r and r.total >= KM.class_min and r.players >= KM.class_players then
            return (r.hits + KP.prior_weight * KP.prior) / (r.total + KP.prior_weight), r.total, "its class"
        end
        return nil, 0
    end

    -- The fight's players as it goes: the picture drops a player the moment
    -- it dies, so by the fight's close the dead are gone from it. Their
    -- pattern tables are kept here by reference until the fight is written.
    local seen = {}
    local seen_at = -huge

    --- Writes down every player of the picture (and of the fight so far)
    --- the predictor counted anything for. Returns how many.
    function M.remember(S)
        if not M.enabled() then return 0 end
        load()
        local now_wall, n = wall(), 0
        local all = {}
        for guid, e in pairs(seen) do all[guid] = e end
        for guid, f in pairs(S.foes or {}) do all[guid] = f end
        for guid in pairs(seen) do seen[guid] = nil end
        for guid, f in pairs(all) do
            local p = f.pat
            if p and p.cats and f.class then
                local cats, any = {}, false
                for key, c in pairs(p.cats) do
                    if (c.total or 0) > 0 then
                        -- This session's counts, added to what was remembered
                        -- before it (faded), never counted twice: the session's
                        -- own total is kept apart and replaced.
                        cats[key] = { hits = c.hits or 0, total = c.total or 0 }
                        any = true
                    end
                end
                if any then
                    local e = book.players[guid] or { cats = {}, base = {} }
                    e.base = e.base or {}
                    if e.session ~= M.session_id then
                        -- A new session: what was there becomes the base, faded.
                        local w = fade(e.at, now_wall)
                        for key, c in pairs(e.cats or {}) do
                            e.base[key] = { hits = (tonumber(c.hits) or 0) * w, total = (tonumber(c.total) or 0) * w }
                        end
                        e.session = M.session_id
                    end
                    e.cats = {}
                    for key, b in pairs(e.base) do e.cats[key] = { hits = b.hits, total = b.total } end
                    for key, c in pairs(cats) do
                        local r = e.cats[key] or { hits = 0, total = 0 }
                        r.hits, r.total = r.hits + c.hits, r.total + c.total
                        e.cats[key] = r
                    end
                    e.name, e.class, e.at = f.name, f.class, now_wall
                    e.fights = (e.fights or 0) + (e.counted_fight == M.fight_mark and 0 or 1)
                    e.counted_fight = M.fight_mark
                    book.players[guid] = e
                    n = n + 1
                end
            end
        end
        if n > 0 then
            -- The newest KM.keep players.
            local list = {}
            for guid, e in pairs(book.players) do list[#list + 1] = { guid = guid, at = tonumber(e.at) or 0 } end
            if #list > KM.keep then
                table.sort(list, function(a, b) return a.at > b.at end)
                for i = KM.keep + 1, #list do book.players[list[i].guid] = nil end
            end
            by_class = nil
            save()
        end
        return n
    end

    -- One id a session, so a player's counts this session replace (not add
    -- to) what this session already wrote; one mark a fight for its tally.
    M.session_id = lib.random_hex and lib.random_hex(12) or tostring(wall())
    M.fight_mark = 0

    --- After the debrief: a fight with players closed -- remember them.
    local was_open = false
    function M.update(W, S, now)
        local D = lib.debrief and lib.debrief.T or nil
        local open = D ~= nil and D.open == true
        if open and M.enabled() and (now - seen_at) >= 1.0 then
            seen_at = now
            for guid, f in pairs(S.foes or {}) do
                if f.pat and f.class then seen[guid] = { pat = f.pat, class = f.class, name = f.name } end
            end
        end
        if was_open and not open then
            M.fight_mark = M.fight_mark + 1
            pcall(M.remember, S)
        end
        was_open = open
    end

    --- Logging out: remembered as it stands.
    function M.on_logout(S)
        pcall(M.remember, S)
    end

    --- In words, for the readout: how many players and classes you remember.
    function M.line()
        load()
        local n, classes = 0, {}
        for _, e in pairs(book.players) do
            n = n + 1
            if e.class then classes[e.class] = true end
        end
        local cl = 0
        for _ in pairs(classes) do cl = cl + 1 end
        return n > 0 and string.format("memory: %d player(s) remembered, %d class(es)", n, cl) or nil
    end

    function M.reset_cache() loaded, by_class = false, nil end

    return M
end

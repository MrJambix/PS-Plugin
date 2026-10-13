-- Jambix AIO / react / intel / cooldowns -- what was spent, what is back,
-- and whether another answer is needed (PvP intelligence, Stage 3 / brief
-- Phase 5).
--
-- "Professional PvP is fundamentally about resource exchanges." A fight
-- with a player is a trade of cooldowns, and a trade needs a ledger:
--
--   THEIRS   every ability seen from a player (state.lua's recent ring: its
--            cast events by unit token, the buff a cooldown leaves, on Era
--            the combat log's cast lines) becomes an entry in that player's
--            ledger, foe.cds[name]: when it was seen, through what, how sure
--            (score.lua CD: an event 1.0, a started cast 0.5, an aura 0.7),
--            and -- when the client's own tables say the cooldown
--            (pvp_data.lua, tools/jcheck/pvp_extract.js) -- when it is back,
--            with a shared category (Forever's two traps) kept per category.
--            A spell never seen is UNKNOWN, never "ready"; one whose
--            cooldown the tables do not carry is "unknown cooldown".
--   OURS     the picture's abilities by purpose (state.lua), with the same
--            tables for what each costs in cooldown.
--   COVER    what a buff on us already answers, with how long it has left
--            (data.PROTECTION over the player's own aura index).
--
-- And the economy questions the brief asks, as functions a rule or a later
-- stage calls:
--   sufficient(kind)   is the protection up enough, for long enough, that
--                      another defensive against this kind would be spent
--                      for nothing?
--   cheapest(kind)     our ready answers to it, cheapest cooldown first
--   answer(kind)       the brief's own decision: preserve | cheapest | none
--                      (escape, control or line of sight instead)
--   reserved           what to keep: the last ready control for a melee
--                      player closing, the last defensive for a burst the
--                      ledger says is back soon
-- Two hooks the existing rules ask (rules/pvp.lua's "answer the burst",
-- rules/core.lua's "Defensive cooldown"): hold_answer and hold_defensive,
-- each returning the reason to hold a self-defensive while the protection
-- already up covers it, and nothing otherwise. Never under critical health.

return function(P, lib, data, K)
    local units = P.units
    local book = P.spellbook

    local M = {}
    local huge, floor, max, min = math.huge, math.floor, math.max, math.min
    local CD = K.CD

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        if ok then return value end
        return nil
    end

    local function game_ms()
        if type(core.game_time) ~= "function" then return nil end
        local ok, value = pcall(core.game_time)
        return ok and type(value) == "number" and value or nil
    end

    -- --- the tables ------------------------------------------------------------------

    local client_key = (lib.client and lib.client.forever) and "forever" or "vanilla"
    local half = lib.pvp_data and lib.pvp_data[client_key] or nil
    local classes = half and half.classes or nil
    local index, index_class = {}, {}       -- name -> row of the first class that has it
    if classes then
        for cls, tbl in pairs(classes) do
            for name, row in pairs(tbl) do
                if not index[name] then index[name], index_class[name] = row, cls end
            end
        end
    end

    --- The client's row for an ability, its own class's first.
    ---@param name string
    ---@param cls? string
    ---@return table|nil row
    ---@return string|nil class
    function M.fact(name, cls)
        if not classes or type(name) ~= "string" then return nil end
        local own = cls and classes[cls] or nil
        local row = own and own[name] or nil
        if row then return row, cls end
        return index[name], index_class[name]
    end
    M.has_data = classes ~= nil
    M.client = client_key
    M.build = half and half.build or nil

    local T = {
        tracked = 0, down = 0, unknown = 0, ready = 0,
        target = nil, target_guid = nil,
        protection = { names = {}, left = huge, physical = 0, spell = 0, melee = 0 },
        reserved = {}, reserved_n = 0,
        answer = nil,
        data = classes ~= nil, data_build = M.build, client = client_key,
    }
    M.T = T

    -- --- theirs ----------------------------------------------------------------------

    local function entry_of(f, name)
        local e = f.cds[name]
        if not e then
            e = { name = name }
            f.cds[name] = e
        end
        return e
    end

    --- New rows of a player's recent ring into its ledger.
    local function feed(f, now)
        f.cds = f.cds or {}
        f.cds_cat = f.cds_cat or {}
        local recent = f.recent
        local last = f.cds_at or -huge
        local newest = last
        for i = 1, #recent do
            local r = recent[i]
            if r.at > last then
                if r.at > newest then newest = r.at end
                local kind = r.kind
                if kind == "interrupted" then
                    -- A cast that began and was stopped did not go on cooldown.
                    local e = f.cds[r.name]
                    if e and e.source == "UNIT_SPELLCAST_START" and (r.at - (e.seen_at or -huge)) < 10 then
                        e.ready_at, e.conf, e.interrupted = nil, 0, true
                    end
                elseif (kind == "cast" or kind == "start" or kind == "channel" or kind == "buff")
                    and not (lib.own and lib.own(f, r) == false) then
                    -- (another's shield on it, another class's spell: not its cooldown)
                    local row = M.fact(r.name, f.class)
                    local e = entry_of(f, r.name)
                    e.id, e.seen_at, e.source, e.kind, e.interrupted = r.id, r.at, r.source, kind, nil
                    e.conf = (kind == "buff" and CD.conf_aura) or (kind == "start" and CD.conf_start)
                        or (r.source == "SPELL_CAST_SUCCESS" and CD.conf_log) or CD.conf_event
                    e.base = row and row.cd or nil
                    e.category, e.cat_cd = row and row.category or nil, row and row.cat_cd or nil
                    e.ready_at = (e.base and e.base > 0) and (r.at + e.base) or nil
                    if e.category and e.cat_cd and e.cat_cd > 0 then
                        local cat = f.cds_cat[e.category] or {}
                        f.cds_cat[e.category] = cat
                        cat.ready_at, cat.by, cat.at = r.at + e.cat_cd, r.name, r.at
                    end
                end
            end
        end
        f.cds_at = newest
    end

    --- The estimate now: unknown | down | ready, the seconds, the confidence
    --- (fading once the cooldown has run out: it may have gone again unseen).
    local function settle(e, f, now)
        local ready_at = e.ready_at
        if e.category then
            local cat = f.cds_cat[e.category]
            if cat and (not ready_at or cat.ready_at > ready_at) then ready_at = cat.ready_at end
        end
        e.ready_eff = ready_at
        if e.interrupted then
            e.state, e.ready_in, e.conf_now = "interrupted", nil, 0
        elseif not e.base or e.base == 0 then
            e.state, e.ready_in, e.conf_now = "unknown", nil, e.conf
        elseif ready_at and ready_at > now then
            e.state, e.ready_in, e.conf_now = "down", ready_at - now, e.conf
        else
            e.state, e.ready_in = "ready", 0
            e.conf_now = (e.conf or 0) * max(0, 1 - (now - (ready_at or now)) / CD.decay)
        end
    end

    --- A player's ledger entry, or nil when nothing of that name was seen.
    ---@param guid string|nil
    ---@param name string
    ---@param S table the picture
    function M.seen(S, guid, name)
        local f = guid and S.foes[guid] or nil
        return f and f.cds and f.cds[name] or nil
    end

    --- Seconds until a player's ability is estimated back: 0 when it was
    --- seen and has run out, nil when never seen or its cooldown is unknown.
    function M.ready_in(S, guid, name)
        local e = M.seen(S, guid, name)
        if not e or e.state == "unknown" or e.state == "interrupted" then return nil end
        return e.ready_in or 0
    end

    -- --- ours ------------------------------------------------------------------------

    local my_class = nil

    local function read_protection(W, S, now)
        local pr = T.protection
        for i = #pr.names, 1, -1 do pr.names[i] = nil end
        pr.physical, pr.spell, pr.melee, pr.left = 0, 0, 0, huge
        local player = W.player.unit
        local index_ = player and units.aura_index and try(units.aura_index, player) or nil
        if type(index_) ~= "table" then return pr end
        local now_ms = game_ms()
        for _, aura in pairs(index_) do
            local name = type(aura) == "table" and aura.buff_name or nil
            local kind = name and data.PROTECTION[name] or nil
            local covers = kind and data.COVERS[kind] or nil
            if covers then
                pr.names[#pr.names + 1] = name
                local expires = tonumber(aura.expire_time) or 0
                local left = (expires > 0 and now_ms) and max(0, (expires - now_ms) / 1000) or huge
                if (covers.physical or 0) > 0 or (covers.spell or 0) > 0 or (covers.melee or 0) > 0 then
                    pr.left = min(pr.left, left)
                end
                pr.physical = max(pr.physical, covers.physical or 0)
                pr.spell = max(pr.spell, covers.spell or 0)
                pr.melee = max(pr.melee, covers.melee or 0)
            end
        end
        return pr
    end

    local function cover(kind)
        local pr = T.protection
        if kind == "physical" then return pr.physical end
        if kind == "spell" then return pr.spell end
        if kind == "melee" then return pr.melee end
        return 0
    end

    --- Is the protection up enough, for long enough, that another defensive
    --- against this kind would be spent for nothing?
    ---@param kind string "physical" | "spell" | "melee"
    ---@return boolean
    ---@return string why
    function M.sufficient(kind)
        local pr = T.protection
        local c = cover(kind)
        if c >= CD.cover_enough and pr.left >= CD.cover_left then
            return true, string.format("%s covers %d%% of %s for %.1fs", table.concat(pr.names, " and "),
                floor(c * 100 + 0.5), kind, min(pr.left, 999))
        end
        if c > 0 then
            return false, string.format("%s covers only %d%% of %s%s", table.concat(pr.names, " and "),
                floor(c * 100 + 0.5), kind, pr.left < CD.cover_left and string.format(", %.1fs left", pr.left) or "")
        end
        return false, "nothing up against " .. kind
    end

    local cheapest_pool = {}

    --- Our ready answers to a kind of threat, cheapest cooldown first:
    --- { name, set, cd } rows (reused between calls). A defensive or a
    --- control: an escape or a slow does not answer a burst, it leaves it
    --- (the "none" verdict names them).
    ---@param kind string
    ---@param S table
    ---@return table[] rows
    local SETS_SPELL, SETS_PHYSICAL = { "controls", "defensives" }, { "defensives", "controls" }
    function M.cheapest(kind, S)
        local out = cheapest_pool
        for i = #out, 1, -1 do out[i] = nil end
        local sets = (kind == "spell") and SETS_SPELL or SETS_PHYSICAL
        local me = S.me
        for _, set in ipairs(sets) do
            local rows = me.abilities and me.abilities[set] or {}
            for i = 1, #rows do
                local row = rows[i]
                if row.known and row.ready then
                    local fact = M.fact(row.name, my_class)
                    local cd = fact and fact.cd or nil
                    if not cd then
                        local ability = P.catalog and P.catalog.ability and try(P.catalog.ability, row.name) or nil
                        cd = ability and tonumber(ability.cooldown) or nil
                    end
                    out[#out + 1] = { name = row.name, set = set, cd = cd or huge, reserved = T.reserved[row.name] }
                end
            end
        end
        table.sort(out, function(a, b)
            if (a.reserved ~= nil) ~= (b.reserved ~= nil) then return a.reserved == nil end
            if a.cd ~= b.cd then return a.cd < b.cd end
            return a.name < b.name
        end)
        return out
    end

    --- The brief's own decision for a burst or a threat of `kind`.
    ---@return table { verdict = "preserve" | "cheapest" | "none", why, name? }
    function M.answer(kind, S)
        local ok, why = M.sufficient(kind)
        if ok then return { verdict = "preserve", why = why } end
        local list = M.cheapest(kind, S)
        if #list > 0 then
            local pick = list[1]
            return { verdict = "cheapest", name = pick.name, set = pick.set, cd = pick.cd,
                     why = string.format("%s (%s, %s cooldown)", pick.name, pick.set,
                         pick.cd < huge and string.format("%.0fs", pick.cd) or "no") }
        end
        return { verdict = "none", why = "no defensive answers it: escape, control or line of sight instead" }
    end

    -- --- what to keep ----------------------------------------------------------------

    local function compute_reserve(W, S, now)
        local R = T.reserved
        for k in pairs(R) do R[k] = nil end
        T.reserved_n = 0
        local me = S.me
        -- The last ready control, for a melee player closing but not here yet.
        local closing = nil
        for i = 1, #S.foe_list do
            local f = S.foe_list[i]
            if f.inferred.role.v == "melee" and (f.targets_me or f.in_combat) and f.dist > (S.env.melee_range or 5)
                and (f.time_to_reach or huge) <= CD.reserve_closing then
                closing = f
                break
            end
        end
        if closing and S.melee_attackers == 0 and (me.controls_ready or 0) == 1 then
            for _, row in ipairs(me.abilities.controls or {}) do
                if row.ready then
                    R[row.name] = string.format("%s closing (%.1fs): the last control ready", closing.name, closing.time_to_reach or 0)
                    T.reserved_n = T.reserved_n + 1
                end
            end
        end
        -- The last ready defensive, for a burst cooldown the ledger says is
        -- back soon on a player on you, with no burst up now.
        local soon = nil
        for i = 1, #S.foe_list do
            local f = S.foe_list[i]
            if f.targets_me and f.cds and not (f.st and f.st.burst) then
                for name, e in pairs(f.cds) do
                    local row = M.fact(name, f.class)
                    if row and lib.pvp and lib.pvp.ENEMY and lib.pvp.ENEMY[name] and lib.pvp.ENEMY[name].burst
                        and e.state == "down" and (e.ready_in or huge) <= CD.burst_soon then
                        soon = { f = f, name = name, ready_in = e.ready_in }
                        break
                    end
                end
            end
            if soon then break end
        end
        if soon and (me.defensives_ready or 0) == 1 then
            for _, row in ipairs(me.abilities.defensives or {}) do
                if row.ready then
                    R[row.name] = string.format("%s's %s back in %.0fs: the last defensive ready", soon.f.name, soon.name, soon.ready_in)
                    T.reserved_n = T.reserved_n + 1
                end
            end
        end
    end

    -- --- the tick --------------------------------------------------------------------

    ---@param W table
    ---@param S table the picture
    ---@param now number
    function M.update(W, S, now)
        my_class = W.class and W.class.class_name or my_class
        T.tracked, T.down, T.unknown, T.ready = 0, 0, 0, 0
        for _, f in pairs(S.foes) do
            if f.recent_at and f.recent_at > (f.cds_at or -huge) then feed(f, now) end
            if f.cds then
                for _, e in pairs(f.cds) do
                    settle(e, f, now)
                    T.tracked = T.tracked + 1
                    if e.state == "down" then T.down = T.down + 1
                    elseif e.state == "ready" then T.ready = T.ready + 1
                    else T.unknown = T.unknown + 1 end
                end
            end
        end
        local tg = S.env.target.guid and S.foes[S.env.target.guid] or nil
        T.target, T.target_guid = tg and tg.cds or nil, tg and tg.guid or nil
        read_protection(W, S, now)
        compute_reserve(W, S, now)
        T.answer = nil
        local V = W.pvp
        if S.active and V and V.burster and V.burster.st and V.burster.st.burst then
            T.answer = M.answer(V.burster.st.burst, S)
            T.answer.burst = V.burster.st.burst_name
        end
        return T
    end

    -- --- the hooks the rules ask ------------------------------------------------------

    local function module_on()
        if not P.opt then return true end
        local v = P.opt("intel_cooldowns", true)
        return v == nil or v == true
    end
    M.enabled = module_on

    --- rules/pvp.lua "answer the burst": hold a self-defensive while the
    --- protection up already covers the burst's kind.
    ---@return string|nil why
    function M.hold_answer(W, c)
        if not module_on() then return nil end
        if c.target_kind ~= "self" then return nil end
        local b = c.b
        local kind = b and b.st and b.st.burst or nil
        if not kind then return nil end
        if W.sit and W.sit.hp_critical then return nil end
        local ok, why = M.sufficient(kind)
        if ok then return "already covered: " .. why .. "; keeping " .. tostring(c.name) end
        return nil
    end

    --- rules/core.lua "Defensive cooldown": the same, against what is on
    --- you (melee players: their damage; a caster: spells).
    ---@return string|nil why
    function M.hold_defensive(W, c, S)
        if not module_on() then return nil end
        if not (S and S.active) then return nil end
        if W.sit and W.sit.hp_critical then return nil end
        local kind = (S.melee_attackers or 0) > 0 and "melee" or "spell"
        local ok, why = M.sufficient(kind)
        if ok then return "already covered: " .. why .. "; keeping " .. tostring(c.name) end
        return nil
    end

    function M.reset()
        T.tracked, T.down, T.unknown, T.ready = 0, 0, 0, 0
        T.target, T.target_guid, T.answer = nil, nil, nil
        for k in pairs(T.reserved) do T.reserved[k] = nil end
        T.reserved_n = 0
    end

    -- --- words -------------------------------------------------------------------------

    --- "cds: target Sprint back 42s (aura 0.7), Blind cooldown unknown | covered: Deterrence 6.2s | keep Freezing Trap (Enemy closing)"
    function M.line(S)
        local parts = {}
        local tg = T.target
        if tg then
            local words, n = {}, 0
            for name, e in pairs(tg) do
                n = n + 1
                if n <= 4 then
                    if e.state == "down" then
                        words[#words + 1] = string.format("%s back %.0fs (%s %.1f)", name, e.ready_in or 0,
                            e.kind == "buff" and "aura" or "cast", e.conf_now or 0)
                    elseif e.state == "ready" then
                        words[#words + 1] = string.format("%s ready? (%.1f)", name, e.conf_now or 0)
                    elseif e.state == "interrupted" then
                        words[#words + 1] = name .. " interrupted"
                    else
                        words[#words + 1] = name .. " cooldown unknown"
                    end
                end
            end
            if #words > 0 then
                table.sort(words)
                parts[#parts + 1] = "target: " .. table.concat(words, ", ") .. (n > 4 and string.format(" +%d", n - 4) or "")
            end
        end
        local pr = T.protection
        if #pr.names > 0 then
            parts[#parts + 1] = string.format("covered: %s%s", table.concat(pr.names, ", "),
                pr.left < huge and string.format(" %.1fs", pr.left) or "")
        end
        for name, why in pairs(T.reserved) do
            parts[#parts + 1] = string.format("keep %s (%s)", name, why)
        end
        if T.answer then
            local a = T.answer
            parts[#parts + 1] = string.format("%s: %s", a.burst or "burst",
                a.verdict == "preserve" and ("preserve, " .. a.why) or a.verdict == "cheapest" and ("cheapest " .. a.why) or a.why)
        end
        if not T.data then parts[#parts + 1] = "no pvp_data for " .. client_key .. ": cooldowns unknown" end
        if #parts == 0 then return nil end
        return "cds: " .. table.concat(parts, " | ")
    end

    return M
end

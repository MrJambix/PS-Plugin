-- Jambix AIO / react / intel / fieldcheck -- the game's own answers to what
-- the hunter work assumed and never saw (CHANGELOG 1.7.8, "Not yet seen in
-- game"; the user's relook of 2026-10-12, item 6). Each check watches for
-- the evidence it needs, counts what it saw across sessions, and says it:
-- in the log when a verdict first forms or changes, and on the Reactions
-- page under the fight debrief. Nothing here acts.
--
--   trap_in_melee   a trap laid with a hostile within melee reach: did its
--                   effect show on one of them within 5 s?
--   disengage       Disengage with a mob on you in melee: did it turn off
--                   you within 3 s?
--   sting_add       Serpent Sting sent at a mob that is not your target:
--                   did it go out (its cast succeeded) or not?
--   feign_cast      Feign Death while a player's cast at you is on its bar:
--                   did that cast land anyway, or fail? (needs the enemy's
--                   cast events: see the debrief's "Enemy events" line)
--   dr              Forever: how long each of your controls lasted on a
--                   player, by its place in a chain (first, second, third
--                   within 18 s): the diminishing returns, measured.
--
-- Kept in scripts_data/jambix.aio.fieldchecks.json. A check with no
-- evidence says "not seen yet"; a verdict is a count, never a guess.

return function(P, lib, data, K)
    local KF = K.FIELD
    local floor, huge = math.floor, math.huge
    local M = {}

    local FILE = "jambix.aio.fieldchecks.json"
    local TEXT = {
        trap_in_melee = "a trap laid in melee springs under the mob",
        disengage = "Disengage turns the mob off you",
        sting_add = "Serpent Sting goes out at a mob that is not your target",
        feign_cast = "Feign Death makes a player's cast at you fail",
    }
    local ORDER = { "trap_in_melee", "disengage", "sting_add", "feign_cast" }
    local TRAPS = { ["Immolation Trap"] = true, ["Explosive Trap"] = true, ["Freezing Trap"] = true, ["Frost Trap"] = true }
    local CONTROLS = { ["Freezing Trap Effect"] = true, ["Scatter Shot"] = true, ["Intimidation"] = true, ["Scare Beast"] = true,
                       ["Wyvern Sting"] = true, ["Wing Clip"] = false }

    local store = nil
    local dirty, saved_at = false, -huge
    local pending = { traps = {}, disengage = {}, stings = {}, feign = {} }
    local chains = {}                 -- guid|name -> { step, ends_at }
    M.pending = pending

    local function storage() local ctx = P.ctx return ctx and ctx.storage or nil end
    local function load()
        if store then return store end
        local st = storage()
        local ok, v = false, nil
        if st and st.read_json then ok, v = pcall(st.read_json, FILE) end
        store = (ok and type(v) == "table") and v or {}
        store.checks = type(store.checks) == "table" and store.checks or {}
        store.dr = type(store.dr) == "table" and store.dr or {}
        return store
    end
    local function save(now)
        if not dirty then return end
        local st = storage()
        if st and st.write_json then pcall(st.write_json, FILE, store) end
        dirty, saved_at = false, now
    end

    local function verdict_of(c)
        if not c or (c.yes or 0) + (c.no or 0) == 0 then return "not seen yet" end
        local yes, no = c.yes or 0, c.no or 0
        local word = (no == 0 and "yes") or (yes == 0 and "no") or "mixed"
        return string.format("%s (%d of %d)", word, yes, yes + no)
    end

    --- One answer for a check: counted, kept, and said when the verdict changes.
    local function answer(key, yes, how, now)
        local s = load()
        local c = s.checks[key] or { yes = 0, no = 0 }
        s.checks[key] = c
        local before = verdict_of(c):match("^%a+")
        if yes then c.yes = (c.yes or 0) + 1 else c.no = (c.no or 0) + 1 end
        c.last, c.at = how, (lib.wall_time and lib.wall_time()) or 0
        dirty = true
        local after = verdict_of(c):match("^%a+")
        if before ~= after and P.log and P.log.fmt then
            P.log.fmt("info", "field check: %s -- %s: %s", TEXT[key], verdict_of(c), how)
        end
    end
    M.answer = answer

    local function trap_effect(nm)
        return nm:find("Trap", 1, true) ~= nil and (nm:find("Effect", 1, true) ~= nil or nm:find("Aura", 1, true) ~= nil)
    end

    local function rows(W)
        return (W and W.enemies and W.enemies.list) or {}, (W and W.enemies and W.enemies.count) or 0
    end

    local function aura_names(unit)
        local units = P.units
        if not (unit and units and units.aura_index) then return nil end
        local ok, idx = pcall(units.aura_index, unit)
        if not ok or type(idx) ~= "table" then return nil end
        local names = {}
        for _, a in pairs(idx) do
            local n = type(a) == "table" and (a.buff_name or a.name) or nil
            if type(n) == "string" then names[n] = true end
        end
        return names
    end

    -- --- our casts, and the jobs they start -------------------------------------------------

    function M.on_our_cast(name, W, S, now)
        if type(name) ~= "string" then return end
        local list, n = rows(W)
        if TRAPS[name] then
            -- A trap effect already on a mob in reach (an earlier trap) would
            -- read as this one springing: then the check has no clean answer.
            local near, already = {}, false
            for i = 1, n do
                local r = list[i]
                if r and r.guid and r.obj and (r.dist or huge) <= KF.melee then
                    near[#near + 1] = { guid = r.guid, obj = r.obj }
                    for nm in pairs(aura_names(r.obj) or {}) do if trap_effect(nm) then already = true end end
                end
            end
            if #near > 0 and not already then pending.traps[#pending.traps + 1] = { trap = name, at = now, near = near } end
        elseif name == "Disengage" then
            local on = {}
            for i = 1, n do
                local r = list[i]
                if r and r.guid and r.targeting_me and (r.dist or huge) <= KF.disengage_reach then on[#on + 1] = r.guid end
            end
            if #on > 0 then pending.disengage[#pending.disengage + 1] = { at = now, on = on } end
        elseif name == "Serpent Sting" then
            for i = #pending.stings, 1, -1 do
                local p = pending.stings[i]
                if (now - p.at) <= KF.sting_window then
                    answer("sting_add", true, "a sting at a mob not your target went out", now)
                    table.remove(pending.stings, i)
                    break
                end
            end
        elseif name == "Feign Death" and S and S.foes then
            for guid, f in pairs(S.foes) do
                local c = f.casting
                if c and c.at_me and (c.left or 0) > 0 and c.name and c.name ~= "" then
                    pending.feign[#pending.feign + 1] = { guid = guid, cast = c.name, at = now, until_at = now + (c.left or 0) + KF.feign_slack }
                end
            end
        end
    end

    --- JCore's cast request (jcore.cast.sent): a Serpent Sting sent at a mob
    --- that is not your target opens the sting check.
    function M.on_sent(request, S, now)
        if type(request) ~= "table" then return end
        local name = lib.spell_name and lib.spell_name(tonumber(request.spell_id)) or nil
        if name ~= "Serpent Sting" then return end
        local tg = request.target
        local guid = nil
        if tg then
            local ok, g = pcall(function() return tg:get_guid() end)
            guid = ok and g or nil
        end
        local mine = S and S.env and S.env.target and S.env.target.guid or nil
        if guid and mine and guid ~= mine then
            pending.stings[#pending.stings + 1] = { at = now, guid = guid }
        end
    end

    --- The rotation gave up on a spell it reported castable: for a pending
    --- sting at an add, that is the "no".
    function M.on_stuck(name, now)
        if name ~= "Serpent Sting" or #pending.stings == 0 then return end
        table.remove(pending.stings, 1)
        answer("sting_add", false, "a sting at a mob not your target never went out (the rotation backed off)", now)
    end

    --- One of our controls appearing on an enemy player (UNIT_AURA "added",
    --- resolved by the picture): its duration, by its place in the chain.
    function M.on_control_aura(guid, name, duration, now)
        if not (lib.client and lib.client.forever) then return end
        if not (guid and CONTROLS[name]) then return end
        duration = tonumber(duration)
        if not duration or duration <= 0 then return end
        local key = guid .. "|" .. name
        local ch = chains[key]
        local step = 1
        if ch and now <= (ch.ends_at + KF.chain_window) then step = math.min(ch.step + 1, 4) end
        chains[key] = { step = step, ends_at = now + duration }
        local s = load()
        local byname = s.dr[name] or {}
        s.dr[name] = byname
        local slot = byname[tostring(step)] or { sum = 0, n = 0, min = duration, max = duration }
        byname[tostring(step)] = slot
        slot.sum, slot.n = slot.sum + duration, slot.n + 1
        slot.min, slot.max = math.min(slot.min, duration), math.max(slot.max, duration)
        dirty = true
    end

    -- --- the tick: the open jobs answered or timed out -------------------------------------

    function M.update(W, S, now)
        load()
        local list, n = rows(W)
        local by = {}
        for i = 1, n do local r = list[i]; if r and r.guid then by[r.guid] = r end end
        -- Traps: the effect on one of the mobs that stood in reach.
        for i = #pending.traps, 1, -1 do
            local p = pending.traps[i]
            local sprang = false
            for _, m in ipairs(p.near) do
                local names = aura_names(m.obj)
                if names then
                    for nm in pairs(names) do
                        if trap_effect(nm) then sprang = true break end
                    end
                end
                if sprang then break end
            end
            if sprang then
                answer("trap_in_melee", true, p.trap .. " laid in melee sprang", now)
                table.remove(pending.traps, i)
            elseif (now - p.at) >= KF.trap_window then
                answer("trap_in_melee", false, string.format("%s laid in melee: no trap effect on the mobs in reach within %.0f s", p.trap, KF.trap_window), now)
                table.remove(pending.traps, i)
            end
        end
        -- Disengage: the mob on you turns off you.
        for i = #pending.disengage, 1, -1 do
            local p = pending.disengage[i]
            local off = false
            for _, guid in ipairs(p.on) do
                local r = by[guid]
                if r and not r.targeting_me then off = true break end
            end
            if off then
                answer("disengage", true, "the mob turned off you", now)
                table.remove(pending.disengage, i)
            elseif (now - p.at) >= KF.disengage_window then
                answer("disengage", false, string.format("still on you %.0f s after Disengage", KF.disengage_window), now)
                table.remove(pending.disengage, i)
            end
        end
        -- A sting at an add with nothing heard either way: no answer.
        for i = #pending.stings, 1, -1 do
            if (now - pending.stings[i].at) > KF.sting_window * 4 then table.remove(pending.stings, i) end
        end
        -- Feign Death against a cast: the cast's own event, from the picture.
        for i = #pending.feign, 1, -1 do
            local p = pending.feign[i]
            local f = S and S.foes and S.foes[p.guid] or nil
            local done = nil
            for _, row in ipairs(f and f.recent or {}) do
                if row.at >= p.at and row.name == p.cast then
                    if row.kind == "cast" then done = false elseif row.kind == "interrupted" then done = true end
                end
            end
            if done ~= nil then
                answer("feign_cast", done, done and (p.cast .. " failed after Feign Death") or (p.cast .. " still landed after Feign Death"), now)
                table.remove(pending.feign, i)
            elseif now > p.until_at then
                table.remove(pending.feign, i)            -- nothing heard: no answer (see the enemy events line)
            end
        end
        if dirty and (now - saved_at) >= KF.save_every then save(now) end
    end

    --- The page's lines: each check's verdict, and the measured durations.
    function M.lines()
        local s = load()
        local out = {}
        local parts = {}
        for _, key in ipairs(ORDER) do parts[#parts + 1] = string.format("%s: %s", TEXT[key], verdict_of(s.checks[key])) end
        out[#out + 1] = "Field checks -- " .. table.concat(parts, "; ")
        local dr = {}
        for name, steps in pairs(s.dr) do
            local seq = {}
            for step = 1, 4 do
                local slot = steps[tostring(step)]
                if slot and slot.n > 0 then seq[#seq + 1] = string.format("#%d %.1fs (%d)", step, slot.sum / slot.n, slot.n) end
            end
            if #seq > 0 then dr[#dr + 1] = name .. " " .. table.concat(seq, ", ") end
        end
        table.sort(dr)
        out[#out + 1] = "Control durations on players (Forever): " .. (#dr > 0 and table.concat(dr, "; ") or "not seen yet")
        return out
    end

    function M.verdict(key) return verdict_of(load().checks[key]) end
    function M.flush(now) save(now or 0) end
    function M.reset()
        for _, list in pairs(pending) do for i = #list, 1, -1 do list[i] = nil end end
        for k in pairs(chains) do chains[k] = nil end
    end

    return M
end

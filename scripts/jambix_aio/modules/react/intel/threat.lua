-- Jambix AIO / react / intel / threat -- how much danger is coming, from
-- whom, and how sure that is (PvP intelligence, Stage 2 / brief Phase 4).
--
-- WHAT IT ANSWERS
-- detect.lua's danger says how much trouble we are in from the numbers we
-- can see on ourselves: health, its slope, how many are on us. A player
-- answers you, so most of the danger is in what it is ABOUT to do: the
-- burst it just popped, the sheep it is casting, the Charge it is in range
-- of, the gap closer it just used, the healer it turned to. This reads
-- those signs off W.intel (state.lua) and scores them on the same 0..100
-- scale, each sign a named INDICATOR with the points it is worth, the
-- seconds until it lands, how reliable the read is, and words.
--
--   S.threat.level      CRITICAL | HIGH | MODERATE | LOW | INFORMATIONAL,
--                       with two lines each and a dwell before stepping
--                       down (score.lua LEVELS, DWELL), never a flicker
--   S.threat.score      the point estimate
--   S.threat.low/high   the band: the score with every unknown against us
--                       at the top (score.lua UNKNOWN_WIDENS per unknown)
--   S.threat.worst      the level the top of the band would be
--   S.threat.reasons    the top indicators, points and words, for the readout
--   S.threat.by_foe     points per player; S.threat.highest the top indicator
--   S.threat.protection what a buff on us already covers (data.PROTECTION)
--   S.threat.unknown    what widened the band
--
-- WHAT IT DOES NOT DO: decide. No rule is here, nothing casts; Stage 4 and
-- Phase 13 read this. And it never reads missing information as safety: a
-- client that cannot measure damage widens the band and says so.
--
-- Every weight is in score.lua with its reason; nothing here is a literal.

return function(P, lib, data, K)
    local M = {}

    local huge, floor, min, max = math.huge, math.floor, math.min, math.max

    local T = {
        level = "INFORMATIONAL", score = 0, low = 0, high = 0, worst = "INFORMATIONAL",
        reasons = {}, list = {}, by_foe = {}, highest = nil, unknown = {},
        protection = { names = {}, physical = 0, spell = 0, melee = 0 },
        since = 0, changed = false, prev_level = nil, incoming_cast = false,
    }
    M.T = T

    local below_since = nil
    local pool, pool_n = {}, 0          -- indicator rows, reused

    local function urgency(tti)
        local U = K.URGENCY
        for i = 1, #U do
            if tti <= U[i].within then return U[i].factor end
        end
        return U[#U].factor
    end

    local function level_for(score)
        local L = K.LEVELS
        for i = 1, #L do
            if score >= L[i].enter then return L[i].name end
        end
        return "INFORMATIONAL"
    end

    local function level_row(name)
        for i = 1, #K.LEVELS do
            if K.LEVELS[i].name == name then return K.LEVELS[i] end
        end
        return K.LEVELS[#K.LEVELS]
    end

    --- One indicator: its base points, the seconds until it lands, how
    --- reliable the read is, a cover factor (0..1 already answered) and words.
    local function add(name, base, tti, rel, cover, why, guid)
        local raw = base * urgency(tti) * (1 - (cover or 0))
        if raw < 0.5 then return nil end
        pool_n = pool_n + 1
        local row = pool[pool_n]
        if not row then
            row = {}
            pool[pool_n] = row
        end
        row.name, row.base, row.tti, row.rel = name, base, tti, rel or 1
        row.raw, row.points = raw, raw * (rel or 1)
        row.why, row.guid = why, guid
        T.list[pool_n] = row
        return row
    end

    local function note_unknown(text)
        for i = 1, #T.unknown do
            if T.unknown[i] == text then return end
        end
        T.unknown[#T.unknown + 1] = text
    end

    -- --- what a buff on us already covers ----------------------------------------

    local function read_protection(S)
        local pr = T.protection
        for i = #pr.names, 1, -1 do pr.names[i] = nil end
        pr.physical, pr.spell, pr.melee = 0, 0, 0
        for name in pairs(S.me.buffs or {}) do
            local kind = data.PROTECTION[name]
            local covers = kind and data.COVERS[kind] or nil
            if covers then
                pr.names[#pr.names + 1] = name
                pr.physical = max(pr.physical, covers.physical or 0)
                pr.spell = max(pr.spell, covers.spell or 0)
                pr.melee = max(pr.melee, covers.melee or 0)
            end
        end
        return pr
    end

    local function covered_by(pr, kind)
        if kind == "physical" then return pr.physical end
        if kind == "spell" then return pr.spell end
        if kind == "melee" then return pr.melee end
        return 0
    end

    local function cover_text(pr, kind)
        local c = covered_by(pr, kind)
        if c <= 0 then return "" end
        return string.format(", %d%% covered by %s", floor(c * 100 + 0.5), table.concat(pr.names, " and "))
    end

    -- --- the read ---------------------------------------------------------------------

    ---@param W table the reactions' world
    ---@param S table the intel picture (state.lua)
    ---@param now number
    ---@return table T
    function M.update(W, S, now)
        -- Start the tick clean, reusing every row.
        for i = #T.list, 1, -1 do T.list[i] = nil end
        for k in pairs(T.by_foe) do T.by_foe[k] = nil end
        for i = #T.unknown, 1, -1 do T.unknown[i] = nil end
        for i = #T.reasons, 1, -1 do T.reasons[i] = nil end
        pool_n = 0
        T.highest, T.incoming_cast = nil, false
        T.prev_level = T.level
        T.changed = false

        local me = S.me
        local pr = read_protection(S)
        local forever = S.client.forever == true
        local damage_rel = forever and K.RELIABILITY.forever_damage or K.RELIABILITY.observed
        if forever then
            note_unknown("incoming damage is read from your own health drop (Forever sends the combat log empty)")
        end
        local melee_range = S.env.melee_range or 5

        if S.active then
            -- --- each player --------------------------------------------------------
            for i = 1, #S.foe_list do
                local f = S.foe_list[i]
                local role, role_conf = f.inferred.role.v, f.inferred.role.conf
                local role_rel = (f.class ~= nil) and K.RELIABILITY.observed or K.RELIABILITY.role_unknown
                if f.class == nil and (f.targets_me or f.in_combat) then
                    note_unknown("a player's class is not named by the client: its reach and role are guessed")
                end
                local fighting = f.targets_me or f.targets_pet or f.in_combat or S.mode.kind == "bg"
                    or S.mode.kind == "arena" or S.mode.kind == "duel"

                -- A burst cooldown up, on you.
                if f.targets_me and f.st and f.st.burst then
                    local kind = f.st.burst
                    add("burst_on_me", K.BASE.burst_on_me, 0, 1, covered_by(pr, kind),
                        string.format("%s bursting on you (%s%s)", f.name, tostring(f.st.burst_name), cover_text(pr, kind)), f.guid)
                end

                -- A dangerous cast, at you or at an ally.
                local c = f.casting
                if c and (c.danger or 0) > 0 then
                    local by_danger = min(1, (c.danger or 0) / 45)
                    local cover = (c.kind == "damage") and covered_by(pr, "spell") or 0
                    if c.at_me then
                        local row = add("cast_at_me", K.BASE.cast_at_me + K.BASE.cast_at_me_by_danger * by_danger,
                            c.left or 0, 1, cover,
                            string.format("%s casting %s at you (%.1fs%s)", f.name, tostring(c.name), c.left or 0, cover_text(pr, "spell")), f.guid)
                        if row then T.incoming_cast = true end
                    elseif f.targets_ally then
                        local ally = S.allies[f.target_guid]
                        local vulnerable = ally ~= nil and (ally.healer or (ally.hp or 1) < 0.5)
                        local base = (K.BASE.cast_at_ally + K.BASE.cast_at_ally_by_danger * by_danger)
                            * (vulnerable and K.BASE.cast_at_ally_vulnerable or 1)
                        add("cast_at_ally", base, c.left or 0, 1, 0,
                            string.format("%s casting %s at %s%s", f.name, tostring(c.name), ally and ally.name or "an ally",
                                vulnerable and (ally.healer and " (the healer)" or " (hurt)") or ""), f.guid)
                    end
                end

                -- A melee player about to reach you.
                if fighting and role == "melee" and f.dist > melee_range and (f.time_to_reach or huge) <= K.CLOSING_WITHIN then
                    add("melee_closing", K.BASE.melee_closing, f.time_to_reach, role_rel * max(role_conf, 0.5), covered_by(pr, "melee"),
                        string.format("%s closing, %.1fs to reach you%s", f.name, f.time_to_reach, cover_text(pr, "melee")), f.guid)
                end

                -- Inside the reach of a control its class throws.
                local controls = fighting and f.class and data.CONTROLS[f.class] or nil
                if controls then
                    local best, best_w = nil, 0
                    for k = 1, #controls do
                        local ctl = controls[k]
                        if f.dist <= ctl.reach and (not ctl.from or f.dist >= ctl.from) then
                            local w = data.CONTROL_WEIGHT[ctl.kind] or 0.5
                            if w > best_w then best, best_w = ctl, w end
                        end
                    end
                    if best then
                        add("in_control_reach", K.BASE.in_control_reach * best_w, 0, role_rel, 0,
                            string.format("%s within %s reach (%.0f of %d yd)", f.name, best.name, f.dist, best.reach), f.guid)
                    end
                end

                -- Targeting an ally.
                if f.targets_ally then
                    local ally = S.allies[f.target_guid]
                    local vulnerable = ally ~= nil and (ally.healer or (ally.hp or 1) < 0.5)
                    add("ally_targeted", vulnerable and K.BASE.ally_targeted_vulnerable or K.BASE.ally_targeted, 0, 1, 0,
                        string.format("%s on %s%s", f.name, ally and ally.name or "an ally",
                            vulnerable and (ally.healer and " (the healer)" or " (hurt)") or ""), f.guid)
                end

                -- A gap closer or a sprint just used.
                local recent = f.recent
                for k = #recent, 1, -1 do
                    local r = recent[k]
                    if (now - r.at) > K.MOBILITY_HOLD then break end
                    local mob = data.MOBILITY[r.name]
                    if mob then
                        if fighting or f.targets_me then
                            add("mobility_used", K.BASE.mobility_used, 0.5, 1, 0,
                                string.format("%s used %s %.1fs ago", f.name, r.name, now - r.at), f.guid)
                        end
                        break
                    end
                end
            end

            -- --- you ------------------------------------------------------------------
            if S.attackers > 1 then
                add("extra_attackers", min((S.attackers - 1) * K.BASE.extra_attacker, K.BASE.extra_attackers_max), 0, 1, 0,
                    string.format("%d players on you", S.attackers))
            end

            local held = me.root or me.snare or (me.control and me.control.kind == "root")
            if held then
                local melee_near = S.melee_attackers > 0
                if not melee_near then
                    for i = 1, #S.foe_list do
                        local f = S.foe_list[i]
                        if f.inferred.role.v == "melee" and (f.time_to_reach or huge) <= 3.0 and (f.targets_me or f.in_combat) then
                            melee_near = true
                            break
                        end
                    end
                end
                if melee_near then
                    add("rooted_threatened", K.BASE.rooted_threatened, 0, 1, 0,
                        string.format("%s (%s) with a melee player on you", held.kind, held.name or ""))
                end
            end

            if S.melee_attackers > 0 and (me.escapes_ready or 0) == 0 then
                add("escapes_gone", K.BASE.escapes_gone, 0, 1, 0,
                    (me.escapes_known or 0) == 0 and "no escape in your book, a melee player on you"
                        or "no escape ready, a melee player on you")
            end

            local ttl = W.player.ttl or huge
            if ttl < K.BASE.lethal_within then
                add("lethal", K.BASE.lethal * (K.BASE.lethal_within - ttl) / K.BASE.lethal_within, ttl, damage_rel, 0,
                    string.format("%.0fs to live at this rate%s", ttl, forever and " (read from your health)" or ""))
            end
            if me.hp < K.BASE.low_line and (S.attackers > 0 or (W.player.damage_recent or 0) > 0) then
                add("low_and_hit", K.BASE.low_and_hit, 0, 1, 0, string.format("%d%% and being hit", floor(me.hp * 100 + 0.5)))
            end

            local V = W.pvp
            if V and V.vanished then
                add("vanished", K.BASE.vanished, 1.0, 1, 0, "a player vanished beside you")
                note_unknown("where the vanished player is")
            end
        end

        -- --- the sum ---------------------------------------------------------------------
        local hp_factor = K.HEALTH_FLOOR + K.HEALTH_RANGE * (1 - min(1, max(0, me.hp or 1)))
        local answers = ((me.defensives_ready or 0) > 0) or ((me.escapes_ready or 0) > 0)
        local scale = hp_factor * ((not answers and S.attackers > 0) and K.NO_ANSWERS or 1)
        local sum_points, sum_raw = 0, 0
        for i = 1, #T.list do
            local row = T.list[i]
            row.points = row.points * scale
            row.raw = row.raw * scale
            sum_points = sum_points + row.points
            sum_raw = sum_raw + row.raw
            if row.guid then T.by_foe[row.guid] = (T.by_foe[row.guid] or 0) + row.points end
        end
        T.score = min(100, sum_points)
        T.low = T.score
        T.high = min(100, sum_raw + K.UNKNOWN_WIDENS * #T.unknown * (S.active and 1 or 0))
        T.hp_factor, T.scale = hp_factor, scale

        -- The top indicators, by points.
        table.sort(T.list, function(a, b) return a.points > b.points end)
        for i = 1, min(4, #T.list) do
            T.reasons[i] = T.list[i]
        end
        T.highest = T.list[1]

        -- --- the level, with its two lines and its dwell ----------------------------------
        local want = level_for(T.score)
        local rank = K.RANK
        if rank[want] > rank[T.level] then
            T.level, T.since, below_since = want, now, nil
        elseif rank[want] < rank[T.level] then
            local row = level_row(T.level)
            if T.score <= row.exit then
                below_since = below_since or now
                if (now - below_since) >= K.DWELL then
                    T.level, T.since, below_since = want, now, nil
                end
            else
                below_since = nil
            end
        else
            below_since = nil
        end
        T.worst = level_for(T.high)
        if rank[T.worst] < rank[T.level] then T.worst = T.level end
        T.changed = T.level ~= T.prev_level
        T.at = now
        return T
    end

    function M.reset()
        T.level, T.score, T.low, T.high, T.worst = "INFORMATIONAL", 0, 0, 0, "INFORMATIONAL"
        for i = #T.list, 1, -1 do T.list[i] = nil end
        for i = #T.reasons, 1, -1 do T.reasons[i] = nil end
        for k in pairs(T.by_foe) do T.by_foe[k] = nil end
        T.highest, T.incoming_cast, below_since = nil, false, nil
    end

    --- "threat HIGH 62 (Enemy bursting on you (Recklessness) +35, 2 players on you +10) band 62-74"
    function M.line()
        local parts = { string.format("threat %s %d", T.level, floor(T.score + 0.5)) }
        if #T.reasons > 0 then
            local words = {}
            for i = 1, #T.reasons do
                words[i] = string.format("%s +%d", T.reasons[i].why, floor(T.reasons[i].points + 0.5))
            end
            parts[1] = parts[1] .. " (" .. table.concat(words, "; ") .. ")"
        end
        if T.high > T.score + 0.5 then
            parts[#parts + 1] = string.format("up to %d if %s", floor(T.high + 0.5),
                #T.unknown > 0 and "the unknowns go against you" or "every read is right")
        end
        if #T.protection.names > 0 then
            parts[#parts + 1] = "covered: " .. table.concat(T.protection.names, ", ")
        end
        return table.concat(parts, " | ")
    end

    return M
end

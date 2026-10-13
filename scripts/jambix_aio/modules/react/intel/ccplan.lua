-- Jambix AIO / react / intel / ccplan -- the control plan (PvP intelligence,
-- Stage 6 / brief Phase 8): every control on every enemy player, whose it
-- is, what breaks it, who of ours could break it, its diminishing returns,
-- what keeping it is worth, and the one thing to hold.
--
-- OBSERVED   the control on a player (JCore's row: Era's loss-of-control
--            read, Forever's debuff read), its name and the seconds left;
--            an aura's caster where the index carries one (pvphunter.held);
--            the pet's target; our own damage over time on it (the aura
--            index, by name); each control landing (the UNIT_AURA event or
--            the row), counted per category.
-- INFERRED   whose a control is when the aura has no caster field (JCore's
--            aura_is_mine fails open the same way: "yours" at
--            score.lua CC.unknown_caster_conf); what keeping it is worth,
--            from the picture's facts; on Era, what the next control gets
--            (DRList's rule on the observed count, CC.era_conf).
-- UNKNOWN    on Forever, the multiplier: the client's table gives each
--            spell's category (DiminishType) and the count is observed,
--            but whether and how Forever halves is unverified, so the plan
--            never claims a halved duration there; an ally's damage about
--            to break a control (no read); a control whose name no table
--            carries (no category, no count).
--
-- Nothing here presses or recalls. The hold goes out as a reaction
-- (rules/intel.lua "Intel: keep the control on your target", kind hold,
-- through the one engine); the pet's recall is pet.lua's own (1.8.1, "the
-- pet kept off crowd control"), and this plan says the reason for it
-- (S.cc.pet). The hunter's trap rules ask M.next for the diminishing
-- returns (classes/hunter.lua trap_first, rules/hunter_pvp.lua dr).

return function(P, lib, data, K)
    local units = P.units
    local book = P.spellbook
    local floor, max, min, huge = math.floor, math.max, math.min, math.huge
    local KC = K.CC

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

    --- The module's switch (the Reactions page, *Crowd control planning*).
    function M.enabled() return opt("intel_cc", true) == true end

    local forever = lib.client ~= nil and lib.client.forever == true
    local cds = lib.cooldowns

    -- The names pvphunter's kinds stand for.
    local OURS_NAME = { trap = "Freezing Trap Effect", scatter = "Scatter Shot", sting = "Wyvern Sting" }

    --- An inferred entry { v, conf, why } read only when it is this sure.
    local function sure(x, threshold)
        if type(x) ~= "table" or x.v == nil then return nil, 0 end
        if (x.conf or 0) < (threshold or 0) then return nil, x.conf or 0 end
        return x.v, x.conf or 0
    end

    -- --- the categories ---------------------------------------------------------------

    --- The diminishing-returns category of a control, by its name: on
    --- Forever the client's own table first (SpellCategories.DiminishType,
    --- pvp_data.lua), on Era DRList's list (data.DR_ERA); a name Forever's
    --- table lacks (an effect aura such as "Freezing Trap Effect") takes
    --- Era's list at a lower confidence.
    ---@param name string
    ---@return string|nil category
    ---@return number conf
    ---@return string source
    function M.category(name)
        if type(name) ~= "string" or name == "" then return nil, 0, "no name" end
        if forever and cds and cds.has_data then
            local row = cds.fact(name)
            local id = row and tonumber(row.diminish) or nil
            if id and id > 0 then
                local cat = data.DR_FOREVER_TYPES[id]
                if cat then return cat, KC.forever_table_conf, "the client's table" end
                return "type " .. tostring(id), KC.forever_table_conf, "the client's table (an id this plugin has no name for)"
            end
        end
        local cat = data.DR_ERA[name]
        if cat then
            if forever then return cat, KC.forever_era_fallback_conf, "Era's list, unverified on Forever" end
            return cat, KC.era_conf, "DRList's Classic Era list"
        end
        return nil, 0, "no table carries it"
    end

    --- What a control gets after `count` of its category in the window:
    --- Era, DRList's rule; Forever, what the field checks measured (Stage
    --- 14: each of your controls' durations by its place in a chain, the
    --- ratio to the first, snapped to full / half / quarter), else UNKNOWN.
    --- A first control in a window is full on every client.
    ---@param count integer
    ---@param category? string
    ---@return number|nil mult 1, 0.5, 0.25, 0; nil when unknown
    ---@return string level full, half, quarter, immune, unknown
    function M.next_of(count, category)
        local n = min(max(count or 0, 0), 3)
        if forever then
            if n == 0 then return 1, "full" end
            local fc = lib.fieldcheck
            local ratio, behind = nil, 0
            if fc and fc.dr_ratio then
                ratio, behind = fc.dr_ratio(n + 1, category and function(name) return (M.category(name)) == category end or nil)
            end
            if not ratio then return nil, "unknown" end
            if ratio >= 0.75 then return 1, string.format("full (measured, %d)", behind) end
            if ratio >= 0.375 then return 0.5, string.format("half (measured, %d)", behind) end
            return 0.25, string.format("quarter (measured, %d)", behind)
        end
        return KC.dr_mult[n], KC.dr_level[n]
    end

    --- What the next control of a category gets on a player.
    ---@param S table the picture
    ---@param guid string|nil
    ---@param category string
    ---@return number|nil mult
    ---@return string level
    ---@return integer count
    ---@return number conf
    function M.next(S, guid, category)
        local f = guid and S and S.foes and S.foes[guid] or nil
        local c = f and f.cc or nil
        local d = c and c.dr[category] or nil
        local count = d and d.count or 0
        if d and (S.now or 0) > d.reset_at then count = 0 end
        local mult, level = M.next_of(count, category)
        return mult, level, count, d and d.conf or 0
    end

    -- --- the plan, per player ------------------------------------------------------

    local function plan_of(f)
        local c = f.cc
        if not c then
            c = { held = nil, held_row = nil, held_name_seen = nil, dr = {}, scan_at = -huge,
                  breakers = {}, dots = {}, pet_on = false,
                  value = { kind = "none", why = "", conf = 0 }, chain = nil,
                  next_level = "full", next_mult = 1 }
            f.cc = c
        end
        return c
    end

    --- One control landing on a player, counted for its category.
    local function note_control(c, cat, name, at, duration, conf, source)
        local d = c.dr[cat]
        if not d then
            d = { count = 0, last_at = -huge, ends_at = -huge, reset_at = -huge, name = nil, conf = conf, source = source }
            c.dr[cat] = d
        end
        -- The same landing twice (the aura event and the row read): one.
        if (at - d.last_at) <= KC.dedupe and (at - d.last_at) >= 0 then
            if at + duration > d.ends_at then
                d.ends_at = at + duration
                d.reset_at = d.ends_at + KC.dr_window
            end
            return d
        end
        -- The window ran out: a new chain. One that lands where the rule
        -- said immune means the server had reset already: a new chain too.
        if d.count > 0 and at > d.reset_at then d.count = 0 end
        if not forever and d.count >= 3 then d.count = 0 end
        d.count = d.count + 1
        d.last_at, d.name = at, name
        d.ends_at = at + duration
        d.reset_at = d.ends_at + KC.dr_window
        d.conf, d.source = conf, source
        return d
    end

    --- The aura events the state kept (UNIT_AURA "added" on the player):
    --- each control among them lands once.
    local function scan_recent(f, c)
        local list = f.recent or {}
        local newest = c.scan_at
        for i = 1, #list do
            local row = list[i]
            if row.at > c.scan_at and row.kind == "debuff" then
                local cat, conf, source = M.category(row.name)
                if cat then
                    local fact = cds and cds.fact and cds.fact(row.name) or nil
                    local dur = fact and tonumber(fact.duration) or nil
                    if not dur or dur <= 0 then dur = KC.duration_guess end
                    note_control(c, cat, row.name, row.at, min(dur, KC.duration_cap), conf, source .. " (UNIT_AURA)")
                end
            end
            if row.at > newest then newest = row.at end
        end
        c.scan_at = newest
    end

    --- Whose an aura is: "yes" (its caster is us), "other", or "unknown"
    --- (no caster field, or one that gives no guid).
    local function caster_of(aura)
        local ph = P.pvphunter
        if ph and ph.caster_of then
            local ok, who = pcall(ph.caster_of, aura)
            if ok and who then return who end
        end
        return "unknown"
    end

    --- The control on the player: the row's (any caster), and ours through
    --- pvphunter.held (the aura's caster).
    local function read_held(f, c, now)
        local ctl = f.control
        local held = nil
        if ctl then
            local h = c.held_row or {}
            c.held_row = h
            h.kind, h.name, h.left = ctl.kind or "control", ctl.name or "", tonumber(ctl.left) or 0
            h.breaks, h.source = ctl.breaks == true, ctl.source
            h.category, h.category_conf, h.category_source = M.category(h.name)
            held = h
        end
        local kind, left, who = nil, 0, nil
        local ph = P.pvphunter
        if ph and ph.held and f.unit then
            local ok, k, l, w = pcall(ph.held, f.unit)
            if ok and k then kind, left, who = k, l or 0, w or "unknown" end
        end
        if held then
            if kind then
                held.ours = (who == "yes") and "yes" or "unknown"
                held.ours_conf = (who == "yes") and 1.0 or KC.unknown_caster_conf
                held.ours_kind = kind
            else
                held.ours, held.ours_conf, held.ours_kind = "no", 1.0, nil
            end
        elseif kind then
            -- The row said nothing (Era's loss-of-control read on a player
            -- it cannot query); our own aura read stands in.
            local h = c.held_row or {}
            c.held_row = h
            h.kind, h.name, h.left, h.breaks, h.source = "incapacitate", OURS_NAME[kind] or kind, left, true, "aura (ours)"
            h.category, h.category_conf, h.category_source = M.category(h.name)
            h.ours = (who == "yes") and "yes" or "unknown"
            h.ours_conf = (who == "yes") and 1.0 or KC.unknown_caster_conf
            h.ours_kind = kind
            held = h
        end
        c.held = held
        -- A control newly on it counts for its category, with the seconds
        -- left the row observed.
        if held and held.category and held.name ~= c.held_name_seen then
            c.held_name_seen = held.name
            note_control(c, held.category, held.name, now, max(held.left or 0, 0), held.category_conf,
                (held.category_source or "") .. " (row)")
        elseif not held then
            c.held_name_seen = nil
        end
        for _, d in pairs(c.dr) do
            if now > d.reset_at then d.count = 0 end
        end
        -- What the next one of the held category (or, for a hunter, the next
        -- incapacitate) gets.
        local cat = (held and held.category) or "incapacitate"
        c.next_mult, c.next_level = M.next(nil, nil, cat)
        local d = c.dr[cat]
        if d then c.next_mult, c.next_level = M.next_of(now > d.reset_at and 0 or d.count, cat) end
    end

    --- What the player could break the control with: its trinket as
    --- pvp.lua saw it, its class's breakers as the ledger saw them.
    local function read_breakers(S, f, c)
        local b = c.breakers
        for i = #b, 1, -1 do b[i] = nil end
        if not c.held then return end
        local st = f.st
        if st then
            if st.trinket_down then
                b[#b + 1] = string.format("trinket down, back in %.0fs", st.trinket_back or 0)
            else
                b[#b + 1] = "trinket: never seen used (ready, or none)"
            end
        end
        local mech = c.held.kind
        local list = f.class and data.BREAKERS[f.class] or nil
        for i = 1, #(list or {}) do
            local e = list[i]
            if e.mechs[mech] or e.mechs.magic then
                local seen = cds and cds.seen and cds.seen(S, f.guid, e.name) or nil
                if seen and seen.state == "down" then
                    b[#b + 1] = string.format("%s down, back in %.0fs", e.name, seen.ready_in or 0)
                else
                    b[#b + 1] = e.name .. " (ready, or never seen)"
                end
            end
        end
    end

    --- Our own damage over time on the player: the control ends at its
    --- next tick, whatever we hold.
    local function read_dots(f, c)
        local d = c.dots
        for i = #d, 1, -1 do d[i] = nil end
        if not (c.held and f.unit and units.aura_index) then return end
        local index = try(units.aura_index, f.unit)
        if type(index) ~= "table" then return end
        for _, aura in pairs(index) do
            local name = type(aura) == "table" and aura.buff_name or nil
            if name and data.OUR_DOTS[name] then
                local who = caster_of(aura)
                if who ~= "other" then d[#d + 1] = name .. (who == "yes" and "" or " (caster unread)") end
            end
        end
        table.sort(d)
    end

    local function read_pet(S, f, c)
        c.pet_on = S.pet.alive == true and S.pet.target_guid ~= nil and S.pet.target_guid == f.guid
    end

    --- What keeping the control is worth, from the picture's facts, in the
    --- order a fight asks them.
    local function read_value(S, f, c, now)
        local v = c.value
        local h = c.held
        if not h then v.kind, v.why, v.conf = "none", "", 0 return end
        local me = S.me
        if f.targets_me and (me.hp or 1) <= KC.survive_hp then
            v.kind, v.why = "survive", string.format("it was on you at %d%% health", floor((me.hp or 0) * 100 + 0.5))
            v.conf = 0.9
            return
        end
        local inf = f.inferred or {}
        local is_healer, hconf = sure(inf.healer, 0.6)
        if is_healer == true then
            v.kind, v.why, v.conf = "stop_heal", "it heals (" .. tostring(inf.healer.why or "seen healing") .. ")", hconf
            return
        end
        if f.st and f.st.burst then
            v.kind, v.why, v.conf = "stop_burst", "its " .. tostring(f.st.burst_name or "burst") .. " is up", 0.9
            return
        end
        for _, o in pairs(S.foes) do
            if o ~= f and not o.dead and (o.hp or 1) <= KC.kill_hp and (now - (o.at or -huge)) < 2 then
                v.kind, v.why = "kill", string.format("%s is at %d%%: finish it while this one is held", o.name, floor((o.hp or 0) * 100 + 0.5))
                v.conf = 0.8
                return
            end
        end
        if f.targets_ally then v.kind, v.why, v.conf = "peel", "it was on an ally", 0.8 return end
        local role = sure(inf.role, 0.5)
        if role == "melee" or (S.melee_attackers or 0) > 0 then
            v.kind, v.why, v.conf = "distance", "a melee player held: the range is yours to take", 0.7
            return
        end
        local KT = K.TACTIC
        if (me.hp or 1) <= KT.recover_hp or (me.power_counted and (me.power_pct or 1) <= KT.recover_power) then
            v.kind, v.why, v.conf = "reset", "you are low: drink, bandage, reset", 0.7
            return
        end
        v.kind, v.why, v.conf = "none", "nothing to gain by waiting on it", 0.6
    end

    --- The control to follow with: the trap under a scattered player.
    local function read_chain(f, c)
        c.chain = nil
        local h = c.held
        if not (h and h.ours_kind == "scatter") then return end
        if not (book.known("Freezing Trap") and book.ready("Freezing Trap")) then return end
        if c.next_mult == 0 then
            c.chain = { name = "Freezing Trap", ok = false, why = "immune to incapacitates for now" }
        elseif c.next_mult == nil then
            c.chain = { name = "Freezing Trap", ok = true, why = "lay it under the scattered player (diminishing returns unknown here)" }
        else
            c.chain = { name = "Freezing Trap", ok = true, why = string.format("lay it under the scattered player (%s)", c.next_level) }
        end
    end

    -- --- the tick --------------------------------------------------------------------

    local T = {
        target = nil, hold = nil, doomed = nil,
        held_n = 0, ours_n = 0,
        pet = { recall = false, guid = nil, name = nil, why = "" },
        dr_rule = "", unknown = {},
    }
    M.T = T

    function M.update(W, S, now)
        T.held_n, T.ours_n = 0, 0
        T.pet.recall, T.pet.guid, T.pet.name, T.pet.why = false, nil, nil, ""
        T.target, T.hold, T.doomed = nil, nil, nil
        for i = #T.unknown, 1, -1 do T.unknown[i] = nil end
        T.dr_rule = forever and "Forever: counts observed; the multiplier from your controls' measured durations where enough are measured, else unknown" or "DRList's Classic Era rule"
        if not S.active then return T end
        for _, f in pairs(S.foes) do
            local c = plan_of(f)
            scan_recent(f, c)
            read_held(f, c, now)
            read_breakers(S, f, c)
            read_dots(f, c)
            read_pet(S, f, c)
            read_value(S, f, c, now)
            read_chain(f, c)
            if c.held and c.held.breaks then
                T.held_n = T.held_n + 1
                if c.held.ours ~= "no" then T.ours_n = T.ours_n + 1 end
                if c.pet_on and (c.held.left or 0) > 0.3 and not T.pet.recall then
                    T.pet.recall, T.pet.guid, T.pet.name = true, f.guid, f.name
                    T.pet.why = string.format("the pet is on %s, held by %s (%.1fs): its next bite breaks it",
                        f.name, c.held.name, c.held.left or 0)
                end
            end
        end
        local tg = S.env.target.guid and S.foes[S.env.target.guid] or nil
        local c = tg and tg.cc or nil
        T.target = c
        if c and c.held and c.held.breaks and (c.held.left or 0) >= KC.hold_min_left then
            local h = c.held
            if #c.dots > 0 then
                T.doomed = { guid = tg.guid, name = h.name,
                             why = c.dots[1] .. " of yours ticks on it: the control ends at its next tick" }
            elseif c.value.kind ~= "none" or (c.chain and c.chain.ok) then
                local whose = h.ours == "yes" and "yours" or h.ours == "unknown" and "yours, caster unread" or "not yours"
                local reason = c.value.kind ~= "none" and c.value.why or c.chain.why
                T.hold = {
                    guid = tg.guid, name = h.name, value = c.value.kind, left = h.left,
                    conf = min(c.value.kind ~= "none" and c.value.conf or 0.6, h.ours_conf or 1),
                    why = string.format("%s on %s, %.1fs left (%s): %s", h.name, tg.name, h.left or 0, whose, reason),
                }
            end
        end
        if T.held_n > 0 then T.unknown[#T.unknown + 1] = "an ally's damage about to break a control (no read)" end
        return T
    end

    function M.reset()
        T.target, T.hold, T.doomed = nil, nil, nil
        T.held_n, T.ours_n = 0, 0
        T.pet.recall, T.pet.guid, T.pet.name, T.pet.why = false, nil, nil, ""
        for i = #T.unknown, 1, -1 do T.unknown[i] = nil end
    end

    --- The readout's piece.
    ---@return string|nil
    function M.line(S)
        if T.held_n == 0 and not T.hold and not T.doomed then return nil end
        local parts = {}
        if T.hold then
            parts[#parts + 1] = "hold: " .. T.hold.why
        elseif T.doomed then
            parts[#parts + 1] = "no hold: " .. T.doomed.why
        elseif T.target and T.target.held then
            local h = T.target.held
            parts[#parts + 1] = string.format("%s on the target, %.1fs (%s)", h.name, h.left or 0,
                h.ours == "yes" and "yours" or h.ours == "unknown" and "yours?" or "not yours")
        else
            parts[#parts + 1] = string.format("%d player(s) held", T.held_n)
        end
        if T.target and T.target.held and T.target.held.category then
            local cat = T.target.held.category
            local d = T.target.dr[cat]
            if d then parts[#parts + 1] = string.format("DR %s x%d -> %s", cat, d.count, T.target.next_level or "?") end
        end
        if T.pet.recall then parts[#parts + 1] = "pet: off " .. tostring(T.pet.name) end
        return "CC " .. table.concat(parts, "; ")
    end

    return M
end

-- Jambix AIO / pvpmarks -- the enemy players, marked on the ground (1.87.0).
--
-- The user, 2026-10-08, choosing what the curtains and rings should do next:
-- "PvP: Kill target, Enemy healer, CC and trinket timers".
--
--   KILL TARGET   the enemy player in reach (40 yd, a setting) lowest on
--                 health: a red curtain round it, and a pulse when the pick
--                 changes. A pick holds until another is 5% lower, so two
--                 players trading the lowest spot do not flicker. The dead
--                 and the immune to everything (Divine Shield, Ice Block)
--                 are never picked.
--   ENEMY HEALER  a green curtain round each enemy player seen healing in
--                 the last 20 s: casting a heal, or the caster of a Renew,
--                 Rejuvenation or Regrowth on one of them. Era's role guess
--                 is only the class, so it is read from what they do.
--   CC TIMERS     your crowd control on an enemy player (or your pet's: a
--                 Seduction), a purple ring under it emptying as it runs out.
--   TRINKET       their PvP trinket, from the reactions' pvp.lua: a grey
--                 ring filling back up while it is on cooldown, a thin gold
--                 one once it is back.
--
-- Nothing is drawn without an enemy player within 40 yd, so nothing in PvE.
-- Auras are read off the nearest six players, five times a second each.
-- A crowd control's full length is not read: the client's duration field
-- is unproven, so a ring empties from what was left the first time it was
-- seen (as timers.lua does). A trinket's cooldown is not read either:
-- pvp.lua says how long until it is back, and a wait over 120 s means a
-- 300 s Insignia, else the 120 s PvP Trinket.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min = math.floor, math.max, math.min

    local M = {}

    local REACH = 40             -- yards: pvp.lua's, an enemy player this close is in the fight
    local READ_EVERY = 0.2       -- seconds between aura reads per player
    local LOOK = 6               -- players whose auras are read, nearest first
    local HEALER_KEEP = 20       -- seconds a heal makes a healer
    local STICK = 0.05           -- health: how much lower another must be to take the kill pick
    local CC_RINGS = 3           -- at most this many control rings per player
    local GAP = 0.45             -- yards between rings
    local PERMANENT = 600        -- seconds: longer is not a timer
    local CD_SHORT, CD_LONG = 120, 300  -- the PvP Trinket's and an Insignia's cooldown

    local function clock() return core.time() end
    local function game_ms()
        local ok, v = pcall(core.game_time)
        return ok and tonumber(v) or 0
    end
    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end

    local C = {
        band = color(0, 0, 0, 110),
        kill = color(240, 70, 60), kill_top = color(240, 70, 60, 30), kill_pulse = color(250, 120, 90, 230),
        healer = color(100, 220, 130), healer_top = color(100, 220, 130, 30),
        cc = color(170, 120, 250),
        trinket_down = color(150, 150, 158), trinket_band = color(0, 0, 0, 70),
        trinket_ready = color(245, 190, 60, 200),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function pvp() return P.react and P.react.pvp end

    local function guid_of(obj)
        if not obj then return nil end
        return (units.guid and ask(units.guid, obj)) or ask(obj.get_guid, obj)
    end

    -- --- spell names ------------------------------------------------------------

    local names = {}             -- spell id -> name
    local function spell_name(id)
        id = tonumber(id)
        if not id then return nil end
        local n = names[id]
        if n then return n end
        local spells = ctx and ctx.spells
        n = spells and ask(spells.name, id)
        if type(n) ~= "string" or n == "" then
            local book = core.spell_book
            n = book and ask(book.get_spell_name, id)
        end
        if type(n) ~= "string" or n == "" then return nil end
        names[id] = n
        return n
    end

    -- --- what a heal is ----------------------------------------------------------
    --
    -- Classic's heals by name. The reactions' detect.lua also calls a cast a
    -- heal from its name ("heal", "renew", "prayer of"), which catches a
    -- name missed here but also Create Healthstone, Health Funnel and Mend
    -- Pet, none of which make a healer.

    local HEALS = {
        ["Heal"] = true, ["Greater Heal"] = true, ["Flash Heal"] = true, ["Lesser Heal"] = true,
        ["Renew"] = true, ["Prayer of Healing"] = true, ["Holy Light"] = true, ["Flash of Light"] = true,
        ["Healing Wave"] = true, ["Lesser Healing Wave"] = true, ["Chain Heal"] = true,
        ["Healing Touch"] = true, ["Regrowth"] = true, ["Rejuvenation"] = true, ["Tranquility"] = true,
    }
    -- A heal over time left on a player: whoever cast it heals.
    local HOTS = { ["Renew"] = true, ["Rejuvenation"] = true, ["Regrowth"] = true }
    local NOT_HEALS = { ["Mend Pet"] = true }

    local heal_cache = {}
    local function is_heal(name)
        if type(name) ~= "string" or name == "" then return false end
        local hit = heal_cache[name]
        if hit ~= nil then return hit end
        local yes = HEALS[name] == true
        local detect = P.react and P.react.detect
        if not yes and not NOT_HEALS[name] and detect and type(detect.cast_danger) == "function" then
            local ok, _, kind = pcall(detect.cast_danger, name)
            yes = ok and kind == "heal" and not name:lower():find("health", 1, true)
        end
        heal_cache[name] = yes
        return yes
    end

    -- --- what crowd control is ---------------------------------------------------
    --
    -- pvp.lua's tables, from the Era client's own data: its CONTROL (debuffs
    -- by name, with the mechanic) and SPELL_MECH (our spells by mechanic). A
    -- snare is no crowd control. Without the reactions, a short list.

    local FALLBACK_CC = {
        ["Polymorph"] = true, ["Polymorph: Pig"] = true, ["Polymorph: Turtle"] = true, ["Sap"] = true,
        ["Gouge"] = true, ["Blind"] = true, ["Fear"] = true, ["Psychic Scream"] = true,
        ["Howl of Terror"] = true, ["Hammer of Justice"] = true, ["Kidney Shot"] = true,
        ["Cheap Shot"] = true, ["Freezing Trap"] = true, ["Freezing Trap Effect"] = true,
        ["Scatter Shot"] = true, ["Hibernate"] = true, ["Entangling Roots"] = true, ["Frost Nova"] = true,
        ["Seduction"] = true, ["Intimidating Shout"] = true, ["Concussion Blow"] = true, ["Repentance"] = true,
    }

    local cc_cache = {}
    local function is_cc(name)
        if type(name) ~= "string" or name == "" then return false end
        local hit = cc_cache[name]
        if hit ~= nil then return hit end
        local yes = false
        local p = pvp()
        local control, by_spell = p and p.CONTROL, p and p.SPELL_MECH
        if type(control) == "table" or type(by_spell) == "table" then
            local row = type(control) == "table" and control[name] or nil
            local mech = (type(row) == "table" and row.mech) or (type(by_spell) == "table" and by_spell[name]) or nil
            yes = mech ~= nil and mech ~= "snare"
        else
            yes = FALLBACK_CC[name] == true
        end
        cc_cache[name] = yes
        return yes
    end

    -- --- each enemy player -------------------------------------------------------

    local looks = {}             -- guid -> { at, seen, cc, immune, down, back, cd }
    local healer_at = {}         -- guid -> when it was last seen healing
    local swept_at = -1e9
    local my_guid, pet_guid = nil, nil

    local function look_for(guid, now)
        local l = looks[guid]
        if not l then
            l = { at = -1e9, cc = {} }
            looks[guid] = l
        end
        l.seen = now
        return l
    end

    local function is_player(r)
        local snap = units.snapshot and ask(units.snapshot, r.obj)
        if type(snap) == "table" and snap.is_player ~= nil then return snap.is_player == true end
        local p = pvp()
        if p and type(p.is_player) == "function" then return ask(p.is_player, r.obj, r.guid) == true end
        return ask(r.obj.is_player, r.obj) == true
    end

    local function is_dead(r)
        if r.dead then return true end
        local snap = units.snapshot and ask(units.snapshot, r.obj)
        if type(snap) == "table" and snap.dead ~= nil then return snap.dead == true end
        return units.is_dead and ask(units.is_dead, r.obj) == true or false
    end

    local function health(r)
        local hp = tonumber(r.hp)
        if hp then return hp end
        return tonumber(units.health_fraction and ask(units.health_fraction, r.obj)) or 1
    end

    --- Your crowd control on it, and who has healed it: off its auras.
    local function read_auras(l, obj, now)
        local list = ask(obj.get_auras, obj)
        local seen = {}
        local ms = game_ms()
        if type(list) == "table" then
            for i = 1, #list do
                local a = list[i]
                if type(a) == "table" then
                    local name = a.buff_name
                    if type(name) ~= "string" or name == "" then name = spell_name(a.buff_id) end
                    local caster = a.caster
                    local cguid = caster and guid_of(caster)
                    local id, expire = tonumber(a.buff_id), tonumber(a.expire_time)
                    if cguid and HOTS[name] and cguid ~= my_guid then healer_at[cguid] = now end
                    if id and expire and cguid and (cguid == my_guid or (pet_guid and cguid == pet_guid))
                        and is_cc(name) then
                        local left = (expire - ms) / 1000
                        if left > 0 and left < PERMANENT then
                            seen[id] = true
                            local c = l.cc[id]
                            if not c then
                                c = {}
                                l.cc[id] = c
                            end
                            -- New, or put on again: its length is what is left now.
                            if not c.total or left > c.left_at_read + 0.5 then c.total = left end
                            c.expire_ms, c.left_at_read = expire, left
                        end
                    end
                end
            end
        end
        for id in pairs(l.cc) do
            if not seen[id] then l.cc[id] = nil end
        end
    end

    --- Immune to everything, and its trinket: pvp.lua's state.
    local function read_state(l, r)
        local p = pvp()
        if not p then return end
        if type(p.immune_all) == "function" then l.immune = ask(p.immune_all, r.obj) == true end
        local st = type(p.state) == "function" and ask(p.state, r.obj, r.guid) or nil
        if type(st) ~= "table" then
            l.down = nil
            return
        end
        if type(p.immune_all) ~= "function" then l.immune = st.immune == "all" end
        if st.trinket_down then
            local back = tonumber(st.trinket_back) or 0
            if not l.down then l.cd = back > CD_SHORT + 1 and CD_LONG or CD_SHORT end
            l.down, l.back = true, back
        else
            l.down, l.back, l.cd = false, 0, nil
        end
    end

    local stats = { players = 0, kill = false, healers = 0, cc = 0, trinkets = 0, looked = 0 }
    local kill_guid = nil

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.players, stats.kill, stats.healers, stats.cc, stats.trinkets, stats.looked = 0, false, 0, 0, 0, 0
        -- Through the world layer (1.89.0): lanes, the budget, the look, the wall fade.
        local draw = P.worldmarks or P.draw
        if not (draw and draw.ring_3d) then return end
        if not opt("pvpmarks_on", true) then return end
        local rows = ctx and ctx.enemies and ask(ctx.enemies.all)
        if type(rows) ~= "table" then return end
        local now = clock()
        local kill_range = tonumber(opt("pvp_kill_range", 40)) or 40
        local reach_all = max(REACH, kill_range)

        -- The enemy players within 40 yd (or the kill range), alive, nearest first.
        local players = {}
        for i = 1, #rows do
            local r = rows[i]
            if type(r) == "table" and r.obj and r.guid and (tonumber(r.dist) or reach_all + 1) <= reach_all
                and is_player(r) and not is_dead(r) then
                players[#players + 1] = r
            end
        end
        if #players == 0 then
            kill_guid = nil
            return
        end
        table.sort(players, function(a, b) return (a.dist or 0) < (b.dist or 0) end)
        stats.players = #players

        -- 1.7.6: curtains are off by default (main.lua, CURTAINS).
        local want_kill, want_healers = opt("pvp_kill_target", false), opt("pvp_healers", false)
        local want_cc, want_trinkets = opt("pvp_cc_timers", true), opt("pvp_trinkets", true)
        local L = (ctx and ctx.LAYER) or {}
        local layer = L.WORLD or 100
        local ms = game_ms()
        my_guid = my_guid or guid_of(ask(units.player))
        pet_guid = guid_of(ask(units.player_pet))

        -- Read: casts every frame (a field), auras and pvp.lua's state five
        -- times a second for the nearest few.
        local seen_now = {}      -- players[i]'s look
        for i = 1, #players do
            local r = players[i]
            local l = look_for(r.guid, now)
            seen_now[i] = l
            local cast = r.casting
            if want_healers and type(cast) == "table" and is_heal(spell_name(cast.spell_id)) then
                healer_at[r.guid] = now
            end
            if now - l.at >= READ_EVERY then
                local deep = i <= LOOK
                if deep or want_kill then
                    l.at = now
                    read_state(l, r)
                    if deep and my_guid and (want_cc or want_healers) then
                        read_auras(l, r.obj, now)
                        stats.looked = stats.looked + 1
                    end
                end
            end
        end

        -- KILL TARGET.
        local pick = nil
        if want_kill then
            local best, held = nil, nil
            for i = 1, #players do
                local r = players[i]
                if (r.dist or 0) <= kill_range and not seen_now[i].immune then
                    local hp = health(r)
                    if hp > 0 then
                        if not best or hp < best.hp or (hp == best.hp and (r.dist or 0) < (best.r.dist or 0)) then
                            best = { r = r, hp = hp }
                        end
                        if r.guid == kill_guid then held = { r = r, hp = hp } end
                    end
                end
            end
            pick = best
            if held and best and held.hp <= best.hp + STICK then pick = held end
        end
        local g = pick and pick.r.guid or nil
        if g and g ~= kill_guid then
            if kill_guid and draw.pulse then
                draw.pulse(pick.r.obj, C.kill_pulse, { life = 0.9, from = 1, to = 4, prio = "warn", module = "pvp" })
            end
        end
        kill_guid = g

        -- Drawing.
        for i = 1, #players do
            local r = players[i]
            local l = seen_now[i]
            local pos = units.position and ask(units.position, r.obj)
            if pos then
                local reach = tonumber(units.combat_reach and ask(units.combat_reach, r.obj)) or 1.5
                local base = min(4, max(0.9, reach + 0.3)) + 0.6

                if r.guid == kill_guid and draw.curtain_3d then
                    draw.curtain_3d(pos, max(1, reach + 0.5), C.kill, { to = C.kill_top, height = 2.4,
                        points = 24, rings = 3, fill = 0.3, speed = 1.4, spin = 1, lod = true, layer = layer,
                        unit = r.obj, prio = "warn", module = "pvp" })
                    stats.kill = true
                end

                local healed = healer_at[r.guid]
                if want_healers and healed and now - healed <= HEALER_KEEP and draw.curtain_3d then
                    draw.curtain_3d(pos, max(1.3, reach + 0.9), C.healer, { to = C.healer_top, height = 1.6,
                        points = 24, rings = 3, fill = 0.25, speed = 1.1, spin = -0.8, lod = true, layer = layer,
                        unit = r.obj, prio = "info", module = "pvp" })
                    stats.healers = stats.healers + 1
                end

                if i <= LOOK then
                    if want_trinkets and l.down ~= nil then
                        if l.down then
                            local back = max(0, (l.back or 0) - (now - l.at))
                            local cd = l.cd or CD_LONG
                            draw.ring_3d(pos, base, min(1, max(0, 1 - back / cd)), C.trinket_down,
                                { bg = C.trinket_band, inner = 0.88, outer = 1.0, layer = layer,
                                  unit = r.obj, lane = "trinket", prio = "info", module = "pvp" })
                        else
                            draw.ring_3d(pos, base, 1, C.trinket_ready,
                                { bg = C.trinket_band, inner = 0.94, outer = 1.0, layer = layer,
                                  unit = r.obj, lane = "trinket", prio = "info", module = "pvp" })
                        end
                        stats.trinkets = stats.trinkets + 1
                    end

                    if want_cc then
                        local list = {}
                        for _, c in pairs(l.cc) do list[#list + 1] = c end
                        table.sort(list, function(a, b) return a.expire_ms < b.expire_ms end)
                        for k = 1, min(CC_RINGS, #list) do
                            local c = list[k]
                            local left = (c.expire_ms - ms) / 1000
                            if left > 0 then
                                local frac = c.total > 0 and min(1, left / c.total) or 0
                                draw.ring_3d(pos, base + k * GAP, frac, C.cc, { to = C.cc, bg = C.band,
                                    inner = 0.86, outer = 1.0, direction = -1, layer = layer,
                                    unit = r.obj, lane = "cc", index = k, prio = "info", module = "pvp" })
                                stats.cc = stats.cc + 1
                            end
                        end
                    end
                end
            end
        end

        -- Forget who has not been seen for a while.
        if now - swept_at > 10 then
            swept_at = now
            for guid, l in pairs(looks) do
                if now - l.seen > 30 then looks[guid] = nil end
            end
            for guid, at in pairs(healer_at) do
                if now - at > HEALER_KEEP then healer_at[guid] = nil end
            end
        end
    end

    function M.stats() return stats end

    return M
end

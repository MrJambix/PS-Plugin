-- Jambix AIO / react / rules / hunter_pvp -- the PvP hunter's reactions (1.7.6, ALPHA/TEST).
--
-- The user, 2026-10-10: "make an unstoppable PVP hunter where it can detect
-- its in pvp mode and react instantly... know what to do what the player is
-- doing how to Cast CC and kill". Everything here asks modules/pvphunter.lua
-- first: only with the class option "PvP hunter (ALPHA/TEST)" on, and only in
-- a fight with a player. The rotation's PvP profile (classes/hunter.lua) is
-- what gets shot; these are what cannot wait for it.
--
-- WHERE THE RULES COME FROM. Nobody has published a PvP guide for the
-- Forever hunter (Mobalytics, Icy Veins and wowtbc.gg were all PvE on
-- 2026-10-10), so these are the Classic guides' (Icy Veins' Classic hunter
-- PvP guide, Wowhead's Classic hunter dueling guide) with what Forever
-- changed: traps are laid in combat, Freezing Trap shares its cooldown with
-- Frost Trap, Scatter Shot turns your attack off, Multi-Shot shares Aimed
-- Shot's cooldown.
--
--   85  PvP hunter: peel the melee   an enemy player in melee with you: Wing
--                                    Clip while it is not slowed; once a clip
--                                    has not shaken it, it ignores slows, or
--                                    you are hurt, Freezing Trap at your feet
--                                    (nothing of ours ticking on it, the pet
--                                    not on it), Scatter Shot, the pet's
--                                    Intimidation, Frost Trap against two.
--                                    (Deterrence is the core defensive's and
--                                    the burst answer's.) The kite walks you out, and
--                                    from a frozen one on to the reset
--                                    distance for the Aimed Shot opener.
--   84  PvP hunter: Scatter into the trap   a player in your Scatter Shot
--                                    beside you, nothing ticking on it: the
--                                    trap goes down under it before it wakes.
--   88  PvP hunter: Feign Death the cast   a Polymorph, a Fear, a big bolt
--                                    about to land on you and nothing kicked
--                                    it: they lose you as a target and the
--                                    cast fails. Scatter Shot (the hunter's
--                                    "stop the cast", 86) goes first from 15
--                                    yd: same cast, answered once.
--   76  PvP hunter: turn on the player attacking you   your target is a
--                                    mob, or nothing, and a player is hitting
--                                    you.
--   68  PvP hunter: shoot another while this one is trapped
--   66  PvP hunter: finish the low one   another enemy player nearly dead.
--
-- UNTESTED IN GAME, every one of these: that a trap laid under a player
-- standing on it springs once it arms, that Feign Death breaks a player's
-- cast at you on Forever, that the hawks break a trap.

return function(R, P, lib)
    local book = P.spellbook
    local units = P.units
    local pvp = lib.pvp
    local floor, min, huge = math.floor, math.min, math.huge

    if not pvp then return end

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        if ok then return value end
        return nil
    end

    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    local function H() return (P.rotation and P.rotation.helpers) or {} end

    local function usable(name)
        local h = H()
        return book.known(name) and book.ready(name) and (not h.key_allows or h.key_allows(name))
    end

    --- The PvP hunter is on, and this is a fight with a player.
    local function on()
        local m = P.pvphunter
        if not (m and m.mode) then return false end
        local ok, yes = pcall(m.mode)
        return ok and yes == true
    end

    local function note(text)
        local m = P.pvphunter
        if m and m.note then pcall(m.note, text) end
    end

    local function name_of(unit)
        return (unit and units.name and try(units.name, unit)) or "a player"
    end

    local function debuff_up(unit, name)
        local h = H()
        return h.debuff_up ~= nil and try(h.debuff_up, unit, name) == true
    end

    -- Our slows and roots: any of these and it is not following at speed.
    local SLOWS = { "Wing Clip", "Improved Wing Clip", "Concussive Shot", "Frost Trap Aura", "Entrapment",
                    "Counterattack" }
    local function slowed(unit)
        for i = 1, #SLOWS do
            if debuff_up(unit, SLOWS[i]) then return true end
        end
        return false
    end

    --- Something of ours ticks on it: a sting, or (on the target) the hawks.
    --- A tick breaks a trap or a Scatter Shot the moment it lands.
    local HAWK_LASTS = 18
    local function ticking(unit, is_target)
        if debuff_up(unit, "Serpent Sting") or debuff_up(unit, "Viper Sting") then return true end
        if is_target and book.known("Summon Hawk") then
            local mem = lib.memory
            local since = mem and mem.since_success and mem.since_success("Summon Hawk") or huge
            if since < HAWK_LASTS then return true end
            local h = H()
            if h.since_cast and try(h.since_cast, "Summon Hawk") < HAWK_LASTS then return true end
        end
        return false
    end

    --- What the next incapacitate gets on this player: 1, 0.5, 0.25 or 0,
    --- from the PvP intelligence's control plan (react/intel/ccplan.lua,
    --- Stage 6: on Era DRList's rule on the controls it counted; on Forever
    --- UNKNOWN, taken as full). Scatter Shot and the trap share one category.
    local function dr(unit)
        local I = P.react and P.react.intel
        local S = I and I.S
        if not (I and I.cc and S and S.active and not S.off and unit and P.units) then return 1 end
        local ok, mult = pcall(I.cc.next, S, P.units.guid(unit), "incapacitate")
        if ok and type(mult) == "number" then return mult end
        return 1
    end

    local function in_melee(r)
        local h = H()
        if h.in_melee then
            local ok, yes = pcall(h.in_melee, r.obj, r.dist)
            if ok then return yes == true end
        end
        return (r.dist or huge) <= 5
    end

    --- The enemy players in melee with us and on us, free to act (nothing
    --- holds them): the count, and the nearest.
    local function melee_on_me(W)
        local rows, n = W.enemies.list or {}, W.enemies.count or 0
        local count, nearest = 0, nil
        for i = 1, n do
            local r = rows[i]
            if r and r.obj and r.guid and not r.dead and r.targeting_me and not r.control
                and pvp.is_player(r.obj, r.guid) and in_melee(r) then
                count = count + 1
                if not nearest or (r.dist or huge) < (nearest.dist or huge) then nearest = r end
            end
        end
        return count, nearest
    end

    -- When each player came into melee with us, for "the clip did not shake it".
    local on_since = {}
    local function in_melee_for(guid, now, present)
        if not present then
            on_since[guid] = nil
            return 0
        end
        on_since[guid] = on_since[guid] or now
        return now - on_since[guid]
    end
    local SHAKE = 1.5           -- seconds slowed and still on us: the clip was not enough

    -- ==========================================================================
    -- 85  PEEL THE MELEE
    -- ==========================================================================

    R.add_rule({
        name = "PvP hunter: peel the melee",
        category = "escape", priority = 85,
        needs = { "combat" },
        every = 0.1,
        retry = { hold = 0.8 },
        propose = function(W, offer)
            if not on() then
                for k in pairs(on_since) do on_since[k] = nil end
                return
            end
            local V = W.pvp
            if V and V.control and V.control.helpless then return end
            local n, r = melee_on_me(W)
            for guid in pairs(on_since) do
                if not r or guid ~= r.guid then on_since[guid] = nil end
            end
            if not r then return end
            local st = pvp.state(r.obj, r.guid)
            if st and st.immune == "all" then return end
            local f = pvp.foe(r.obj, r.guid)
            local hp = W.player.hp or 1
            local is_target = r.guid == W.target.guid
            local is_slowed = slowed(r.obj)
            local ignores = st ~= nil and (st.mech.snare ~= nil or st.mech.root ~= nil)
            local held_for = in_melee_for(r.guid, W.now, true)
            local unshaken = (is_slowed and held_for >= SHAKE) or ignores
            local tick = ticking(r.obj, is_target)
            local next_cc = dr(r.obj)
            local pet_on = W.pet.alive and W.pet.target_guid == r.guid
            local who = name_of(r.obj)
            local key = "pvp_peel:" .. tostring(r.guid)

            local function give(name, spec, points, reasons)
                spec.name = name
                spec.event_key = key
                spec.handled_for = spec.handled_for or 1.0
                spec.why = spec.why or string.format("%s %s in melee with you", who, pvp.foe_text(f))
                local c = offer(spec)
                c.reasons_in = reasons
                c.points = points
                c.peel_of = who
                return c
            end

            -- Pairs of (points, text); a pair with no text or no points is
            -- left out. select, not #: the texts may be nil.
            local function reason_list(...)
                local out, p = {}, 0
                for i = 1, select("#", ...), 2 do
                    local points, text = select(i, ...)
                    if points and points ~= 0 and text then
                        out[#out + 1] = { points, text }
                        p = p + points
                    end
                end
                return out, p
            end

            -- The clip first: the bigger answers (the trap, Scatter Shot, the
            -- stun) wait until it has not shaken the player, it ignores slows,
            -- you are hurt, two are on you, or there is no clip to give.
            local clip_ok = usable("Wing Clip") and not ignores
            local escalate = unshaken or hp < 0.5 or n >= 2 or not clip_ok
            local hurt = hp < 0.5 and string.format("you are at %d%%", pct(hp)) or nil
            local hurt_pts = hp < 0.3 and 14 or (hp < 0.5 and 8 or 0)
            local two = n >= 2 and string.format("%d players in melee with you", n) or nil

            -- Wing Clip: the first answer, while it is not slowed.
            if not is_slowed and not ignores and usable("Wing Clip") and not pvp.blocks("Wing Clip", r.obj) then
                local reasons, p = reason_list(15, "not slowed: Wing Clip, then step out")
                give("Wing Clip", { target = r.obj, target_kind = "enemy" }, p, reasons)
            end

            -- Freezing Trap at your feet: it is standing on it.
            if escalate and usable("Freezing Trap") and next_cc > 0 and not tick then
                local reasons, p = reason_list(
                    6, "it stands where the trap goes down",
                    unshaken and 12 or 0, ignores and "it ignores slows" or "slowed and still on you",
                    (not is_target) and 8 or 0, "not your target: trap it, keep shooting yours",
                    hurt_pts, hurt,
                    two and 4 or 0, two,
                    next_cc < 1 and -4 or 0, "diminished: a shorter freeze",
                    pet_on and -10 or 0, "the pet is on it: its next bite breaks the trap")
                give("Freezing Trap", { target = W.player.unit, target_kind = "self", handled_for = 2.0 }, p, reasons)
            end

            -- Scatter Shot: four seconds to get out.
            if escalate and usable("Scatter Shot") and (r.dist or huge) <= 15 and next_cc > 0
                and not pvp.blocks("Scatter Shot", r.obj) then
                local reasons, p = reason_list(
                    6, "four seconds to get out",
                    unshaken and 10 or 0, ignores and "it ignores slows" or "slowed and still on you",
                    hp < 0.4 and 12 or 0, hp < 0.4 and string.format("you are at %d%%", pct(hp)) or nil,
                    two and 4 or 0, two,
                    tick and -4 or 0, "something of ours ticks on it: it wakes at the next tick",
                    pet_on and -10 or 0, "the pet is on it: its next bite wakes it")
                give("Scatter Shot", { target = r.obj, target_kind = "enemy" }, p, reasons)
            end

            -- Intimidation: the pet is on it.
            if escalate and pet_on and usable("Intimidation") and not (st and st.mech.stun) then
                local reasons, p = reason_list(
                    8, "the pet is on it: a three-second stun",
                    unshaken and 8 or 0, ignores and "it ignores slows" or "slowed and still on you",
                    hurt_pts, hurt)
                give("Intimidation", { target = W.player.unit, target_kind = "self" }, p, reasons)
            end

            -- Frost Trap (Forever: the Freezing Trap's cooldown too) against
            -- two, or when something of ours ticks on it and the freeze would
            -- not hold.
            if usable("Frost Trap") and (two or (tick and unshaken)) then
                local reasons, p = reason_list(
                    4, "a slowing patch where you stand",
                    two and 12 or 0, two,
                    (tick and unshaken) and 8 or 0, "a freeze would not hold: something of ours ticks on it")
                give("Frost Trap", { target = W.player.unit, target_kind = "self", handled_for = 2.0 }, p, reasons)
            end

            -- Deterrence is not offered here: the core "Defensive cooldown"
            -- presses it at low health and "PvP: answer the burst" into a
            -- melee player's burst (rules/core.lua, rules/pvp.lua).
        end,
        score = function(W, c)
            for i = 1, #(c.reasons_in or {}) do c:add(c.reasons_in[i][1], c.reasons_in[i][2]) end
        end,
        on_execute = function(W, c)
            note(string.format("%s on %s", c.name, c.peel_of or "the player in melee"))
        end,
    })

    -- ==========================================================================
    -- 84  SCATTER INTO THE TRAP
    -- ==========================================================================
    --
    -- The Classic combo without the Feign Death Classic needed: the player is
    -- disoriented beside you, the trap goes down at your feet, and it wakes
    -- inside it.

    R.add_rule({
        name = "PvP hunter: Scatter into the trap",
        category = "cc", priority = 84,
        needs = { "combat" },
        every = 0.1,
        retry = { hold = 1.5 },
        propose = function(W, offer)
            if not on() or not usable("Freezing Trap") then return end
            local m = P.pvphunter
            local rows, n = W.enemies.list or {}, W.enemies.count or 0
            for i = 1, n do
                local r = rows[i]
                if r and r.obj and r.guid and not r.dead and (r.dist or huge) <= 5
                    and pvp.is_player(r.obj, r.guid) then
                    local kind, left = nil, 0
                    if m and m.held then kind, left = m.held(r.obj) end
                    if kind == "scatter" and left >= 0.8 and dr(r.obj) > 0
                        and not ticking(r.obj, r.guid == W.target.guid) then
                        local c = offer({
                            name = "Freezing Trap", target = W.player.unit, target_kind = "self",
                            event_key = "pvp_scatter_trap:" .. tostring(r.guid), handled_for = 4,
                            why = string.format("%s scattered beside you, %.1fs left", name_of(r.obj), left),
                        })
                        c.left, c.who = left, name_of(r.obj)
                        return
                    end
                end
            end
        end,
        score = function(W, c)
            c:add(12, "it wakes inside the trap")
            if c.left < 2 then c:add(6, string.format("Scatter Shot ends in %.1fs", c.left)) end
        end,
        on_execute = function(W, c) note("Freezing Trap under " .. (c.who or "the scattered player")) end,
    })

    -- ==========================================================================
    -- 88  FEIGN DEATH THE CAST
    -- ==========================================================================
    --
    -- The Classic guides: "Feign Death just before a cast lands (Frostbolt,
    -- Polymorph, Fear, Mind Blast). They lose their target and the cast
    -- fails." Pressed in its last moment, so a Scatter Shot from 15 yd (the
    -- hunter's "stop the cast", 86, with the same cast key) goes first.

    local FD_MECHS = { polymorph = true, fear = true, charm = true, sleep = true, horror = true }
    local FD_LEFT = 0.6            -- seconds left on the cast when Feign Death goes
    local FD_BIG = 30              -- detect.lua's weight for a hit worth it at any health

    R.add_rule({
        name = "PvP hunter: Feign Death the cast",
        category = "defensive", priority = 88, target = "self",
        needs = { "casting", "combat" },
        wake = { "jcore.enemy.casting" },
        retry = { hold = 1.0 },
        propose = function(W, offer)
            if not on() or not usable("Feign Death") then return end
            local V = W.pvp
            if V and V.control and V.control.helpless then return end
            local best = nil
            local function consider(cast, guid)
                if not cast or cast.remaining > FD_LEFT or cast.remaining < 0.08 then return end
                local mech = pvp.SPELL_MECH[cast.name or ""]
                local danger = cast.danger or 0
                local worth = (mech and FD_MECHS[mech]) or danger >= FD_BIG
                    or (danger >= 25 and (W.player.hp or 1) < 0.5)
                if worth and (not best or cast.remaining < best.cast.remaining) then
                    best = { cast = cast, guid = guid, mech = mech }
                end
            end
            local tg = W.target
            if tg.player and tg.casting and tg.targets_me then consider(tg.cast, tg.guid) end
            local en = W.enemies
            for i = 1, en.casting_n or 0 do
                local cast = en.casting[i]
                if cast.player and cast.at_me then consider(cast, cast.guid) end
            end
            if not best then return end
            local cast = best.cast
            local c = offer({
                name = "Feign Death", target = W.player.unit, target_kind = "self",
                event_key = lib.cast_key(best.guid, cast), handled_for = cast.remaining + 0.5,
                why = string.format("%s at you", cast.name ~= "" and cast.name or "a cast"),
            })
            c.cast, c.mech = cast, best.mech
        end,
        score = function(W, c)
            local cast = c.cast
            c:add(cast.danger or 0, string.format("%s (%s)", cast.name or "a cast", c.mech or cast.kind or "cast"))
            c:add(20, string.format("lands in %.1fs", cast.remaining))
        end,
        on_execute = function(W, c) note("Feign Death into " .. tostring(c.cast and c.cast.name or "a cast")) end,
    })

    -- ==========================================================================
    -- TARGETS
    -- ==========================================================================

    local function free(r)
        if not r or not r.obj or r.dead or (r.hp or 1) <= 0 then return false end
        if r.control and r.control.breaks then return false end
        local react = P.react
        if react and react.out_of_fight and try(react.out_of_fight, r.obj) == true then return false end
        return true
    end

    --- The enemy player that best fits, or nil: `want(r)` says which rows
    --- count; the nearest of them.
    local function pick(W, want)
        local rows, n = W.enemies.list or {}, W.enemies.count or 0
        local best = nil
        for i = 1, n do
            local r = rows[i]
            if r and r.guid ~= W.target.guid and (r.dist or huge) <= 35 and free(r)
                and pvp.is_player(r.obj, r.guid) and want(r) then
                if not best or (r.dist or huge) < (best.dist or huge) then best = r end
            end
        end
        return best
    end

    local function switch_to(offer, r, key, why)
        local who = name_of(r.obj)
        local c = offer({
            name = "Target " .. who, kind = "set_target", target = r.obj, target_kind = "enemy",
            event_key = key, handled_for = 4, why = why,
        })
        c.who = who
        return c
    end

    R.add_rule({
        name = "PvP hunter: turn on the player attacking you",
        category = "utility", priority = 76, kind = "set_target", lane = "fast",
        every = 0.2,
        retry = { hold = 2.0 },
        propose = function(W, offer)
            if not on() then return end
            local tg = W.target
            if tg.player then return end
            -- A mob nearly dead is finished first.
            if tg.unit and (tg.hp or 1) < 0.15 then return end
            local r = pick(W, function(row) return row.targeting_me == true end)
            if not r then return end
            switch_to(offer, r, "pvp_turn:" .. tostring(r.guid),
                string.format("%s is attacking you", name_of(r.obj)))
        end,
        score = function(W, c) c:add(12, c.why or "a player on you") end,
        on_execute = function(W, c) note("turned on " .. (c.who or "the player attacking you")) end,
    })

    R.add_rule({
        name = "PvP hunter: shoot another while this one is trapped",
        category = "utility", priority = 68, kind = "set_target", lane = "fast",
        every = 0.25,
        retry = { hold = 2.0 },
        propose = function(W, offer)
            if not on() or not W.target.unit then return end
            local m = P.pvphunter
            if not (m and m.held) then return end
            local kind, left = m.held(W.target.unit)
            if kind ~= "trap" or left < 4 then return end
            local r = pick(W, function(row)
                return row.engaged == true or row.targeting_me == true or row.targeting_pet == true
            end)
            if not r then return end
            switch_to(offer, r, "pvp_other:" .. tostring(W.target.guid),
                string.format("%s is frozen for %.0fs", name_of(W.target.unit), left))
        end,
        score = function(W, c) c:add(8, c.why or "the target is trapped") end,
        on_execute = function(W, c) note("on " .. (c.who or "another player") .. " while the trap holds") end,
    })

    local FINISH_AT = 0.2          -- another player this low is worth the switch
    local FINISH_FROM = 0.4        -- unless the target is this low itself

    R.add_rule({
        name = "PvP hunter: finish the low one",
        category = "utility", priority = 66, kind = "set_target", lane = "fast",
        every = 0.25,
        retry = { hold = 3.0 },
        propose = function(W, offer)
            if not on() then return end
            local tg = W.target
            if not tg.player or (tg.hp or 1) <= FINISH_FROM then return end
            -- A kill window (Stage 9) when the layer reads one: low AND no
            -- out seen ready; health alone when it does not.
            local kill = lib.killwindow
            local r = pick(W, function(row)
                local v = kill and kill.for_guid and kill.for_guid(row.guid) or nil
                if v then return v.v == "HIGH_CONFIDENCE_KILL_WINDOW" or (v.v == "PREPARE_BURST" and (row.hp or 1) <= FINISH_AT) end
                return (row.hp or 1) <= FINISH_AT
            end)
            if not r then return end
            local c = switch_to(offer, r, "pvp_finish:" .. tostring(r.guid),
                string.format("%s at %d%%", name_of(r.obj), pct(r.hp)))
            c.hp = r.hp
        end,
        score = function(W, c) c:add(min(15, floor((FINISH_AT - (c.hp or FINISH_AT)) * 100) + 8), c.why or "nearly dead") end,
        on_execute = function(W, c) note("finishing " .. (c.who or "a player")) end,
    })
end

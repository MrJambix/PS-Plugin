-- Jambix AIO / react / rules / pvp -- answering another player (1.81.0, Classic Era).
--
-- The user, 2026-10-06: "let's work PvP on Classic Era ... what players will
-- do and how to react to it, what skills to use for that purpose, or if to
-- hold or use trinkets". Six reactions, every class, acting only against
-- players (react/pvp.lua reads them):
--
--   92  PvP: break the control    out of a stun, fear, sheep, root... with
--                                 the cheapest thing that breaks it, and the
--                                 PvP trinket only when the control costs
--                                 more than the trinket is worth
--   87  PvP: stop the cast        a heal, a sheep, a fear on its way with no
--                                 interrupt ready: a stun or a fear stops it;
--                                 aimed at you, Grounding Totem, Tremor
--                                 Totem, Berserker Rage, Fear Ward or a
--                                 druid's form make it land on nothing
--   82  PvP: answer the burst     a player on you pops Recklessness, Arcane
--                                 Power, Adrenaline Rush...: take them out
--                                 for it, or your own defensive
--   70  PvP: off the immune target  Divine Shield, Ice Block (Blessing of
--                                 Protection, for a warrior or a rogue): to
--                                 a target something lands on
--   64  PvP: find the stealthy    a rogue vanished beside you: Flare,
--                                 Arcane Explosion, Holy Nova, Consecration,
--                                 Thunder Clap; Perception when one is about
--   58  PvP: purge                Purge, Dispel Magic, a felhunter's Devour
--                                 Magic on the buff that matters most
--
-- HOLD OR USE THE TRINKET. A trinket on a five-minute cooldown is the one
-- answer to the control that loses the fight, so every control is weighed
-- before anything is pressed: what it is, how long is left, whether you are
-- being hit through it, your health, how many players are on you, whether
-- damage would break it anyway, whether a player is casting at you behind
-- it, whether you carry the flag, whether your target is getting away. The
-- points are the candidate's reasons, so the readout says why. Cheap
-- breakers (Blink, Berserker Rage, a druid's form, Blessing of Freedom, the
-- felhunter) go first and at a low line; Will of the Forsaken and Escape
-- Artist a little higher; a Living Action Potion higher still; the trinket
-- at the line the Reactions page sets ("PvP trinket": only to stay alive,
-- balanced, or break any control). A control nothing you have can break
-- (Blind, Sap, a Freezing Trap, Death Coil for most) is said once in the
-- journal, and the trinket stays where it is. The burst window never spends
-- a control breaker either (burst.lua asks react/pvp.lua's keeps()).

return function(R, P, lib)
    local book = P.spellbook
    local units = P.units
    local detect = lib.detect
    local pvp = lib.pvp
    local floor, min, huge = math.floor, math.min, math.huge

    if not pvp then return end

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        if ok then return value end
        return nil
    end

    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    local function H() return (P.rotation and P.rotation.helpers) or {} end

    local function key_allows(name)
        local h = H()
        return not h.key_allows or h.key_allows(name)
    end

    local function usable(name)
        return book.known(name) and book.ready(name) and key_allows(name)
    end

    local function class_name(W) return W.class and W.class.class_name or "" end

    --- Does this character fight in melee? The power bar says it for
    --- warriors, rogues and feral druids; a paladin is melee unless Holy, a
    --- shaman only as Enhancement.
    local function melee(W)
        local kind = W.player.power_kind
        if kind == "RAGE" or kind == "ENERGY" then return true end
        local cls = class_name(W)
        local label = ((W.profile and W.profile.label) or ""):lower()
        if cls == "PALADIN" then return label:find("holy", 1, true) == nil end
        if cls == "SHAMAN" then return label:find("enhance", 1, true) ~= nil end
        return cls == "WARRIOR" or cls == "ROGUE"
    end

    local function caster(W)
        return not melee(W) and class_name(W) ~= "HUNTER"
    end

    local function name_of(unit)
        return (unit and units.name and try(units.name, unit)) or "a player"
    end

    local function dist_to(unit, fallback)
        if fallback and fallback < huge then return fallback end
        local d = unit and units.distance and try(units.distance, unit) or nil
        return type(d) == "number" and d or huge
    end

    local function being_hit(W)
        local pl = W.player
        return (pl.hp_rate or 0) < -0.02 or (pl.damage_recent or 0) >= 0.05
    end

    -- ==========================================================================
    -- 92  BREAK THE CONTROL, AND THE TRINKET
    -- ==========================================================================

    --- What a control is worth breaking, before anything else is known.
    local BASE = {
        charm = 40, stun = 30, fear = 30, horror = 30, polymorph = 25, sleep = 25, knockout = 25,
        disorient = 25, freeze = 25, silence = 10, disarm = 10, root = 10, snare = 5,
    }

    --- The line each kind of breaker needs. The trinket's is the setting's
    --- ("break any control": anything worth more than nothing), and a
    --- cheaper one's is never above it, so the trinket is never spent while
    --- something cheaper would have gone.
    local LINE = { cheap = 15, racial = 15, potion = 35 }
    local TRINKET_LINE = { 60, 40, 1 }
    local TRINKET_MODE = { "only to stay alive", "balanced", "break any control" }
    -- Cheaper first when two would do: the trinket is the last thing spent.
    local COST_ORDER = { cheap = 4, racial = 3, potion = 2, trinket = 1 }

    -- Balanced. The *Use the PvP trinket* dropdown left the Reactions page with
    -- the old PvP sections on 2026-10-11 (the user: "drop/delete old stuff");
    -- the PvP intelligence layer's cooldown economy is to own this choice
    -- (PVP_INTEL_PLAN.md, Stage 6).
    local function trinket_line()
        return TRINKET_LINE[2], TRINKET_MODE[2]
    end

    ---@return number line
    ---@return string|nil mode the trinket's setting, for its line
    local function line_for(cost)
        local trinket, mode = trinket_line()
        if cost == "trinket" then return trinket, mode end
        return min(LINE[cost] or 15, trinket), nil
    end

    --- How much this control costs you, in points with reasons. nil and a
    --- reason when it is not worth an answer at all.
    local function pressure(W, ctl)
        local V, pl, tg = W.pvp, W.player, W.target
        local left = ctl.remaining or 0
        if left < 1.0 then return nil, nil, string.format("%s ends in %.1fs", ctl.name, left) end
        local reasons = {}
        local p = 0
        local function add(points, text)
            points = floor(points + 0.5)
            if points ~= 0 then
                p = p + points
                reasons[#reasons + 1] = { points, text }
            end
        end
        local base = BASE[ctl.mech] or 10
        if left < huge then
            add(base * min(1, left / 4), string.format("%s (%s), %.1fs left", ctl.name, ctl.mech, left))
        else
            add(base, string.format("%s (%s)", ctl.name, ctl.mech))
        end
        local hit = being_hit(W)
        if hit then add(20, "you are being hit through it") end
        if pl.hp < 0.3 then
            add(30, string.format("health %d%%", pct(pl.hp)))
        elseif pl.hp < 0.5 then
            add(15, string.format("health %d%%", pct(pl.hp)))
        end
        if (V.attackers or 0) >= 2 then
            add(min(20, (V.attackers - 1) * 10), string.format("%d players on you", V.attackers))
        end
        if ctl.breaks and not hit then
            add(-15, "damage breaks it, and nothing is hitting you")
            if ctl.mech == "polymorph" and pl.hp < 0.9 then add(-10, "the sheep heals you") end
        end
        local cast = V.cast_at_me
        if cast and ctl.helpless and (cast.danger or 0) >= detect.DANGEROUS then
            add(15, string.format("%s is on its way to you", cast.name ~= "" and cast.name or "a cast"))
        end
        if V.flag then add(40, "you carry the flag") end
        if ctl.mech == "silence" and caster(W) then add(15, "a caster, silenced") end
        if ctl.mech == "disarm" and melee(W) then add(15, "melee, disarmed") end
        if ctl.mech == "root" or ctl.mech == "snare" then
            if melee(W) and tg.player and (tg.distance or huge) > 5 then
                add(15, string.format("%s is out of your reach", name_of(tg.unit)))
            elseif not melee(W) and (V.melee_attackers or 0) > 0 then
                add(15, "a player in melee with you")
            end
            if tg.player and (tg.hp or 1) < 0.25 and tg.activity == "fleeing" then
                add(15, string.format("%s is getting away at %d%%", name_of(tg.unit), pct(tg.hp)))
            end
        end
        return p, reasons, nil
    end

    -- What each of yours breaks, and whether it can be pressed under a
    -- control that leaves you helpless (`under`). Era's data for what
    -- each removes (pvp.lua's header); what can be pressed while stunned or
    -- feared is the game's long-standing rule: Will of the Forsaken out of a
    -- fear, Blink out of a stun, Berserker Rage out of a fear.
    local BREAKERS = {
        { name = "Will of the Forsaken", breaks = { fear = true, charm = true, sleep = true },
          under = { fear = true, charm = true, sleep = true }, cost = "racial", lane = "fast" },
        { name = "Blink", breaks = { stun = true, root = true }, under = { stun = true }, cost = "cheap" },
        { name = "Berserker Rage", breaks = { fear = true, knockout = true }, under = { fear = true }, cost = "cheap" },
        { name = "Escape Artist", breaks = { root = true, snare = true }, cost = "racial", lane = "fast" },
        { name = "Blessing of Freedom", breaks = { root = true, snare = true }, cost = "cheap" },
    }
    -- A druid's form takes off roots and snares; which one, by the form
    -- it is in (a form cast again would only leave it).
    local FORMS_FROM = {
        ["Cat Form"] = { "Travel Form", "Dire Bear Form", "Bear Form" },
        ["Bear Form"] = { "Cat Form", "Travel Form" }, ["Dire Bear Form"] = { "Cat Form", "Travel Form" },
        ["Travel Form"] = { "Cat Form", "Dire Bear Form", "Bear Form" },
    }
    local FORMS_ANY = { "Travel Form", "Cat Form", "Dire Bear Form", "Bear Form" }
    -- Living Action Potion: removes stuns, roots and snares (Era 24364).
    local LIVING_ACTION = "Living Action Potion"
    local LIVING_BREAKS = { stun = true, root = true, snare = true }

    local function druid_form(W, ctl)
        if class_name(W) ~= "DRUID" or ctl.helpless then return nil end
        local current = P.forms and P.forms.current and try(P.forms.current) or nil
        local list = FORMS_FROM[current or ""] or FORMS_ANY
        -- The form keeper (forms.lua) puts the profile's form back after.
        for i = 1, #list do
            if usable(list[i]) then return list[i] end
        end
        return nil
    end

    --- Every way you have to break this control right now, cheapest first.
    local function breakers_for(W, ctl)
        local out = {}
        local mech = ctl.mech
        for i = 1, #BREAKERS do
            local b = BREAKERS[i]
            if b.breaks[mech] and (not ctl.helpless or (b.under and b.under[mech])) and usable(b.name) then
                out[#out + 1] = { name = b.name, kind = "spell", cost = b.cost, lane = b.lane or "gcd",
                                  target = W.player.unit, target_kind = "self" }
            end
        end
        if mech == "root" or mech == "snare" then
            local form = druid_form(W, ctl)
            if form then
                out[#out + 1] = { name = form, kind = "spell", cost = "cheap", lane = "gcd",
                                  target = W.player.unit, target_kind = "self" }
            end
        end
        -- The felhunter takes a Magic one off you, whatever it is.
        if ctl.dispel == "MAGIC" and W.pet.alive and P.pet and P.pet.knows and P.pet.knows("Devour Magic") then
            out[#out + 1] = { name = "Devour Magic", kind = "pet_spell", cost = "cheap", lane = "pet",
                              target = W.player.unit, target_kind = "self" }
        end
        local hc = P.hardcore
        if LIVING_BREAKS[mech] and (not ctl.helpless or mech == "stun") and hc and hc.named
            and hc.named(LIVING_ACTION) then
            out[#out + 1] = { name = LIVING_ACTION, kind = "named_item", item = LIVING_ACTION, cost = "potion",
                              lane = "fast", target = W.player.unit, target_kind = "self" }
        end
        local trinket = pvp.trinket_for(mech)
        if trinket then
            out[#out + 1] = { name = trinket.name, kind = "named_item", item = trinket.name, cost = "trinket",
                              lane = "fast", target = W.player.unit, target_kind = "self", trinket = trinket }
        end
        table.sort(out, function(a, b) return COST_ORDER[a.cost] > COST_ORDER[b.cost] end)
        return out
    end

    --- Did a player put it on you? Said by the debuff's caster where the
    --- client names one. A mob's stun is not the trinket's, even with a
    --- player in sight (on a PvP realm one usually is), unless you carry the
    --- flag. Where the caster is not said: a player on you, or a battleground.
    local function by_a_player(W, ctl)
        if ctl.from_player == true then return true end
        if ctl.from_player == false then return W.pvp.flag == true end
        return (W.pvp.attackers or 0) > 0 or W.env.context == "pvp"
    end

    local said_at = {}
    local function say_once(key, text)
        local now = core.time()
        if said_at[key] and (now - said_at[key]) < 30 then return end
        said_at[key] = now
        if lib.journal then lib.journal("select", text, key) end
    end

    R.add_rule({
        name = "PvP: break the control",
        category = "escape", priority = 92, lane = "fast",
        every = 0.1,
        retry = { hold = 1.0 },
        propose = function(W, offer)
            local V = W.pvp
            if not V or not V.active then return end
            local list
            if V.control and V.control.helpless then
                list = { V.control }
            else
                list = { V.control, V.root, V.snare }
            end
            for i = 1, 3 do
                local ctl = list[i]
                if ctl and by_a_player(W, ctl) then
                    local points, reasons, skip = pressure(W, ctl)
                    local options = breakers_for(W, ctl)
                    if #options == 0 then
                        if ctl.helpless and points then
                            local _, kept = pvp.trinket_for(ctl.mech)
                            say_once("pvp_nobreak:" .. ctl.mech, string.format(
                                "%s (%s): nothing you have breaks it%s -- waiting it out", ctl.name, ctl.mech,
                                kept and string.format("; %s breaks %s", kept.name, pvp.breaks_text(kept.breaks)) or ""))
                        end
                    elseif points then
                        local key = string.format("pvp_break:%s:%s", tostring(ctl.id or ctl.name), ctl.mech)
                        -- The cheapest that clears its line is the answer, and
                        -- nothing dearer is offered beside it. One held is shown
                        -- (the cheapest), and the trinket whenever it is held:
                        -- that is the line a player wants to read.
                        local shown = false
                        for j = 1, #options do
                            local o = options[j]
                            local line, mode = line_for(o.cost)
                            local go = points >= line
                            if go or not shown or o.cost == "trinket" then
                                shown = true
                                local c = offer({
                                    name = o.name, kind = o.kind, item = o.item, target = o.target,
                                    target_kind = o.target_kind, lane = o.lane, event_key = key,
                                    handled_for = 1.5, why = ctl.name,
                                })
                                c.reasons_in, c.cost = reasons, o.cost
                                if not go then
                                    c:wait(string.format("held: %s is worth %d, %s needs %d%s", ctl.name, points,
                                        o.cost == "trinket" and "the trinket" or o.name, line,
                                        mode and (" (" .. mode .. ")") or ""))
                                end
                            end
                            if go then break end
                        end
                    elseif skip and #options > 0 and options[#options].cost == "trinket" and ctl.helpless then
                        say_once("pvp_tail:" .. ctl.mech, "trinket held: " .. skip)
                    end
                end
            end
        end,
        score = function(W, c)
            for i = 1, #(c.reasons_in or {}) do c:add(c.reasons_in[i][1], c.reasons_in[i][2]) end
            -- Cheaper first, between two that would both do.
            c:add((COST_ORDER[c.cost] or 1) * 2, "cost: " .. tostring(c.cost))
        end,
    })

    -- ==========================================================================
    -- 87  STOP THE CAST
    -- ==========================================================================
    --
    -- The core "Interrupt" kicks with the class's interrupt. This is for the
    -- moment it is not ready, or the cast is aimed at you and nothing can
    -- kick it: a stun or a fear stops a cast as surely as a kick does, and
    -- some answers make the cast land on nothing. One event per cast (the
    -- core's cast key), so the two never answer the same cast twice.

    -- A stun, an incapacitate or a fear the class can throw at a caster.
    -- `reach`: yards from you to the caster; `around`: it goes off around
    -- you, so it is cast on yourself.
    local STOPPERS = {
        WARRIOR = { { name = "Concussion Blow", reach = 5 }, { name = "Intercept", reach = 25, from = 8 },
                    { name = "Intimidating Shout", reach = 10 } },
        ROGUE = { { name = "Kidney Shot", reach = 5 }, { name = "Gouge", reach = 5 }, { name = "Blind", reach = 10 } },
        PRIEST = { { name = "Psychic Scream", reach = 8, around = true } },
        WARLOCK = { { name = "Death Coil", reach = 30 }, { name = "Howl of Terror", reach = 10, around = true } },
    }
    local RACIAL_STOPPERS = { { name = "War Stomp", reach = 8, around = true } }

    -- Aimed at you: make it land on nothing. `mechs`: only for a cast of
    -- these; `left`: pressed this close to the end of the cast.
    local PREEMPT = {
        { name = "Grounding Totem", any = true, left = 1.5, class = "SHAMAN" },
        { name = "Tremor Totem", mechs = { fear = true, charm = true, sleep = true }, left = 2.5, class = "SHAMAN",
          lasts = 120 },
        { name = "Berserker Rage", mechs = { fear = true }, left = 0.8, class = "WARRIOR" },
        { name = "Fear Ward", mechs = { fear = true }, left = 2.0, class = "PRIEST" },
    }

    local function interrupt_ready(W, unit)
        local list = (W.class and W.class.interrupts) or {}
        for i = 1, #list do
            if usable(list[i]) then
                local castable = book.castable
                if not castable or castable(list[i], unit) then return list[i] end
            end
        end
        return nil
    end

    R.add_rule({
        name = "PvP: stop the cast",
        category = "interrupt", priority = 87,
        needs = { "casting", "combat" },
        wake = { "jcore.enemy.casting" },
        retry = { hold = 1.0 },
        propose = function(W, offer)
            local V = W.pvp
            if not V or not V.active then return end
            if V.control and V.control.helpless then return end
            local cls = class_name(W)

            local function consider(cast, unit, guid, current, dist)
                if not unit or cast.remaining <= 0.15 then return end
                local mech = pvp.SPELL_MECH[cast.name]
                local wanted = (cast.danger or 0) >= detect.DANGEROUS or mech ~= nil
                if not wanted then return end
                local key = lib.cast_key(guid, cast)

                -- Aimed at you, and nothing kicks it: let it land on nothing.
                if cast.at_me then
                    for i = 1, #PREEMPT do
                        local p = PREEMPT[i]
                        if p.class == cls and (p.any or (mech and p.mechs[mech])) and cast.remaining <= p.left
                            and usable(p.name) and not (p.lasts and lib.memory.since_success(p.name) < p.lasts) then
                            local c = offer({ name = p.name, target = W.player.unit, target_kind = "self",
                                              event_key = key, handled_for = cast.remaining + 0.5,
                                              why = string.format("%s at you", cast.name) })
                            c.cast, c.preempt = cast, true
                            return
                        end
                    end
                    -- A druid in a form cannot be sheeped.
                    if mech == "polymorph" and cls == "DRUID" and cast.remaining <= 0.8 then
                        local current_form = P.forms and P.forms.current and try(P.forms.current) or nil
                        if not current_form then
                            for i = 1, #FORMS_ANY do
                                if usable(FORMS_ANY[i]) then
                                    local c = offer({ name = FORMS_ANY[i], target = W.player.unit, target_kind = "self",
                                                      event_key = key, handled_for = cast.remaining + 0.5,
                                                      why = "Polymorph at you: a form cannot be sheeped" })
                                    c.cast, c.preempt = cast, true
                                    return
                                end
                            end
                        end
                    end
                end

                -- The class's interrupt is ready and reaches: the core's. A
                -- stun or a fear stops a cast the kick could not, so the
                -- cast's own "interruptible" is not asked here.
                if interrupt_ready(W, unit) then return end
                local options = {}
                for _, o in ipairs(STOPPERS[cls] or {}) do options[#options + 1] = o end
                for _, o in ipairs(RACIAL_STOPPERS) do options[#options + 1] = o end
                for i = 1, #options do
                    local o = options[i]
                    if dist <= o.reach and dist >= (o.from or 0) and usable(o.name) and not pvp.blocks(o.name, unit) then
                        local c = offer({
                            name = o.name, target = o.around and W.player.unit or unit,
                            target_kind = o.around and "self" or "enemy",
                            event_key = key, handled_for = cast.remaining + 0.5, why = cast.name,
                            offensive = not cast.at_me,
                        })
                        c.cast, c.current = cast, current
                        return
                    end
                end
            end

            local tg = W.target
            if tg.player and tg.casting and tg.unit and not tg.others_fight then
                tg.cast.at_me = tg.targets_me
                consider(tg.cast, tg.unit, tg.guid, true, dist_to(tg.unit, tg.distance))
            end
            local en = W.enemies
            for i = 1, en.casting_n do
                local cast = en.casting[i]
                if cast.player and not cast.current and (cast.engaged or cast.at_group or cast.at_me) then
                    consider(cast, cast.unit, cast.guid, false, dist_to(cast.unit, cast.dist))
                end
            end
        end,
        score = function(W, c)
            local cast = c.cast
            local label = cast.name ~= "" and cast.name or "a cast"
            c:add(cast.danger or 0, string.format("%s (%s)", label, cast.kind or "cast"))
            if cast.remaining <= 1.0 then
                c:add(25, string.format("cast ends in %.1fs", cast.remaining))
            elseif cast.remaining <= 2.0 then
                c:add(12, string.format("cast ends in %.1fs", cast.remaining))
            end
            if cast.at_me then c:add(8, "aimed at you") end
            if c.preempt then
                c:add(5, "it lands on nothing")
            else
                c:add(-6, "crowd control used as an interrupt")
            end
        end,
    })

    -- ==========================================================================
    -- 82  ANSWER THE BURST
    -- ==========================================================================
    --
    -- A player on you with Recklessness, Death Wish, Adrenaline Rush, Blade
    -- Flurry, Cold Blood, Rapid Fire (physical) or Arcane Power, Combustion,
    -- Power Infusion, Presence of Mind, Elemental Mastery (spells). Ten
    -- seconds of that is the fight; ten seconds of them out of it, or of you
    -- out of reach of it, is the answer. In order, best first; anything the
    -- burster is immune to is passed over (Recklessness and Death Wish make
    -- a warrior fearless, so a fear is not the answer to them).
    --   reach  yards from you to the burster      self    cast on yourself
    --   far    only this far away or more         melee   only within 8 yards
    --   hp     only under this health

    local ANSWERS = {
        WARRIOR = {
            physical = { { name = "Disarm", reach = 5 }, { name = "Intimidating Shout", reach = 10 },
                         { name = "Concussion Blow", reach = 5 }, { name = "Shield Wall", self = true, hp = 0.6 } },
            spell = { { name = "Concussion Blow", reach = 5 }, { name = "Intimidating Shout", reach = 10 } },
        },
        ROGUE = {
            physical = { { name = "Evasion", self = true, melee = true }, { name = "Blind", reach = 10 },
                         { name = "Gouge", reach = 5 }, { name = "Kidney Shot", reach = 5 } },
            spell = { { name = "Kidney Shot", reach = 5 }, { name = "Gouge", reach = 5 }, { name = "Blind", reach = 10 } },
        },
        MAGE = {
            physical = { { name = "Frost Nova", self = true, reach = 10 }, { name = "Polymorph", reach = 30, far = 8 },
                         { name = "Ice Block", self = true, hp = 0.35 }, { name = "Ice Barrier", self = true } },
            spell = { { name = "Polymorph", reach = 30 }, { name = "Ice Barrier", self = true },
                      { name = "Ice Block", self = true, hp = 0.35 } },
        },
        PRIEST = {
            physical = { { name = "Psychic Scream", self = true, reach = 8 }, { name = "Power Word: Shield", self = true } },
            spell = { { name = "Psychic Scream", self = true, reach = 8 }, { name = "Power Word: Shield", self = true } },
        },
        WARLOCK = {
            physical = { { name = "Death Coil", reach = 30 }, { name = "Howl of Terror", self = true, reach = 10 },
                         { name = "Fear", reach = 20, far = 8 } },
            spell = { { name = "Death Coil", reach = 30 }, { name = "Fear", reach = 20 } },
        },
        PALADIN = {
            physical = { { name = "Hammer of Justice", reach = 10 }, { name = "Blessing of Protection", self = true },
                         { name = "Divine Protection", self = true, hp = 0.5 }, { name = "Divine Shield", self = true, hp = 0.4 } },
            spell = { { name = "Hammer of Justice", reach = 10 }, { name = "Divine Shield", self = true, hp = 0.4 } },
        },
        DRUID = {
            physical = { { name = "Bash", reach = 5 }, { name = "Nature's Grasp", self = true },
                         { name = "Barkskin", self = true }, { name = "Entangling Roots", reach = 30, far = 8 } },
            spell = { { name = "Bash", reach = 5 }, { name = "Barkskin", self = true } },
        },
        HUNTER = {
            physical = { { name = "Scatter Shot", reach = 15 }, { name = "Deterrence", self = true, melee = true },
                         { name = "Wing Clip", reach = 5 }, { name = "Concussive Shot", reach = 35, far = 8 } },
            spell = { { name = "Scatter Shot", reach = 15 } },
        },
        SHAMAN = {
            physical = { { name = "Earthbind Totem", self = true, reach = 10 }, { name = "Frost Shock", reach = 20 },
                         { name = "Stoneclaw Totem", self = true } },
            spell = { { name = "Grounding Totem", self = true } },
        },
    }

    R.add_rule({
        name = "PvP: answer the burst",
        category = "defensive", priority = 82,
        needs = { "combat" },
        every = 0.1,
        retry = { hold = 2.0 },
        propose = function(W, offer)
            local V = W.pvp
            local b = V and V.active and V.burster or nil
            if not b or (V.control and V.control.helpless) then return end
            local st = b.st
            local list = (ANSWERS[class_name(W)] or {})[st.burst] or {}
            local d = dist_to(b.unit, b.dist)
            for i = 1, #list do
                local a = list[i]
                local fits = (not a.reach or d <= a.reach) and (not a.far or d >= a.far)
                    and (not a.melee or d <= 8) and (not a.hp or W.player.hp < a.hp)
                -- A defensive on yourself is not the burster's to be immune
                -- to; a scream or a nova around you is.
                local own = a.self and not pvp.SPELL_MECH[a.name]
                if fits and usable(a.name) and (own or not pvp.blocks(a.name, b.unit)) then
                    local c = offer({
                        name = a.name, target = a.self and W.player.unit or b.unit,
                        target_kind = a.self and "self" or "enemy",
                        event_key = string.format("burst:%s:%s", tostring(b.guid), tostring(st.burst_name)),
                        handled_for = 4, why = string.format("%s: %s", name_of(b.unit), st.burst_name),
                    })
                    c.b = b
                    return
                end
            end
        end,
        score = function(W, c)
            local st = c.b.st
            local left = st.burst_left or 0
            if left < huge then
                c:add(min(15, floor(left + 0.5)), string.format("%s, %.0fs left", st.burst_name, left))
            else
                c:add(10, st.burst_name)
            end
            local pl = W.player
            if pl.hp < 0.4 then
                c:add(20, string.format("health %d%%", pct(pl.hp)))
            elseif pl.hp < 0.6 then
                c:add(10, string.format("health %d%%", pct(pl.hp)))
            end
            local n = W.pvp.attackers or 0
            if n >= 2 then c:add(min(15, (n - 1) * 8), string.format("%d players on you", n)) end
        end,
        -- The cooldown economy (intel/cooldowns.lua, Stage 3): a defensive on
        -- yourself is held while the protection already up covers the burst
        -- -- never under critical health. A control on the burster still goes.
        validate = function(W, c)
            local I = P.react and P.react.intel
            local cds = I and I.cooldowns
            if cds and W.intel and W.intel.active then return cds.hold_answer(W, c) end
            return nil
        end,
    })

    -- ==========================================================================
    -- 70  OFF THE IMMUNE TARGET
    -- ==========================================================================
    --
    -- Divine Shield or Ice Block on your target: nothing lands for ten
    -- seconds (the rotation's usable check already holds every press into
    -- it, rotation.lua via pvp.blocks, and the auto-target skips it via
    -- out_of_fight). For a warrior or a rogue, Blessing of Protection is the
    -- same. Another enemy something lands on, a player first: switched to.

    local PHYSICAL_ONLY = pvp.PHYSICAL_ONLY

    R.add_rule({
        name = "PvP: off the immune target",
        category = "utility", priority = 70, kind = "set_target", lane = "fast",
        needs = { "combat", "target" },
        every = 0.25,
        retry = { hold = 2.0 },
        propose = function(W, offer)
            local V = W.pvp
            local st = V and V.target
            if not st or not st.immune then return end
            local phys_only = PHYSICAL_ONLY[class_name(W)] == true
            if st.immune == "physical" and not phys_only then return end
            if (st.immune_left or 0) < 2 then return end
            local best, best_rank, best_d = nil, -1, huge
            local rows, n = W.enemies.list or {}, W.enemies.count or 0
            for i = 1, n do
                local r = rows[i]
                if r and r.obj and r.guid ~= W.target.guid and (r.dist or huge) <= 30 and (r.hp or 1) > 0
                    and (r.engaged or r.targeting_me) then
                    local player = pvp.is_player(r.obj, r.guid)
                    local other = player and pvp.state(r.obj, r.guid) or nil
                    local blocked = other and (other.immune == "all" or (other.immune == "physical" and phys_only))
                    if not blocked then
                        local rank = (player and 2 or 0) + (r.targeting_me and 1 or 0)
                        local d = r.dist or huge
                        if rank > best_rank or (rank == best_rank and d < best_d) then
                            best, best_rank, best_d = r, rank, d
                        end
                    end
                end
            end
            if not best then return end
            offer({
                name = "Target " .. name_of(best.obj), kind = "set_target", target = best.obj, target_kind = "enemy",
                event_key = "immune:" .. tostring(W.target.guid), handled_for = 3,
                why = string.format("%s is in %s", name_of(W.target.unit), st.immune_name),
            })
        end,
        score = function(W, c)
            c:add(10, c.why or "immune")
        end,
    })

    -- ==========================================================================
    -- 64  FIND THE STEALTHY
    -- ==========================================================================
    --
    -- A player who was on you, alive, inside fifteen yards and is suddenly
    -- gone went into Vanish, Stealth or Shadowmeld. An area hit around you
    -- brings them out (the client hits what it cannot show you); a hunter's
    -- Flare on the spot shows them. A Human who suspects a stealthed player
    -- about (sense.lua) has Perception.

    local REVEAL = {
        MAGE = { { name = "Arcane Explosion", reach = 10 }, { name = "Frost Nova", reach = 10 } },
        PRIEST = { { name = "Holy Nova", reach = 10 } },
        PALADIN = { { name = "Consecration", reach = 8 } },
        WARRIOR = { { name = "Thunder Clap", reach = 8 } },
    }

    R.add_rule({
        name = "PvP: find the stealthy",
        category = "utility", priority = 64,
        every = 0.1,
        retry = { hold = 2.0 },
        propose = function(W, offer)
            local V = W.pvp
            if not V then return end
            if V.control and V.control.helpless then return end
            local v = V.vanished
            local cls = class_name(W)
            if v then
                local key = "vanish:" .. tostring(v.guid)
                if cls == "HUNTER" and v.pos and usable("Flare") then
                    local c = offer({ name = "Flare", target_kind = "ground", position = v.pos,
                                      event_key = key, handled_for = 4, why = "a player vanished here" })
                    c.v = v
                    return
                end
                for _, o in ipairs(REVEAL[cls] or {}) do
                    if (v.dist or huge) <= o.reach and usable(o.name) then
                        local c = offer({ name = o.name, target = W.player.unit, target_kind = "self",
                                          event_key = key, handled_for = 4,
                                          why = string.format("a player vanished %.0f yd away", v.dist or 0) })
                        c.v = v
                        return
                    end
                end
            end
            local sense = P.sense
            if sense and sense.stealth_suspected and usable("Perception")
                and (V.active or (W.env.context == "pvp")) then
                local suspected, who = sense.stealth_suspected()
                if suspected then
                    offer({ name = "Perception", target = W.player.unit, target_kind = "self",
                            event_key = "perception", handled_for = 20, why = who or "stealth about" })
                end
            end
        end,
        score = function(W, c)
            if c.v then c:add(15, "a player vanished beside you") end
        end,
    })

    -- ==========================================================================
    -- 58  PURGE
    -- ==========================================================================
    --
    -- Only Magic comes off, and the client picks which: so only a player
    -- carrying something worth a global cooldown (pvp.lua's ENEMY values:
    -- Blessing of Protection 30, Power Infusion 30, Arcane Power 25, Nature's
    -- Swiftness 25, Innervate 25, a shield 20, Blessing of Freedom 20...).
    -- The target first, then the players on you. A felhunter's Devour Magic
    -- is free and goes in the pet's lane.

    local PURGERS = { SHAMAN = "Purge", PRIEST = "Dispel Magic" }
    local PURGE_FLOOR = 8

    R.add_rule({
        name = "PvP: purge",
        category = "utility", priority = 58,
        needs = { "combat" },
        every = 0.2,
        retry = { hold = 1.5 },
        propose = function(W, offer)
            local V = W.pvp
            if not V or not V.active or (V.control and V.control.helpless) then return end
            local cls = class_name(W)
            local spell = PURGERS[cls]
            if spell and not usable(spell) then spell = nil end
            if spell and W.player.power_kind == "MANA" and W.player.power_pct < 0.2 then spell = nil end
            local pet = cls == "WARLOCK" and W.pet.alive and P.pet and P.pet.knows and P.pet.knows("Devour Magic")
            if not spell and not pet then return end

            local function consider(unit, guid, st, current)
                local best = st and st.purge_best
                if not best or best.value < PURGE_FLOOR or st.immune == "all" then return false end
                local key = string.format("purge:%s:%s", tostring(guid), best.name)
                if spell then
                    local c = offer({ name = spell, target = unit, target_kind = "enemy", event_key = key,
                                      handled_for = 2, why = best.name })
                    c.st, c.current = st, current
                end
                if pet then
                    local c = offer({ name = "Devour Magic", kind = "pet_spell", target = unit, target_kind = "enemy",
                                      event_key = key, handled_for = 2, why = best.name })
                    c.st, c.current = st, current
                end
                return true
            end

            local tg = W.target
            if V.target and tg.unit and consider(tg.unit, tg.guid, V.target, true) then return end
            local rows, n = W.enemies.list or {}, W.enemies.count or 0
            for i = 1, n do
                local r = rows[i]
                if r and r.obj and r.targeting_me and r.guid ~= tg.guid and (r.dist or huge) <= 30
                    and pvp.is_player(r.obj, r.guid) then
                    if consider(r.obj, r.guid, pvp.state(r.obj, r.guid), false) then return end
                end
            end
        end,
        score = function(W, c)
            local st = c.st
            c:add(st.purge_best.value, st.purge_best.name)
            local rest = (st.purge_total or 0) - st.purge_best.value
            if rest > 0 then c:add(min(10, floor(rest / 2)), "and more on it") end
            if c.current then c:add(5, "your target") end
        end,
    })
end

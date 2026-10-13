-- Jambix AIO / react / rules / core -- the reactions every class shares.
--
-- A REACTION IS DATA
--
--   {
--       name      = "Interrupt",            unique; the debug view shows it
--       category  = "interrupt",            survival | bailout | interrupt | cc | escape |
--                                           defensive | pet | threat | utility | buff | low
--       priority  = 90,                     the base score
--       lane      = "gcd" | "fast",         which arbiter lane it competes in
--       needs     = { "combat", "pet" },    cheap gates: combat, pet, target, group, casting
--       every     = 0.2,                    seconds between evaluations (0: every tick)
--       wake      = { "jcore.enemy.casting" },  events that force an evaluation now
--       enabled   = function(W) ... end,    the setting that governs it
--       retry     = { hold = 2 },           seconds after an attempt before another
--       owns      = { "Mend Pet" },         spells nothing else may cast while it is on
--
--       -- the simple form
--       condition = function(W) ... end,
--       action    = "Counter Shot" | { "A", "B" } | function(W) ... end,
--       target    = "enemy" | "self" | "pet" | function(W) ... end,
--
--       -- or the full form: offer as many candidates as there are answers
--       propose   = function(W, offer) offer({ name, target, event_key, ... }) end,
--
--       score     = function(W, c) c:add(25, "cast ends in 0.8s") end,
--       validate  = function(W, c) return "reason not to" end,     optional
--   }
--
-- The engine supplies everything else: the score's mode and memory terms,
-- the safety checks, the cast, and remembering it. A rule here never casts.
-- Base priorities follow one scale:
--
--   100 survival   95 bail-out   90 interrupt   88 escape   85 crowd control
--    80 defensive  70 pet         65 threat      60 utility  50 buff upkeep
--    40 the rotation itself       20 low-priority utility

return function(R, P, lib)
    local book = P.spellbook
    local units = P.units
    local memory, detect = lib.memory, lib.detect
    local floor, min = math.floor, math.min

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    local function H() return (P.rotation and P.rotation.helpers) or {} end

    local function key_allows(name)
        local h = H()
        return not h.key_allows or h.key_allows(name)
    end

    --- The unit an escape or defensive is cast on: ours, or the enemy's.
    local function escape_target(name, W)
        local h = H()
        if h.escape_target then return h.escape_target(name, W.s) end
        return W.player.unit
    end

    local function kind_of(unit, W)
        if unit == W.player.unit then return "self" end
        if unit == W.pet.unit then return "pet" end
        return "enemy"
    end

    -- ==========================================================================
    -- 100  SURVIVAL: the bag
    -- ==========================================================================
    --
    -- Predictive: health heading under the potion line in the next two seconds
    -- is treated as under it. Waiting for the bar to cross a line it is going
    -- to cross anyway is two seconds of health the potion does not get back.

    R.add_rule({
        name = "Emergency potion",
        category = "survival", priority = 100, lane = "fast", kind = "item",
        needs = { "combat" },
        retry = { hold = 1.5 },
        propose = function(W, offer)
            local pl, line = W.player, W.thresholds.potion_hp
            local now_low = pl.hp <= line
            local soon_low = not now_low and pl.hp_rate < 0 and pl.projected <= line
                and pl.hp <= line + 0.15
            if not now_low and not soon_low then return end
            -- Under the line but nothing is hitting us and the bar is steady:
            -- a potion now is a potion missing from the next fight.
            if now_low and pl.hp_rate >= 0 and W.enemies.on_me == 0 and not W.bailout then return end
            -- Stunned, feared, sheeped: nothing can be drunk, and every
            -- refusal backs the potion off for the moment the control ends
            -- (1.81.0; react/pvp.lua says which controls those are).
            local ctl = W.pvp and W.pvp.control
            if ctl and ctl.helpless then return end
            for _, kind in ipairs({ "healthstone", "potion" }) do
                if pl[kind] then
                    local _, item_name = P.hardcore.item(kind)
                    local c = offer({
                        name = item_name or kind, kind = "item", item = kind,
                        event_key = "consumable", handled_for = 1.5,
                    })
                    c.soon = soon_low
                    return
                end
            end
        end,
        score = function(W, c)
            local pl, line = W.player, W.thresholds.potion_hp
            if pl.hp < line then
                c:add(min(30, (line - pl.hp) * 150),
                    string.format("health %d%% under the %d%% line", pct(pl.hp), pct(line)))
            end
            if c.soon then
                c:add(5, string.format("falling %.0f%%/s: under the line within 2s", -pl.hp_rate * 100))
            end
            if pl.hp_rate < -0.05 then c:add(10, "falling fast") end
        end,
    })

    -- ==========================================================================
    -- 96 / 95  HARDCORE
    -- ==========================================================================
    --
    -- The bail-out is a STATE, not an action: while it holds, nothing offensive
    -- goes out -- not the rotation, not an offensive reaction -- and the
    -- potions, escapes and defensives above it still do. It is offered as a
    -- "hold" so the debug view says why the rotation went quiet.

    R.add_rule({
        name = "Hardcore bail-out",
        category = "bailout", priority = 95, kind = "hold",
        needs = { "combat" },
        enabled = function() return opt("hc_enabled", true) end,
        propose = function(W, offer)
            if not W.bailout then return end
            -- Nothing to wait for: no potion, defensive or escape left. The
            -- hold would only stand us still while the mob keeps hitting.
            if W.fight_on then
                if lib.journal then
                    lib.journal("bailout", "bail-out: nothing left to bail out with -- fighting on", "fight_on")
                end
                return
            end
            offer({
                name = "Stop attacking", kind = "hold",
                why = string.format("health %d%%, bail-out line %d%%", pct(W.player.hp), pct(W.thresholds.bail_hp)),
            })
        end,
    })

    R.add_rule({
        name = "Hearthstone out",
        category = "survival", priority = 96, kind = "item",
        needs = { "combat" },
        enabled = function() return opt("hc_enabled", true) and opt("hc_hearth", false) end,
        retry = { hold = 30 },
        propose = function(W, offer)
            if not W.bailout or W.player.hp > W.thresholds.hearth_hp then return end
            local id = P.hardcore and P.hardcore.item and P.hardcore.item("hearthstone")
            if not id then return end
            offer({ name = "Hearthstone", kind = "item", item = "hearthstone",
                    event_key = "hearth", handled_for = 30 })
        end,
        score = function(W, c)
            if W.enemies.on_me == 0 then
                c:add(10, "nothing on you: the cast can finish")
            else
                c:add(-10, "being hit: the cast will be pushed back")
            end
        end,
    })

    -- ==========================================================================
    -- 90  INTERRUPT
    -- ==========================================================================
    --
    -- The target's cast first, then every caster engaged with us or our group:
    -- the healer at the back is the cast worth kicking, and it was never the
    -- target. One candidate per (cast, interrupt), so the scoring chooses
    -- between kicking the heal and kicking the bolt.
    --
    -- PREDICTIVE. A dangerous cast is kicked as soon as it is seen. A harmless
    -- one is left until its last two seconds: an interrupt spent early on a
    -- filler is one not ready for the heal that follows it. Each cast is one
    -- event (caster, spell, start time), handled once.

    local function cast_key(guid, cast)
        return string.format("cast:%s:%s:%s", tostring(guid), tostring(cast.spell_id), tostring(cast.started))
    end
    lib.cast_key = cast_key

    --- The cast the PvP intelligence's team read says to stop first (react/
    --- intel/team.lua, Stage 10: a heal on a low enemy, a control at one of
    --- us, a dangerous cast), or nil. The three cast-stopping reactions take
    --- its caster even when it is not engaged with us (Stage 14).
    function lib.team_pick(W)
        local S = W and W.intel
        local T = S and S.active and not S.off and S.team or nil
        return T and T.interrupt or nil
    end

    --- Does this spell take this unit at all (1.77.4)? A class may say a spell
    --- works only on some creature types (`creature_types`: Repentance
    --- humanoids). One that does not take it is passed over, so the next in
    --- the list is asked rather than a press the client refuses. A type the
    --- client does not say: yes.
    local function takes(name, unit, W)
        local only = W.class and W.class.creature_types and W.class.creature_types[name]
        if type(only) ~= "table" or not unit then return true end
        local ok, kind = pcall(unit.get_creature_type, unit)
        if not ok or type(kind) ~= "number" or kind <= 0 then return true end
        for i = 1, #only do
            if only[i] == kind then return true end
        end
        return false
    end

    R.add_rule({
        name = "Interrupt",
        category = "interrupt", priority = 90,
        needs = { "casting" },
        wake = { "jcore.enemy.casting" },
        propose = function(W, offer)
            local class = W.class or {}
            local list = class.interrupts or {}
            local pets = W.pet.alive and class.pet_interrupts or nil
            if #list == 0 and not pets then return end

            local function consider(cast, unit, guid)
                if not cast.interruptible or cast.remaining <= 0.1 or not unit then return end
                local key = cast_key(guid, cast)
                local spell, first_known = nil, nil
                for i = 1, #list do
                    if book.known(list[i]) and takes(list[i], unit, W) then
                        first_known = first_known or list[i]
                        if book.ready(list[i]) then spell = list[i] break end
                    end
                end
                spell = spell or first_known
                if spell then
                    local c = offer({
                        name = spell, target = unit, target_kind = "enemy",
                        event_key = key, handled_for = cast.remaining + 0.5, why = cast.name,
                        offensive = not (cast.at_me and cast.danger >= detect.DANGEROUS),
                    })
                    c.cast = cast
                end
                if pets then
                    for i = 1, #pets do
                        if P.pet.knows and P.pet.knows(pets[i]) then
                            local c = offer({
                                name = pets[i], kind = "pet_spell", target = unit, target_kind = "enemy",
                                event_key = key, handled_for = cast.remaining + 0.5, why = cast.name,
                            })
                            c.cast, c.pet = cast, true
                            break
                        end
                    end
                end
            end

            local tg = W.target
            -- Not a stranger's mob: the kick would only pull it onto us.
            if tg.casting and tg.unit and not tg.others_fight then
                local cast = tg.cast
                cast.at_me, cast.at_pet = tg.targets_me, tg.targets_pet
                cast.at_group, cast.at_healer = tg.targets_group, false
                cast.boss, cast.elite, cast.current = tg.boss, tg.elite, true
                consider(cast, tg.unit, tg.guid)
            end
            -- At most three more, nearest first: a raid full of casters must
            -- not turn into a candidate per caster per frame. The team read's
            -- pick (a healer healing its friend is engaged with nobody) is
            -- taken whatever the count.
            local en, extra = W.enemies, 0
            local pick = lib.team_pick(W)
            for i = 1, en.casting_n do
                local cast = en.casting[i]
                local picked = pick ~= nil and cast.guid == pick.guid
                if not cast.current and (picked or (extra < 3 and (cast.engaged or cast.at_group))) then
                    if not picked then extra = extra + 1 end
                    cast.team_pick = picked and pick or nil
                    consider(cast, cast.unit, cast.guid)
                end
            end
        end,
        score = function(W, c)
            local cast = c.cast
            local label = (cast.name ~= "" and cast.name) or "a cast"
            if cast.team_pick then c:add(15, "the team's first cast to stop: " .. tostring(cast.team_pick.why or cast.team_pick.kind)) end
            if cast.danger >= detect.DANGEROUS then
                c:add(cast.danger, string.format("dangerous cast (%s)", label))
            elseif cast.danger > 0 then
                c:add(floor(cast.danger / 2), string.format("cast: %s", label))
            end
            local left = cast.remaining
            if left <= 1.0 then
                c:add(25, string.format("cast ends in %.1fs", left))
            elseif left <= 2.0 then
                c:add(12, string.format("cast ends in %.1fs", left))
            elseif cast.danger < detect.DANGEROUS and not cast.channel then
                c:wait(string.format("%.1fs left on a harmless cast: kick it late", left))
            end
            if cast.boss then
                c:add(9, "boss caster")
            elseif cast.elite then
                c:add(5, "elite caster")
            end
            if cast.at_me then
                c:add(8, "aimed at you")
            elseif cast.at_healer then
                c:add(8, "aimed at the healer")
            elseif cast.at_pet then
                c:add(3, "aimed at the pet")
            end
            if cast.channel then c:add(5, "a channel: every tick counts") end
            if cast.current then c:add(3, "your target") end
            if c.pet then c:add(-5, "the pet's (yours is preferred)") end
        end,
    })

    -- ==========================================================================
    -- 88  ESCAPE
    -- ==========================================================================
    --
    -- When the fight cannot be won (the field says FLEE), the survival options
    -- have run out (ESCAPE), or a hardcore bail-out is on. The class lists its
    -- escapes best first; a fear or a blink breaks contact with everything,
    -- a slow with one pursuer. Key-gated abilities stay gated here too.

    --- The PvP intelligence's word (Stage 14): its tactical state, or nil
    --- without an active picture.
    local function intel_state(W)
        local S = W.intel
        local X = S and S.active and not S.off and S.tactic or nil
        return X and X.state or nil
    end
    --- Its threat level with a player on you, or nil.
    local function intel_threat(W)
        local S = W.intel
        local T = S and S.active and not S.off and (S.attackers or 0) > 0 and S.threat or nil
        if not T or not opt("intel_threat", true) then return nil end
        return T.level, T.highest and T.highest.why or nil
    end

    R.add_rule({
        name = "Break contact",
        category = "escape", priority = 88,
        needs = { "combat" },
        retry = { hold = 5 },
        propose = function(W, offer)
            local bail = W.bailout and opt("hc_enabled", true)
            -- Or the PvP intelligence's DISENGAGE (Stage 14): the threat
            -- CRITICAL with no defensive left, or the fight cannot be won.
            local disengage = intel_state(W) == "DISENGAGE"
            local losing = W.sit.flee or W.mode == "ESCAPE" or disengage
            if not bail and not losing then return end
            local list = (W.class and W.class.escapes) or {}
            for i = 1, #list do
                local name = list[i]
                if book.known(name) and book.ready(name) and key_allows(name) then
                    local target = escape_target(name, W)
                    if target then
                        local c = offer({ name = name, target = target, target_kind = kind_of(target, W),
                                          why = bail and "hardcore bail-out" or (disengage and "PvP: disengage") or W.field.reason })
                        c.bail, c.losing, c.disengage = bail, losing, disengage
                        return
                    end
                end
            end
        end,
        score = function(W, c)
            local on = W.enemies.on_me
            if on > 1 then c:add(min(20, (on - 1) * 10), string.format("%d on you", on)) end
            if c.bail then c:add(10, "hardcore bail-out") end
            if c.losing and W.sit.flee then c:add(10, "the fight cannot be won") end
            if c.disengage then c:add(10, "PvP: " .. tostring(W.intel.tactic.why)) end
        end,
    })

    -- ==========================================================================
    -- 85  CROWD CONTROL: take the add out of the fight
    -- ==========================================================================
    --
    -- When the fight is going badly and something besides the target is on
    -- us. CROWD CONTROL STILL WAITS TO BE ASKED where a mistake costs more
    -- than it saves: in a group (a fear runs into the next pack, a sheep gets
    -- broken) it fires only while the crowd-control key is held, and a class's
    -- key-gated abilities stay gated everywhere. An area effect is never used
    -- while anything nearby is already controlled.

    local CC_ROLES = { "cc", "stun", "disorient", "sleep", "fear" }
    local AREA_CC = {
        ["Psychic Scream"] = true, ["Intimidating Shout"] = true, ["Howl of Terror"] = true,
        ["Frost Nova"] = true, ["War Stomp"] = true, ["Blast Wave"] = true,
    }
    -- What each class can throw at an add when the catalogue has no word on it.
    local CC_FALLBACK = {
        WARRIOR = { "Intimidating Shout" }, ROGUE = { "Gouge", "Blind" },
        MAGE = { "Polymorph", "Frost Nova" }, WARLOCK = { "Fear", "Death Coil", "Howl of Terror" },
        PRIEST = { "Psychic Scream" }, PALADIN = { "Repentance", "Hammer of Justice" },
        DRUID = { "Entangling Roots", "Hibernate" }, SHAMAN = { "Frost Shock" },
        HUNTER = { "Scatter Shot", "Wyvern Sting" },
    }

    local cc_cache, cc_at = nil, -1
    local function cc_spells(W)
        if cc_cache and (W.now - cc_at) < 1.0 then return cc_cache end
        cc_at = W.now
        local out, seen = {}, {}
        local catalog = P.catalog
        if catalog and catalog.with_role then
            for _, role in ipairs(CC_ROLES) do
                local rows = catalog.with_role(role, true)
                for i = 1, #rows do
                    local name = rows[i].name
                    if not seen[name] and rows[i].range ~= "self" then
                        seen[name] = true
                        out[#out + 1] = name
                    end
                end
            end
        end
        local fallback = W.class and CC_FALLBACK[W.class.class_name or ""] or nil
        for i = 1, #(fallback or {}) do
            if not seen[fallback[i]] and book.known(fallback[i]) then
                seen[fallback[i]] = true
                out[#out + 1] = fallback[i]
            end
        end
        cc_cache = out
        return out
    end

    R.add_rule({
        name = "Crowd control an add",
        category = "cc", priority = 85,
        needs = { "combat" },
        every = 0.2,
        retry = { hold = 4 },
        propose = function(W, offer)
            if (W.mode_level or 0) < 2 and not W.sit.adds then return end
            local armed = P.key_armed and P.key_armed("rot_fear_key") or false
            if not W.env.solo and not armed then return end

            local add = nil
            local list, n = W.enemies.list or {}, W.enemies.count or 0
            for i = 1, n do
                local row = list[i]
                if row and row.obj and row.engaged and row.targeting_me and not row.control
                    and row.guid ~= W.target.guid then
                    add = row
                    break
                end
            end
            if not add then return end
            if memory.handled("cc:" .. tostring(add.guid)) then return end

            local spells = cc_spells(W)
            for i = 1, #spells do
                local name = spells[i]
                if book.ready(name) and key_allows(name) and takes(name, add.obj, W)
                    and not (AREA_CC[name] and W.enemies.controlled > 0) then
                    local c = offer({
                        name = name, target = add.obj, target_kind = "enemy",
                        event_key = "cc:" .. tostring(add.guid), handled_for = 8,
                        why = units.name and units.name(add.obj) or "the add",
                    })
                    c.add_row = add
                    return
                end
            end
        end,
        score = function(W, c)
            local on = W.enemies.on_me
            if on > 1 then c:add(min(24, (on - 1) * 8), string.format("%d on you", on)) end
            if W.sit.adds then c:add(5, "an add just joined") end
            if W.player.hp > 0.6 then c:add(-20, "healthy: control is optional") end
        end,
    })

    -- ==========================================================================
    -- 80 / 78  DEFENSIVES
    -- ==========================================================================
    --
    -- Four reasons, three of them predictive: health under the line; the race
    -- being lost (the field measures it seconds before the bar shows it); a
    -- dangerous cast about to land on us; a spike, or health on course for the
    -- line within two seconds. The class lists its defensives best first.

    local function affordable(name, W)
        local pl = W.player
        if not P.auto or not P.auto.cost_fraction or pl.power_max <= 0 then return true end
        local cost = P.auto.cost_fraction(name)
        if not cost then return true end
        -- Spending the last of the bar on a defensive is how a caster ends a
        -- fight alive for four more seconds and then out of options.
        return (pl.power_pct - cost) >= W.thresholds.critical_power
    end

    R.add_rule({
        name = "Defensive cooldown",
        category = "defensive", priority = 80, lane = "fast",
        needs = { "combat" },
        retry = { hold = 6 },
        propose = function(W, offer)
            local sit, pl = W.sit, W.player
            local trigger
            if sit.hp_low then
                trigger = "low health"
            elseif sit.losing then
                trigger = "losing the race"
            elseif sit.incoming then
                trigger = "a big cast is about to land"
            elseif sit.spike then
                trigger = "a health spike"
            elseif W.enemies.melee_on_me >= 3 and pl.hp < 0.7 then
                trigger = "surrounded"
            elseif pl.hp_rate < -0.03 and pl.projected <= W.thresholds.defensive_hp then
                trigger = "on course for the line"
            else
                -- A player fight the threat read calls HIGH or CRITICAL
                -- (Stage 14): before the health says so.
                local level = intel_threat(W)
                if level == "HIGH" or level == "CRITICAL" then trigger = "PvP threat " .. level end
            end
            if not trigger then return end

            -- The PvP hunter (1.7.6) times Feign Death into a player's cast
            -- itself, in its last moment (rules/hunter_pvp.lua): pressed here,
            -- seconds early, the caster simply casts again.
            local ph = P.pvphunter
            local fd_timed = trigger == "a big cast is about to land" and ph ~= nil and ph.mode ~= nil
                and ph.mode() == true
            local list = (W.class and W.class.defensives) or {}
            for i = 1, #list do
                local name = list[i]
                if not (fd_timed and name == "Feign Death")
                    and book.known(name) and book.ready(name) and key_allows(name) and affordable(name, W) then
                    local target = escape_target(name, W)
                    if target then
                        local c = offer({ name = name, target = target, target_kind = kind_of(target, W),
                                          why = trigger })
                        c.trigger = trigger
                        return
                    end
                end
            end
        end,
        score = function(W, c)
            local pl, line = W.player, W.thresholds.defensive_hp
            if pl.hp < line then
                c:add(min(30, (line - pl.hp) * 100),
                    string.format("health %d%% under %d%%", pct(pl.hp), pct(line)))
            end
            if pl.hp_rate < -0.05 then c:add(10, string.format("falling %.0f%%/s", -pl.hp_rate * 100)) end
            local on = W.enemies.on_me
            if on > 1 then c:add(min(15, (on - 1) * 5), string.format("%d on you", on)) end
            if c.trigger == "a big cast is about to land" then c:add(10, "before the hit lands") end
            if c.trigger == "a health spike" then c:add(8, "spike") end
            if c.trigger == "surrounded" then
                c:add(10, string.format("%d in melee with you", W.enemies.melee_on_me))
            end
            if c.trigger == "losing the race" then c:add(5, W.field.reason ~= "" and W.field.reason or "losing") end
            if c.trigger and c.trigger:find("^PvP threat") then
                local level, why = intel_threat(W)
                c:add(level == "CRITICAL" and 20 or 12, c.trigger .. (why and (": " .. why) or ""))
            end
        end,
        -- Against players (intel/cooldowns.lua, Stage 3): held while a
        -- protection already up covers what is hitting you -- never under
        -- critical health, never outside a PvP picture.
        validate = function(W, c)
            local I = P.react and P.react.intel
            local cds = I and I.cooldowns
            if cds and W.intel and W.intel.active then return cds.hold_defensive(W, c, W.intel) end
            return nil
        end,
    })

    -- Racials that answer a specific problem. The old pass fired whichever
    -- one was up on low health, which is how Escape Artist was used against
    -- a mob hitting you in melee. Now each waits for what it fixes.
    local loc_names = nil
    local function loc_kind(type_id)
        if not loc_names then
            loc_names = {}
            for name, id in pairs(P.loc_types or {}) do
                if type(id) == "number" then loc_names[id] = name:lower() end
            end
        end
        return loc_names[type_id] or ""
    end

    local function has_aura_type(unit, wanted)
        if not unit or not units.aura_index then return false end
        local ok, index = pcall(units.aura_index, unit)
        if not ok or type(index) ~= "table" then return false end
        for _, aura in pairs(index) do
            if type(aura) == "table" and aura.type and wanted[aura.type] then return true end
        end
        return false
    end

    R.add_rule({
        name = "Defensive racial",
        category = "defensive", priority = 78, lane = "fast", target = "self",
        needs = { "combat" },
        every = 0.1,
        retry = { hold = 3 },
        propose = function(W, offer)
            local pl = W.player
            local kind = pl.control and loc_kind(pl.control.type) or ""
            local function try_one(name, why)
                if book.known(name) and book.ready(name) then
                    local c = offer({ name = name, why = why })
                    c.breaks = kind ~= "" and why:find("lost control", 1, true) ~= nil
                    return true
                end
                return false
            end
            if kind ~= "" then
                if (kind:find("fear") or kind:find("charm") or kind:find("sleep"))
                    and try_one("Will of the Forsaken", "lost control: " .. kind) then return end
                if (kind:find("stun") or kind:find("fear") or kind:find("root") or kind:find("confuse"))
                    and try_one("Every Man for Himself", "lost control: " .. kind) then return end
                if kind:find("root") and try_one("Escape Artist", "lost control: " .. kind) then return end
            end
            if book.known("Stoneform") and book.ready("Stoneform") then
                local types = P.enums and P.enums.buff_type
                local wanted = {}
                for _, n in ipairs({ "POISON", "DISEASE", "BLEED" }) do
                    if types and type(types[n]) == "number" then wanted[types[n]] = true end
                end
                if W.sit.hp_low or has_aura_type(pl.unit, wanted) then
                    if try_one("Stoneform", W.sit.hp_low and "low health" or "poison or disease on you") then return end
                end
            end
            if W.sit.hp_low and W.enemies.on_me > 0 then
                try_one("War Stomp", "low health, something in melee")
            end
        end,
        score = function(W, c)
            if c.breaks then c:add(20, "breaks the control") end
            local pl, line = W.player, W.thresholds.defensive_hp
            if pl.hp < line then c:add(min(20, (line - pl.hp) * 80), string.format("health %d%%", pct(pl.hp))) end
        end,
    })

    -- ==========================================================================
    -- 72 / 70  PET PROTECTION
    -- ==========================================================================
    --
    -- THE HEAL IS ONE EVENT PER DIP. The pet going under the line opens an
    -- event; a heal answers it, and the event stays answered for the length of
    -- the channel and a beat after -- the time it takes to see whether the heal
    -- worked. Only if the pet is STILL low after that is it a new question.
    -- That is the whole cure for Mend Pet -> Mend Pet -> Mend Pet.
    --
    -- PREDICTIVE: a pet on course for the line within 2.5 seconds is healed now.
    -- Health Funnel is paid in our health, so it keeps the old checks: the trade
    -- has to be affordable, and the pet must not be dying faster than a funnel
    -- can refill it.
    --
    -- THE LINE ONLY OPENS THE QUESTION (1.66.0, react/petcare.lua). The heal
    -- is a channel: five seconds standing still, no shots, no stepping out.
    -- So before it goes out it is weighed, and the readout says which check
    -- holds it back:
    --   * our safety first -- a bail-out, danger ground, our health at the end
    --     of the channel under the defensive line, too few seconds to live,
    --     a mob in melee (or arriving) at half health, the mana Feign Death
    --     needs. Short of a veto, melee and arrivals cost points;
    --   * will it matter -- a pet that outlives what it is holding finishes
    --     the fight and is topped up after it;
    --   * will it work -- a pet that dies inside the channel anyway is not
    --     channelled into (Intimidation, rules/hunter.lua, buys that time).
    -- A channel that turns dangerous halfway gives way (yield): reactions may
    -- cut it and the cast gate opens so the kite can step out.
    -- Weighed by what the pet is worth: the tank solo, much of a Beast
    -- Mastery hunter's damage, and with Improved Mend Pet a removable debuff
    -- raises the line, while one that takes the pet out of the fight (Fear,
    -- Sleep, Polymorph) is answered at any health -- the talent is the only
    -- way a hunter has to free the pet.

    local function heal_worth(name, W)
        if name ~= "Health Funnel" then return true, nil end
        local res = P.resources
        if not res or not res.may_trade_health then return false, "no resource tracking" end
        local ok, why = res.may_trade_health(P.derived("pet_funnel_cost_hp", 20), {
            floor = P.derived("pet_funnel_min_hp", 55), need_power = 1.0,
        })
        if not ok then return false, why end
        if W.pet.hp_rate < -P.derived("pet_funnel_futile_rate", 8) then
            return false, string.format("the pet is losing %.0f%%/s; a funnel will not save it", -W.pet.hp_rate * 100)
        end
        return true, nil
    end

    -- The current dip: from the first moment the pet needed a heal (or was
    -- about to) until it is back over the exit line. One event, however many
    -- times it wobbles across the line in between.
    -- The line it ends at is fixed when it starts: the tuned heal line moves
    -- with how fast the pet is losing health, and an end line that moved with
    -- it closed the dip at 35% a second after it opened at 49%, which opened
    -- a new one -- and a second Mend Pet four seconds after the first.
    local episode_at, episode_guid, episode_exit, episode_seen = nil, nil, 1, 0

    local petcare = lib.petcare
    local PET_HEALS = { "Mend Pet", "Health Funnel" }

    --- Everything the heal has to clear before it is pressed, in the order a
    --- player would ask: can we pay for it, can we stand still, will it
    --- matter, will it work. The first that fails is why it waits.
    --- Held back, and said in the reaction log (every 3s at most): the
    --- readout is not always open when a player wonders why the pet died.
    local function hold(c, name, why)
        c:wait(why)
        if lib.journal then lib.journal("select", string.format("%s waits: %s", name, why), "wait:pet_heal") end
    end

    local function judge(W, c, name)
        local ok, why = heal_worth(name, W)
        if not ok then c:wait(why) return end
        if not petcare then return end
        local F = petcare.forecast(W, name)
        c.F = F
        local veto, costs = petcare.danger(W, name, F.channel, false)
        c.costs = costs
        if veto then hold(c, name, veto) return end
        -- Freeing the pet is the point, whatever its health says.
        if c.clean and c.clean.control then return end
        if F.outlives and not W.sit.pet_critical then
            hold(c, name, string.format("the pet lasts ~%.0fs and its fight ends in ~%.0fs: shooting on",
                F.pet_ttl, F.fight_left))
            return
        end
        if F.futile then
            hold(c, name, string.format("the pet is losing %.0f%%/s and %s heals ~%.0f%%/s: it dies inside the channel",
                F.loss * 100, name, F.heal_rate * 100))
        end
    end

    R.add_rule({
        name = "Heal the pet",
        category = "pet", priority = 70, target = "pet",
        needs = { "pet", "combat" },
        owns = { "Mend Pet", "Health Funnel" },
        retry = { hold = 2.0 },
        -- The channel, once running, asked again with the time it has left:
        -- if standing still now would get us killed, it gives way.
        yield = function(W, name) return petcare and petcare.yield(W, name) or nil end,
        propose = function(W, offer)
            local pet, line = W.pet, W.thresholds.pet_heal_hp
            if pet.guid ~= episode_guid or (episode_at and (pet.hp >= episode_exit
                or (W.now - episode_seen) > 20)) then
                episode_at, episode_guid = nil, pet.guid
            end
            local name = nil
            for i = 1, #PET_HEALS do
                if book.known(PET_HEALS[i]) then name = PET_HEALS[i] break end
            end
            if not name then return end

            -- Improved Mend Pet: what the channel would clear as well.
            local clean = petcare and petcare.cleanse(W, name) or nil
            if clean and clean.control then
                -- Feared, asleep, polymorphed: the pet holds nothing, and the
                -- talent is the only way to free it. At any health.
                local c = offer({
                    name = name, target = pet.unit, target_kind = "pet", channel = true,
                    event_key = string.format("pet_free:%s:%s", tostring(pet.guid), tostring(clean.id)),
                    handled_for = petcare.channel_of(name) + 1.5,
                    why = string.format("free the pet: %s", clean.name),
                })
                c.clean = clean
                judge(W, c, name)
                return
            end
            -- A poison or a curse it can clear: healed a little sooner.
            if clean then line = min(0.6, line + 0.15 * clean.chance) end

            local now_low = W.sit.pet_low or pet.hp < line
            local soon = not now_low and pet.hp_rate < -0.02 and pet.projected <= line
                and pet.hp < min(0.6, line + 0.3)
            if not now_low and not soon then return end
            -- A pet that is not holding anything is not about to be hit again.
            if not pet.target and pet.attackers == 0 then return end

            if not episode_at then
                episode_at = W.now
                episode_exit = min(0.95, math.max(line, 0.20) + 0.25)
            end
            episode_seen = W.now
            local key = string.format("pet_low:%s:%.1f", tostring(pet.guid), episode_at)
            local c = offer({
                name = name, target = pet.unit, target_kind = "pet", channel = true,
                event_key = key,
                handled_for = function() return 6.5 end,
                why = string.format("pet at %d%%", pct(pet.hp)),
            })
            c.soon, c.clean = soon, clean
            judge(W, c, name)
        end,
        score = function(W, c)
            local pet, line = W.pet, W.thresholds.pet_heal_hp
            if pet.hp < line then
                c:add(min(25, (line - pet.hp) * 100), string.format("pet %d%% under %d%%", pct(pet.hp), pct(line)))
            end
            if c.soon then
                c:add(5, string.format("pet falling %.0f%%/s: under the line within 2.5s", -pet.hp_rate * 100))
            end
            if W.sit.pet_critical then c:add(10, "pet critical") end
            local F = c.F
            if F and F.pet_ttl < F.channel + 1.5 then
                c:add(6, string.format("the pet has ~%.1fs to live", F.pet_ttl))
            end
            if pet.attackers > 1 then
                c:add(min(10, (pet.attackers - 1) * 5), string.format("%d on the pet", pet.attackers))
            end
            if W.env.solo and pet.attackers > 0 then c:add(8, "the pet is your tank") end
            local cl = c.clean
            if cl and cl.control then
                c:add(floor(18 * cl.chance + 0.5), string.format("Improved Mend Pet %d/2: %d%% to free it from %s",
                    cl.rank, pct(cl.chance), cl.name))
                if W.sit.pet_lost_aggro then c:add(6, "its mob turned on you") end
            elseif cl then
                c:add(floor(5 * cl.chance + 0.5), string.format("Improved Mend Pet %d/2: %d%% to clear %s",
                    cl.rank, pct(cl.chance), cl.name))
            end
            if petcare then petcare.worth(W, function(points, why) c:add(points, why) end) end
            local costs = c.costs
            if costs then
                for i = 1, #costs do c:add(costs[i][1], costs[i][2]) end
            end
        end,
    })

    -- ==========================================================================
    -- 74  THE PET'S TAUNT (1.68.0)
    -- ==========================================================================
    --
    -- "Pet: take the mob back", a manual Growl when the mob turned on us, was
    -- removed in 1.35.2. The autocast had always just spent it on the pet's
    -- own target ("Spell is not ready yet", every few seconds). Now the engine
    -- owns the taunt. While this reaction runs, Growl (Torment for a
    -- Voidwalker) is off autocast (pet.lua) and pressed here, at the mob
    -- react/petthreat.lua says needs it most: one hitting you, then one about
    -- to turn to you, else the pet's own mob whenever it is ready, as the
    -- autocast did. Only a mob inside the pet's reach; a mob on you further
    -- away is "Pet: pick up the add"'s. Suffering goes out for two or more
    -- around the Voidwalker. It is in the threat category, so it keeps its
    -- weight in an emergency and an escape, where a pet ability usually
    -- loses it. Intimidation, on the hunter's own list, is the strong answer
    -- when the taunt is not enough.

    local petthreat = lib.petthreat

    R.add_rule({
        name = "Pet: taunt",
        category = "threat", priority = 74, kind = "pet_spell",
        needs = { "pet" },
        every = 0.1,
        retry = { hold = 1.0 },
        propose = function(W, offer)
            local S = W.petthreat
            if not S or not S.live then return end
            -- Aimed this pass: autocast stays off while it is.
            local pets = P.pet
            local aimed = S.name ~= nil and pets ~= nil and pets.aim_taunt ~= nil and pets.aim_taunt() ~= nil
            if S.area and S.area_ready and S.area_n >= 2 then
                local c = offer({
                    name = S.area, kind = "pet_spell", target = W.pet.unit, target_kind = "pet",
                    event_key = "taunt_area:" .. tostring(W.pet.guid), handled_for = 2,
                    why = string.format("%d around the pet", S.area_n),
                })
                c.area_n = S.area_n
            end
            local e = S.pick
            -- Why it waits, for the log (1.73.1).
            if S.name and petthreat and petthreat.note then
                if not e then
                    local near = S.list and S.list[1] or nil
                    local why
                    if not near then
                        why = "no mob needs it (none on you, about to turn, or the pet's own)"
                    elseif near.d_pet then
                        why = string.format("%s (%s) is %.0f yd from the pet: out of its 5 yd reach",
                            (units.name and units.name(near.obj)) or "the nearest", near.kind, near.d_pet)
                    else
                        why = string.format("where %s stands from the pet is not known",
                            (units.name and units.name(near.obj)) or "its mob")
                    end
                    petthreat.note(S.name, why)
                elseif S.short then
                    petthreat.note(S.name, S.short)
                elseif S.ready_in > 0 then
                    petthreat.note(S.name, string.format("on its cooldown (%.1fs)", S.ready_in))
                else
                    petthreat.note(S.name, "offered")
                end
            end
            if not (S.name and e) then return end
            if not aimed then
                -- AUTOCAST STAYS ON (pet.lua could not keep it off, 1.68.1). It
                -- Growls the pet's own target, so the pet is moved onto the mob
                -- that needs it; its own mob it keeps Growling by itself.
                if e.held or e.kind == "the pet's own" then return end
                local m = offer({
                    name = "Pet: attack", kind = "pet_send", target = e.obj, target_kind = "enemy",
                    event_key = "taunt_move:" .. tostring(e.guid), handled_for = 4,
                    why = string.format("%s: %s -- autocast Growls it there", (units.name and units.name(e.obj)) or "a mob",
                        e.kind),
                })
                m.e, m.pin = e, 4
                return
            end
            local c = offer({
                name = S.name, kind = "pet_spell", target = e.obj, target_kind = "enemy",
                why = string.format("%s: %s", (units.name and units.name(e.obj)) or "a mob", e.kind),
            })
            c.e = e
            if S.short then
                c:wait(S.short)
            elseif S.ready_in > 0 then
                c:wait(string.format("%s in %.1fs", S.name, S.ready_in))
            end
        end,
        score = function(W, c)
            if c.area_n then
                c:add(min(20, c.area_n * 6), string.format("%d on you or about to be, around the pet", c.area_n))
                return
            end
            local reasons = c.e.reasons
            for i = 1, #reasons do c:add(reasons[i][1], reasons[i][2]) end
        end,
        on_execute = function(W, c)
            if petthreat and c.e and c.kind == "pet_spell" then petthreat.sent(c.e.guid, c.name, W.now) end
        end,
    })

    -- ==========================================================================
    -- 65  THREAT
    -- ==========================================================================
    --
    -- In a group with a living tank, and only for someone who is not the tank.
    -- PREDICTIVE: threat is sampled for its rate, and a figure that will reach
    -- 100 within a second and a half is acted on before it does. With a threat
    -- drop ready it is pressed; without one, the rotation EASES OFF for a
    -- couple of seconds (a hold) rather than pull the mob.
    --
    -- AND SOLO, THE PET IS THE TANK (1.36.0). A mob the pet was holding that
    -- turns on us gets the drop the class has -- Disengage in melee, Feign
    -- Death -- and the pet's own Growl does the rest. No ease-off here: the
    -- damage specials already wait while our threat is high (react/adapt.lua),
    -- and Cower is never pressed for it -- on a hunter that is the PET'S
    -- Cower, which would hand the mob to us for good.

    local THREAT_DROPS = { "Feign Death", "Fade", "Cower", "Soulshatter" }
    local ease_started = -math.huge
    -- Short and rare: a pause is a standing character, so it is only for
    -- threat that is still climbing, and never more than a second and a half.
    local EASE_FOR, EASE_EVERY = 1.5, 8.0

    R.add_rule({
        name = "Shed threat",
        category = "threat", priority = 65,
        needs = { "combat" },
        every = 0.1,
        retry = { hold = 3 },
        propose = function(W, offer)
            local pl, sit = W.player, W.sit
            local pet_tank = not W.group.in_group and W.pet.alive and sit.pet_lost_aggro == true
            if not pet_tank and (not W.group.in_group or pl.is_tank or not W.group.tank_alive) then return end
            local T = pl.threat
            local predicted = T.max_pct and (T.max_pct + T.rate * 1.5) or nil
            local trigger
            if pet_tank then
                trigger = "off the pet"
            elseif sit.aggro_pulled then
                trigger = "pulled"
            elseif sit.threat_critical then
                trigger = "critical"
            elseif predicted and predicted >= 100 and sit.threat_warning then
                trigger = "rising"
            end
            if not trigger then return end

            local drops = {}
            local catalog = P.catalog
            if catalog and catalog.with_role then
                local rows = catalog.with_role("threat_drop", true)
                for i = 1, #rows do drops[#drops + 1] = rows[i].name end
            end
            for i = 1, #THREAT_DROPS do drops[#drops + 1] = THREAT_DROPS[i] end

            for i = 1, #drops do
                local name = drops[i]
                if not (pet_tank and name == "Cower")
                    and book.known(name) and book.ready(name) and key_allows(name) then
                    local target = escape_target(name, W)
                    if target then
                        local c = offer({ name = name, target = target, target_kind = kind_of(target, W),
                                          why = trigger })
                        c.trigger = trigger
                        return
                    end
                end
            end

            -- Nothing to drop it with. Ease off, briefly, and not again soon.
            if not pet_tank and trigger ~= "rising" and (T.rate > 0 or (T.max_pct or 0) >= 98) then
                local now = W.now
                if (now - ease_started) > EASE_EVERY then ease_started = now end
                if (now - ease_started) <= EASE_FOR then
                    local c = offer({ name = "Ease off", kind = "hold",
                                      why = string.format("%s%% threat", tostring(floor(T.max_pct or 100))) })
                    c.trigger = trigger
                end
            end
        end,
        score = function(W, c)
            local T = W.player.threat
            if c.trigger == "off the pet" then
                c:add(20, "it left the pet for you")
            elseif c.trigger == "pulled" then
                c:add(20, "pulled it off the tank")
            elseif c.trigger == "critical" then
                c:add(10, string.format("threat %d%%", floor(T.max_pct or 0)))
            elseif c.trigger == "rising" then
                c:add(15, string.format("threat %d%% rising %+.0f/s: pulls in ~1.5s", floor(T.max_pct or 0), T.rate))
            end
            if W.env.boss then c:add(10, "boss") elseif W.env.elite then c:add(5, "elite") end
        end,
    })

    -- ==========================================================================
    -- 60  DISPEL
    -- ==========================================================================
    --
    -- By aura TYPE, as the class declares (Magic, Curse, Disease, Poison). Self
    -- first, then the most hurt ally, then the healer and the tank. Each aura
    -- on each unit is one event.

    local function dispellable(unit, removable)
        if not unit or not units.aura_index then return nil end
        local ok, index = pcall(units.aura_index, unit)
        if not ok or type(index) ~= "table" then return nil end
        for _, aura in pairs(index) do
            if type(aura) == "table" and aura.type and removable[aura.type] then return aura end
        end
        return nil
    end

    R.add_rule({
        name = "Dispel",
        category = "utility", priority = 60,
        every = 0.25,
        retry = { hold = 1.5 },
        propose = function(W, offer)
            local list = W.class and W.class.dispels
            if type(list) ~= "table" or #list == 0 then return end
            local types = P.enums and P.enums.buff_type
            if not types then return end

            local who = { W.player.unit }
            local s = W.s or {}
            if s.ally and s.ally ~= W.player.unit then who[#who + 1] = s.ally end
            if W.group.healer then who[#who + 1] = W.group.healer end
            if W.group.tank then who[#who + 1] = W.group.tank end

            for e = 1, #list do
                local entry = list[e]
                if book.known(entry.spell) then
                    local removable = {}
                    for _, n in ipairs(entry.types or {}) do
                        if type(types[n]) == "number" then removable[types[n]] = true end
                    end
                    local seen = {}
                    for i = 1, #who do
                        local unit = who[i]
                        if unit and not seen[unit] then
                            seen[unit] = true
                            local aura = dispellable(unit, removable)
                            if aura then
                                local guid = units.guid(unit)
                                local c = offer({
                                    name = entry.spell, target = unit,
                                    target_kind = unit == W.player.unit and "self" or "ally",
                                    event_key = string.format("dispel:%s:%s", tostring(guid), tostring(aura.buff_id)),
                                    handled_for = 2.0, why = aura.buff_name,
                                })
                                c.aura, c.on = aura, unit
                            end
                        end
                    end
                    return
                end
            end
        end,
        score = function(W, c)
            if c.on == W.player.unit then
                c:add(10, "on you")
                if W.player.hp < 0.5 then c:add(10, string.format("and you are at %d%%", pct(W.player.hp))) end
            elseif c.on == W.group.healer then
                c:add(10, "on the healer")
            elseif c.on == W.group.tank then
                c:add(8, "on the tank")
            end
        end,
    })

    -- ==========================================================================
    -- 20  LOW PRIORITY: top the pet up between pulls
    -- ==========================================================================
    --
    -- Below the rotation's score, so it only goes out on a tick the rotation
    -- had nothing to press -- which out of combat is most of them. Never while
    -- eating or drinking: a cast stands you up.

    local function refreshing(W)
        if not units.aura_index then return false end
        local ok, index = pcall(units.aura_index, W.player.unit)
        if not ok or type(index) ~= "table" then return false end
        for _, aura in pairs(index) do
            local n = type(aura) == "table" and aura.buff_name or nil
            if type(n) == "string" and (n:find("Food", 1, true) or n:find("Drink", 1, true)
                or n:find("Refreshment", 1, true)) then
                return true
            end
        end
        return false
    end

    R.add_rule({
        name = "Top up the pet",
        category = "low", priority = 20, target = "pet",
        needs = { "pet" },
        every = 0.5,
        retry = { hold = 6 },
        propose = function(W, offer)
            local pet = W.pet
            if W.player.in_combat or W.player.moving or pet.hp >= 0.7 then return end
            if W.enemies.on_me > 0 or W.enemies.on_pet > 0 then return end
            if not book.known("Mend Pet") or refreshing(W) then return end
            offer({ name = "Mend Pet", target = pet.unit, target_kind = "pet", channel = true,
                    event_key = "pet_topup", handled_for = 7, why = string.format("pet at %d%%", pct(pet.hp)) })
        end,
        score = function(W, c)
            c:add(floor((0.7 - W.pet.hp) * 20), string.format("pet at %d%%", pct(W.pet.hp)))
        end,
    })

    -- ==========================================================================
    -- 87 / 68  MORE THAN ONE ENEMY
    -- ==========================================================================
    --
    -- SURROUNDED. Three or more in melee with us -- two, once it is an
    -- emergency -- is a problem no single-target button solves. An area
    -- control (a nova, a scream, a stomp) takes all of them out of the fight
    -- at once. Like every crowd control it waits to be asked in a group, and
    -- it never goes off while something nearby is already controlled: a nova
    -- breaks a sheep as surely as a fear does.
    --
    -- THE PET PICKS UP THE ADD. Solo, the pet is the tank; an add hitting us
    -- while the pet finishes off a nearly-dead mob (or stands idle) is a mob
    -- the pet should be holding. It is sent, and pinned there for a few
    -- seconds so the assist pass does not pull it straight back. Never off a
    -- healthy mob it is holding: that mob would turn on us instead.

    local AREA_CONTROL = {
        WARRIOR = { "Intimidating Shout" }, MAGE = { "Frost Nova" },
        PRIEST = { "Psychic Scream" }, WARLOCK = { "Howl of Terror" },
    }
    -- The ones aimed at an enemy (the shout fears its target and those near it).
    local AREA_ON_TARGET = { ["Intimidating Shout"] = true }

    R.add_rule({
        name = "Surrounded: area control",
        category = "cc", priority = 87,
        needs = { "combat" },
        every = 0.1,
        retry = { hold = 3 },
        propose = function(W, offer)
            local close = W.enemies.melee_on_me or 0
            local need = (W.mode_level or 0) >= 3 and 2 or 3
            if close < need then return end
            if W.enemies.controlled > 0 then return end
            local armed = P.key_armed and P.key_armed("rot_fear_key") or false
            if not W.env.solo and not armed then return end

            local list = {}
            local own = W.class and AREA_CONTROL[W.class.class_name or ""] or nil
            for i = 1, #(own or {}) do list[#list + 1] = own[i] end
            list[#list + 1] = "War Stomp"
            for i = 1, #list do
                local name = list[i]
                if book.known(name) and book.ready(name) and key_allows(name) then
                    local on_target = AREA_ON_TARGET[name] == true
                    local c = offer({
                        name = name,
                        target = on_target and W.target.unit or W.player.unit,
                        target_kind = on_target and "enemy" or "self",
                        event_key = "surrounded", handled_for = 4,
                        why = string.format("%d in melee", close),
                    })
                    c.close = close
                    return
                end
            end
        end,
        score = function(W, c)
            c:add(min(20, (c.close - 2) * 10), string.format("%d in melee with you", c.close))
            if W.player.hp < 0.5 then c:add(10, string.format("at %d%% health", pct(W.player.hp))) end
        end,
    })

    -- ==========================================================================
    -- 70  THE RUNNER (1.38.0)
    -- ==========================================================================
    --
    -- A mob running away low comes back with company. Whatever the class has
    -- that slows, roots or stuns, ranged first, goes on it the moment it runs
    -- -- the rotation keeps the long-cooldown slow for exactly this
    -- (react/adapt.lua, "saving it").

    R.add_rule({
        name = "Stop the runner",
        category = "cc", priority = 70,
        needs = { "combat" },
        every = 0.1,
        retry = { hold = 1.5 },
        propose = function(W, offer)
            local tg = W.target
            local row = tg.row
            if not tg.unit or not row or row.activity ~= "fleeing" or (tg.hp or 1) > 0.35 then return end
            local catalog = P.catalog
            if not (catalog and catalog.with_role) then return end
            local h = H()
            local rank = 0
            for _, role in ipairs({ "slow", "root", "stun" }) do
                local rows = catalog.with_role(role, true)
                for i = 1, #rows do
                    local r = rows[i]
                    local aura = r.applies and r.applies.aura
                    local up = aura and h.debuff_up and h.debuff_up(tg.unit, aura)
                    if up then return end
                    if book.ready(r.name) and key_allows(r.name) and rank < 3 then
                        rank = rank + 1
                        local c = offer({ name = r.name, target = tg.unit, target_kind = "enemy",
                                          event_key = "runner:" .. tostring(tg.guid), handled_for = 4,
                                          why = units.name and units.name(tg.unit) or "the runner" })
                        c.rank = rank
                    end
                end
            end
        end,
        score = function(W, c)
            if (W.enemies.nearby or 0) > (W.enemies.engaged or 0) then c:add(10, "more of them nearby") end
            if c.rank and c.rank > 1 then c:add(-(c.rank - 1), "a later choice") end
        end,
    })

    -- An evading mob is going home and takes nothing; the pet chases it there,
    -- through whatever stands on the way. Called back, and kept off it.
    R.add_rule({
        name = "Pet: off the evading mob",
        category = "pet", priority = 66, kind = "pet_recall",
        needs = { "pet" },
        every = 0.25,
        retry = { hold = 4 },
        propose = function(W, offer)
            local pet = W.pet
            if not pet.target or not pet.target_evading then return end
            offer({ name = "Pet: follow", kind = "pet_recall", target = pet.target, target_kind = "enemy",
                    event_key = "recall:" .. tostring(pet.target_guid), handled_for = 8,
                    why = units.name and units.name(pet.target) or "evading" })
        end,
    })

    R.add_rule({
        name = "Pet: pick up the add",
        category = "pet", priority = 68, kind = "pet_send",
        needs = { "pet", "combat" },
        every = 0.25,
        retry = { hold = 4 },
        propose = function(W, offer)
            local pet = W.pet
            if not W.env.solo or pet.hp < 0.4 then return end
            local pets = P.pet
            if pets and (pet.mode == pets.OFF or pet.mode == pets.FOCUS) then return end

            local held, add = nil, nil
            local list, n = W.enemies.list or {}, W.enemies.count or 0
            for i = 1, n do
                local row = list[i]
                if row then
                    if pet.target_guid and row.guid == pet.target_guid then held = row end
                    if not add and row.obj and row.engaged and row.targeting_me and not row.control
                        and row.guid ~= W.target.guid and row.guid ~= pet.target_guid then
                        add = row
                    end
                end
            end
            -- THE PLAN SAYS WHICH, AND WHETHER (1.56.0): the add hitting us
            -- that we are not killing, and whether what the pet holds will stay
            -- on it -- our threat on that one decides, not its health, because
            -- the pet's threat on it does not leave with the pet (tactics.lua).
            local plan = W.plan
            local plan_why = nil
            if plan and plan.live and plan.pet_add then
                if not plan.pet_ok then return end
                add, plan_why = plan.pet_add, plan.pet_why
            else
                if not add then return end
                -- Free: holding nothing, or what it holds is nearly dead or cannot fight.
                local free = pet.target_guid == nil
                    or (held ~= nil and ((held.hp or 1) < 0.25 or held.control ~= nil))
                if not free then return end
            end
            local c = offer({
                name = "Pet: attack", kind = "pet_send", target = add.obj, target_kind = "enemy",
                event_key = "pickup:" .. tostring(add.guid), handled_for = 6,
                why = units.name and units.name(add.obj) or "the add",
            })
            c.plan_why = plan_why
        end,
        score = function(W, c)
            if c.plan_why then c:add(4, "the plan: " .. c.plan_why) end
            if W.player.hp < 0.6 then c:add(8, string.format("you are at %d%%", pct(W.player.hp))) end
            if W.pet.target_guid == nil then c:add(5, "the pet is idle") end
        end,
    })

    -- ==========================================================================
    -- 75 / 72  MANA
    -- ==========================================================================
    --
    -- Mana is a race of its own: does what is left last as long as the fight
    -- will? The resource model measures both sides -- how fast the bar is going
    -- and how long the mobs have left -- so mana is restored when the bar will
    -- run dry before the fight does, not at a line somebody set. A gem first
    -- (its own cooldown); a potion only when a healing potion is not about to
    -- be wanted, because the two share one. Nothing for a fight that is nearly
    -- over: drinking afterwards is free, a potion is not.

    local function mana_short(W)
        local pl = W.player
        if pl.power_kind ~= "MANA" or pl.power_max <= 0 then return false end
        if W.sit.mana_low then return true end
        return pl.power_pct < 0.35 and pl.power_empty < pl.fight_left
    end

    R.add_rule({
        name = "Restore mana",
        category = "resource", priority = 75, lane = "fast", kind = "item",
        needs = { "combat" },
        retry = { hold = 2 },
        propose = function(W, offer)
            local pl = W.player
            if not mana_short(W) or pl.fight_left < 6 then return end
            local ctl = W.pvp and W.pvp.control
            if ctl and ctl.helpless then return end
            if pl.mana_gem then
                local _, gem = P.hardcore.item("mana_gem")
                offer({ name = gem or "Mana gem", kind = "item", item = "mana_gem",
                        event_key = "mana_item", handled_for = 2 })
                return
            end
            if pl.mana_potion then
                if pl.potion and pl.hp < W.thresholds.potion_hp + 0.15 then return end
                local _, potion = P.hardcore.item("mana_potion")
                offer({ name = potion or "Mana potion", kind = "item", item = "mana_potion",
                        event_key = "mana_item", handled_for = 2 })
            end
        end,
        score = function(W, c)
            local pl = W.player
            c:add(min(25, (0.35 - pl.power_pct) * 100), string.format("mana %d%%", pct(pl.power_pct)))
            if pl.power_empty < pl.fight_left then
                c:add(10, string.format("empty in %.0fs, the fight has %.0fs", pl.power_empty, pl.fight_left))
            end
        end,
    })

    -- The class's own way of getting mana back. Life Tap and Dark Pact stay
    -- with the warlock's rules, which already pay for them in health through
    -- the resource model's trade gate.
    local MANA_SPELLS = {
        MAGE = { "Evocation" }, DRUID = { "Innervate" }, SHAMAN = { "Mana Tide Totem" },
    }

    R.add_rule({
        name = "Mana cooldown",
        category = "resource", priority = 72, target = "self",
        every = 0.25,
        retry = { hold = 10 },
        propose = function(W, offer)
            local pl = W.player
            local list = W.class and MANA_SPELLS[W.class.class_name or ""] or nil
            if not list or pl.power_kind ~= "MANA" or pl.power_max <= 0 then return end
            local want
            if pl.in_combat then
                want = mana_short(W) and pl.fight_left >= 6
            else
                -- Between pulls, a cooldown that is back by the next one beats
                -- sitting down to drink -- but not once already drinking.
                want = pl.power_pct < 0.2 and not pl.moving and W.enemies.on_me == 0 and not refreshing(W)
            end
            if not want then return end
            for i = 1, #list do
                local name = list[i]
                if book.known(name) and book.ready(name) then
                    -- A channel needs nobody hitting us, or it is pushed back to nothing.
                    if name == "Evocation" and W.enemies.on_me > 0 then return end
                    offer({ name = name, channel = name == "Evocation",
                            why = string.format("mana %d%%", pct(pl.power_pct)) })
                    return
                end
            end
        end,
        score = function(W, c)
            c:add(min(20, (0.30 - W.player.power_pct) * 100), string.format("mana %d%%", pct(W.player.power_pct)))
        end,
    })
end

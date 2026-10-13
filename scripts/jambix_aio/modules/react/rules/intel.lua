-- Jambix AIO / react / rules / intel -- what the PvP intelligence layer
-- acts on (Stage 4). One engine: these are reactions like every other,
-- scored, validated and sent by ctx.react; the layer's tables (W.intel)
-- are what they read, and nothing in the layer casts on its own.
--
--   60  Intel: the aspect for the moment   Aspect of the Monkey with a melee
--                                 player on you, Hawk back once nobody is;
--                                 through the Aspects window's own gate, so
--                                 with *Auto swap aspects* off nothing moves
--   52  Intel: the bait              (Stage 8) the cheap shot a bait asks for
--                                 (Concussive Shot): a mobility bait, to draw
--                                 the charge into the counter; a trinket
--                                 bait, to draw the trinket before the real
--                                 control. Below the survival and escape
--                                 bands; the defensive and interrupt baits
--                                 press nothing (advice, and a hold the
--                                 burst's gate may read)
--   72  Intel: keep the control on your target   (Stage 6) a hold: no
--                                 damage on a player held by a control that
--                                 damage breaks, while the plan says keeping
--                                 it is worth something (or the trap could
--                                 follow); a hold halts the rotation's
--                                 presses, nothing more -- the pet's recall
--                                 is pet.lua's, the Auto Shot already
--                                 running is the hunter class's to stop
--
--   78  Intel: peel for an ally     (Stage 14) the team read's peel: the
--                                 first tool of yours that reaches the
--                                 enemy on your healer or a hurt ally
--   69  Intel: switch target         (Stage 14) off a player an ally holds,
--                                 or onto a clearly better kill window
--   58  Intel: drain the healer      (Stage 14) Viper Sting on a free enemy
--                                 healer
--   The hold above also keeps an ally's breakable control (Stage 14).
--
-- Elsewhere, reading the same tables (Stage 14): the three cast-stopping
-- reactions take the team read's pick (lib.team_pick); "Defensive
-- cooldown" fires on a HIGH or CRITICAL PvP threat; "Break contact" on the
-- DISENGAGE state; the rotation refuses a cast-time spell a sure
-- interrupter in reach would kick (intel.press_veto). Only the move is
-- left to you: nothing here walks the character.

return function(R, P, lib)
    local book = P.spellbook

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    local function picture(W)
        local S = W.intel
        if not (S and S.active and not S.off) then return nil end
        return S
    end

    R.add_rule({
        name = "Intel: the aspect for the moment",
        category = "utility", priority = 60, kind = "aspect", target = "self",
        every = 0.3,
        retry = { hold = 2.0 },
        enabled = function() return opt("intel_tactics", true) end,
        propose = function(W, offer)
            local S = picture(W)
            local pos = S and S.pos or nil
            if not (pos and pos.aspect) then return end
            if not book.known(pos.aspect) then return end
            local A = P.aspects
            if not (A and A.auto_swap_on and A.auto_swap_on()) then return end
            local c = offer({ name = pos.aspect, target = W.player.unit, target_kind = "self",
                              event_key = "intel_aspect:" .. pos.aspect, handled_for = 3, why = pos.aspect_why })
            c.pos_why = pos.aspect_why
        end,
        score = function(W, c)
            local S = picture(W)
            if not S then return end
            if S.melee_attackers > 0 and c.name == "Aspect of the Monkey" then
                c:add(10, string.format("%d in melee with you", S.melee_attackers))
            end
            if c.pos_why then c:add(5, c.pos_why) end
        end,
    })

    -- Stage 8: the cheap shot a bait asks for. The bait module has already
    -- read the prediction through intel.sure, checked the counter is ready
    -- and the threat under the line; here it is a reaction like any other,
    -- validated by the engine (range, cooldown), scored under everything
    -- that keeps us alive, and not repeated on the same player for a while.
    R.add_rule({
        name = "Intel: the bait",
        category = "utility", priority = 52,
        every = 0.3,
        enabled = function() return opt("intel_bait", true) end,
        propose = function(W, offer)
            local S = picture(W)
            local B = S and S.bait or nil
            local b = B and B.target or nil
            if not (b and b.press and W.target.guid and b.guid == W.target.guid) then return end
            if not (book.known(b.press) and book.ready(b.press)) then return end
            local I = R.intel
            local KB = I and I.weights and I.weights.BAIT or nil
            local c = offer({ name = b.press, target = W.target.unit, target_kind = "enemy",
                              event_key = "intel_bait:" .. b.kind .. ":" .. tostring(b.guid),
                              handled_for = KB and KB.repeat_after[b.kind] or 10, why = b.v })
            c.bait_kind, c.bait_conf, c.bait_why = b.kind, b.conf, b.why
        end,
        score = function(W, c)
            local I = R.intel
            local KB = I and I.weights and I.weights.BAIT or nil
            local pts = KB and (KB.points[c.bait_kind] or 0) * (c.bait_conf or 0) or 0
            if pts > 0 then c:add(pts, string.format("%s bait (%.2f): %s", tostring(c.bait_kind), c.bait_conf or 0, c.bait_why or "")) end
        end,
    })

    -- Stage 6: the one hold the control plan asks for. A hold is collected
    -- by the engine whatever its score (it halts the rotation's presses
    -- this tick), so this only proposes when the plan is sure enough: a
    -- breakable control on the current target with at least a global
    -- cooldown left, and a reason to keep it.
    R.add_rule({
        name = "Intel: keep the control on your target",
        category = "cc", priority = 72, kind = "hold",
        every = 0.2,
        enabled = function() return opt("intel_cc", true) end,
        propose = function(W, offer)
            local S = picture(W)
            local C = S and S.cc or nil
            local h = C and C.hold or nil
            if h and W.target.guid and h.guid == W.target.guid then
                local c = offer({ name = "No damage on " .. tostring(h.name), kind = "hold", why = h.why })
                c.hold_value, c.hold_conf = h.value, h.conf
                return
            end
            -- An ally's control that damage breaks on your target (Stage 14,
            -- team.lua's overlap): yours would break it just the same. The
            -- switch below moves you off it; until then, nothing on it.
            local o = S and S.team and S.team.overlap or nil
            if o and W.target.guid and o.guid == W.target.guid and opt("intel_team", true) then
                local c = offer({ name = "No damage on " .. tostring(o.name), kind = "hold", why = o.why })
                c.ally_control = o.control
            end
        end,
        score = function(W, c)
            if c.ally_control then c:add(15, "an ally's " .. tostring(c.ally_control)) return end
            local I = R.intel
            local KC = I and I.weights and I.weights.CC or nil
            local pts = KC and (KC.value_points[c.hold_value] or 0) * (c.hold_conf or 1) or 0
            if pts > 0 then c:add(pts, string.format("%s (%.2f)", tostring(c.hold_value), c.hold_conf or 1)) end
        end,
    })

    -- --- Stage 14: what the team read says, pressed ------------------------------------

    --- The threat on you HIGH or worse: the team's moves wait (the
    --- defensives and the escapes come first).
    local function in_danger(S)
        local T = S.threat
        return T ~= nil and (T.level == "HIGH" or T.level == "CRITICAL")
    end

    -- The peel: an enemy on your healer or on an ally under half health, not
    -- held, and the first tool of yours ready that reaches it (team.lua has
    -- already checked the range, the dead zone and the pet for Intimidation).
    R.add_rule({
        name = "Intel: peel for an ally",
        category = "cc", priority = 78,
        needs = { "combat" },
        every = 0.2,
        retry = { hold = 2.0 },
        enabled = function() return opt("intel_team", true) end,
        propose = function(W, offer)
            local S = picture(W)
            local p = S and S.team and S.team.peel or nil
            if not (p and p.action) or in_danger(S) then return end
            local f = S.foes[p.guid]
            if not (f and f.unit and not f.dead) then return end
            if not (book.known(p.action) and book.ready(p.action)) then return end
            -- On yourself: the pet's (Intimidation) and what goes off around you (a Frost Nova, a Psychic Scream).
            local self_cast = p.pet or p.around or p.action == "Intimidation"
            local c = offer({ name = p.action, target = self_cast and W.player.unit or f.unit,
                              target_kind = self_cast and "self" or "enemy",
                              event_key = "intel_peel:" .. tostring(p.guid), handled_for = 4, why = p.why })
            c.peel = p
        end,
        score = function(W, c)
            c:add(c.peel.ally_healer and 18 or 12, "peel: " .. tostring(c.peel.why))
        end,
    })

    -- The switch: off a player an ally holds with a control damage breaks,
    -- or onto a kill window elsewhere that team.lua found clearly better
    -- (in reach, and high confidence or well lower). An immune target is
    -- "PvP: off the immune target"'s. Held 0.6 s before it goes, so the
    -- target does not flicker between two near-equal players.
    local SWITCH_DWELL = 0.6
    local switch_seen = { key = nil, at = -math.huge }
    R.add_rule({
        name = "Intel: switch target",
        category = "utility", priority = 69, kind = "set_target", lane = "fast",
        needs = { "combat", "target" },
        every = 0.25,
        retry = { hold = 2.0 },
        enabled = function() return opt("intel_team", true) end,
        propose = function(W, offer)
            local S = picture(W)
            local sw = S and S.team and S.team.switch or nil
            if not (sw and sw.guid and sw.guid ~= W.target.guid) then switch_seen.key = nil return end
            local tg = W.target.guid and S.foes[W.target.guid] or nil
            if tg and tg.st and tg.st.immune then return end
            local to = S.foes[sw.guid]
            if not (to and to.unit and not to.dead) then return end
            local key = tostring(W.target.guid) .. ">" .. tostring(sw.guid)
            if switch_seen.key ~= key then switch_seen.key, switch_seen.at = key, W.now return end
            if (W.now - switch_seen.at) < SWITCH_DWELL then return end
            offer({ name = "Target " .. tostring(to.name), kind = "set_target", target = to.unit, target_kind = "enemy",
                    event_key = "intel_switch:" .. key, handled_for = 4, why = sw.why })
        end,
        score = function(W, c) c:add(10, c.why or "switch") end,
    })

    -- The enemy healer free to heal: Viper Sting on it for its mana, when it
    -- is not already stung and you are not in danger.
    R.add_rule({
        name = "Intel: drain the healer",
        category = "utility", priority = 58,
        needs = { "combat" },
        every = 0.5,
        retry = { hold = 3.0 },
        enabled = function() return opt("intel_team", true) end,
        propose = function(W, offer)
            local S = picture(W)
            local h = S and S.team and S.team.healer or nil
            if not (h and h.free and h.action and h.action:find("Viper Sting", 1, true)) or in_danger(S) then return end
            local f = S.foes[h.guid]
            if not (f and f.unit and not f.dead) then return end
            if not (book.known("Viper Sting") and book.ready("Viper Sting")) then return end
            local helpers = P.rotation and P.rotation.helpers or {}
            if helpers.debuff_up then
                local ok, up = pcall(helpers.debuff_up, f.unit, "Viper Sting")
                if ok and up == true then return end
            end
            offer({ name = "Viper Sting", target = f.unit, target_kind = "enemy",
                    event_key = "intel_viper:" .. tostring(h.guid), handled_for = 8, why = h.why })
        end,
        score = function(W, c) c:add(8, "the enemy healer: " .. tostring(c.why)) end,
    })
end

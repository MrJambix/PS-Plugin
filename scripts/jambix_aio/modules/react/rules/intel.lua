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
-- The rest of what the layer concludes -- the state, the move, what to
-- keep -- is advice: the readout, the alerts, the window's conditions.
-- The existing reactions already press the clip, the trap, the Feign
-- Death and the defensives; this file does not press them twice.

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
            if not (h and W.target.guid and h.guid == W.target.guid) then return end
            local c = offer({ name = "No damage on " .. tostring(h.name), kind = "hold", why = h.why })
            c.hold_value, c.hold_conf = h.value, h.conf
        end,
        score = function(W, c)
            local I = R.intel
            local KC = I and I.weights and I.weights.CC or nil
            local pts = KC and (KC.value_points[c.hold_value] or 0) * (c.hold_conf or 1) or 0
            if pts > 0 then c:add(pts, string.format("%s (%.2f)", tostring(c.hold_value), c.hold_conf or 1)) end
        end,
    })
end

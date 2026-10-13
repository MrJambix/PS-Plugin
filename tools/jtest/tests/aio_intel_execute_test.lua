-- Jambix AIO: the PvP intelligence pressed (PVP_INTEL_PLAN.md Stage 14) --
-- what the layer reads, sent through the one reaction engine on a scripted
-- clock (tools/jtest/mock/intel_bundle.lua). The user, 2026-10-13: "at the
-- end of the day it's supposed to be automatic that it reads and executes
-- (except movement)".
--
-- What these hold it to, with the PvP hunter (ALPHA) switch OFF: the cast
-- the team read picks (a heal on a low enemy) is stopped with Scatter Shot
-- on its caster; the peel goes out on the enemy on your healer; an ally's
-- Polymorph on your target holds your damage and moves you to another
-- player; a HIGH threat fires a defensive before your health says so; the
-- DISENGAGE state breaks contact with a cast; a free enemy healer gets
-- Viper Sting; a cast-time spell is refused while a sure interrupter is in
-- its reach. Nothing here walks the character.

local B = require("mock/intel_bundle")
local assert_eq, has = B.assert_eq, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR

local function bundle(opts)
    local G = B.bundle(opts)
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false             -- the ALPHA hunter off: the layer alone
    G.known["Arcane Shot"] = true
    G.by_guid["nameplate1"] = G.target
    return G
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function settle(G) step(G) step(G, 1.0) step(G) end
local function foe(G, n, class, fields)
    local u = unit(G, string.format("Player-1-0000070%d", n), { name = fields.name, player = true })
    u.get_class = function() return class end
    local r = G.row_for(u, fields.row or {})
    G.rows[#G.rows + 1] = r
    G.health[u.guid] = r.hp
    return u, r
end
local function group(G, list)
    G.group.in_group = true
    G.dist = G.dist or {}
    local out = {}
    for i, a in ipairs(list) do
        local u = unit(G, string.format("Player-1-0000080%d", i), { name = a.name, player = true, hostile = false })
        G.dist[u.guid], G.health[u.guid] = a.dist or 10, a.hp or 1
        out[i] = u
        if a.healer then G.healer = u end
    end
    G.members = out
    return out
end
--- The casts sent of one spell, with their targets.
local function sent(G, name)
    local out = {}
    for i = 1, #G.casts do
        if G.names[G.casts[i].spell_id] == name then out[#out + 1] = G.casts[i] end
    end
    return out
end

local T = {}

T[#T + 1] = { "the team's pick is stopped: a priest healing the low warrior, Scatter Shot in reach -- sent at the priest, not the target", function()
    local G = bundle()
    G.known["Scatter Shot"] = true
    G.target.get_class = function() return WARRIOR end
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me, G.row.dist, G.distance = true, true, 20, 20
    G.row.hp, G.health[G.target.guid] = 0.2, 0.2
    group(G, { { name = "Mate", dist = 10 } })
    local priest = foe(G, 1, PRIEST, { name = "Priesty", row = { targeting_me = false, dist = 12, target_guid = G.target.guid, engaged = false } })
    G.rows[2].casting = G.casting("Flash Heal", 2.5, 3.0)
    step(G); step(G)
    assert_eq(G.S.team.interrupt and G.S.team.interrupt.name, "Priesty", "the team's pick")
    local s = sent(G, "Scatter Shot")
    assert(#s >= 1, "Scatter Shot sent")
    assert(s[#s].target == priest, "at the priest")
end }

T[#T + 1] = { "the peel: a warrior on our healer at 12 yd -- Scatter Shot at the warrior; not while the threat on you is HIGH", function()
    local G = bundle()
    G.known["Scatter Shot"] = true
    G.target.get_class = function() return WARRIOR end
    G.in_combat, G.fight_age = true, 8
    local allies = group(G, { { name = "Heals", dist = 14, healer = true } })
    G.row.in_combat, G.row.targeting_me, G.row.target_guid, G.row.dist, G.distance = true, false, allies[1].guid, 12, 12
    settle(G)
    assert(G.S.team.peel and G.S.team.peel.action == "Scatter Shot", "the peel read")
    local s = sent(G, "Scatter Shot")
    assert(#s >= 1, "sent")
    assert(s[#s].target == G.target, "at the warrior on the healer")
    -- In danger (two rogues on you at 30%): the peel waits; no Scatter Shot at the warrior.
    local H = bundle()
    H.known["Scatter Shot"] = true
    H.target.get_class = function() return WARRIOR end
    H.in_combat, H.fight_age = true, 8
    local a2 = group(H, { { name = "Heals", dist = 14, healer = true } })
    H.row.in_combat, H.row.targeting_me, H.row.target_guid, H.row.dist, H.distance = true, false, a2[1].guid, 12, 12
    foe(H, 2, ROGUE, { row = { dist = 3 } })
    foe(H, 3, ROGUE, { row = { dist = 3 } })
    H.hp = 0.3
    settle(H)
    local lv = H.S.threat.level
    assert(lv == "HIGH" or lv == "CRITICAL", "in danger: " .. tostring(lv))
    for _, c in ipairs(sent(H, "Scatter Shot")) do assert(c.target ~= H.target, "no peel at the warrior while in danger") end
end }

T[#T + 1] = { "an ally's Polymorph on your target: your damage held, the running attack stopped, and you moved to another player", function()
    local G = bundle()
    local stops = 0
    _G.core.input = _G.core.input or {}
    _G.core.input.stop_attack = function() stops = stops + 1 return true end
    G.player.is_auto_attacking = function() return true end
    G.target.get_class = function() return ROGUE end
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me, G.row.dist, G.distance = true, false, 20, 20
    group(G, { { name = "Mage", dist = 15 } })
    local other = foe(G, 2, WARRIOR, { name = "Smashy", row = { targeting_me = true, dist = 18, hp = 0.15 } })
    G.row.control = { spell_id = 1, kind = "polymorph", breaks = true, name = "Polymorph", from = "debuff", remaining = 8 }
    settle(G)
    assert(G.S.team.overlap, "the ally's control read")
    assert(stops >= 1, "the attack already running stopped")
    local switched = false
    for _, u in ipairs(G.switched) do if u == other then switched = true end end
    assert(switched, "moved to the other player (" .. #G.switched .. " switch(es))")
end }

T[#T + 1] = { "a HIGH threat fires a defensive before your health says so: three rogues on you at 90%", function()
    local G = bundle()
    G.known["Deterrence"] = true
    G.target.get_class = function() return ROGUE end
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me, G.row.dist, G.distance = true, true, 3, 3
    foe(G, 2, ROGUE, { row = { dist = 4 } })
    foe(G, 3, ROGUE, { row = { dist = 4 } })
    G.hp = 0.9
    step(G); step(G)
    local level = G.S.threat.level
    assert(level == "HIGH" or level == "CRITICAL", "the threat: " .. tostring(level))
    assert(#sent(G, "Deterrence") >= 1, "Deterrence pressed at 90%")
end }

T[#T + 1] = { "DISENGAGE breaks contact with a cast: three rogues on you at 20%, no defensive left -- Feign Death (an escape, not a step)", function()
    local G = bundle()
    G.class.escapes, G.class.defensives = { "Feign Death" }, {}
    G.known["Feign Death"] = true
    G.target.get_class = function() return ROGUE end
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me, G.row.dist, G.distance = true, true, 3, 3
    foe(G, 2, ROGUE, { row = { dist = 4 } })
    foe(G, 3, ROGUE, { row = { dist = 4 } })
    G.hp = 0.2
    step(G); step(G)
    assert_eq(G.S.tactic.state, "DISENGAGE", "the state: " .. tostring(G.S.tactic.why))
    assert(#sent(G, "Feign Death") >= 1, "Feign Death pressed")
end }

T[#T + 1] = { "a free enemy healer gets Viper Sting: a priest seen healing at 20 yd, you not in danger; once stung, not again", function()
    local G = bundle()
    G.known["Viper Sting"] = true
    G.target.get_class = function() return WARRIOR end
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me, G.row.dist, G.distance = true, false, 25, 25
    group(G, { { name = "Mate", dist = 10 } })
    local priest = foe(G, 1, PRIEST, { name = "Priesty", row = { targeting_me = false, dist = 20, engaged = false } })
    G.rows[2].casting = G.casting("Flash Heal", 1.4, 1.5)
    step(G)
    G.rows[2].casting = nil
    settle(G)
    assert(G.S.team.healer and G.S.team.healer.free, "the healer free")
    local s = sent(G, "Viper Sting")
    assert(#s >= 1, "Viper Sting sent")
    assert(s[#s].target == priest, "at the healer")
    local n = #s
    G.aura(priest.guid, "Viper Sting", 8)
    step(G, 9); step(G)
    assert_eq(#sent(G, "Viper Sting"), n, "not again while it is stung")
end }

T[#T + 1] = { "the press veto: a cast-time spell refused while a sure interrupter stands in its reach; an instant passes; its Kick seen down, or the rogue out of reach, passes", function()
    local G = bundle()
    G.target.get_class = function() return ROGUE end
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me, G.row.dist, G.distance = true, true, 4, 4
    step(G)
    local f = G.S.foes[G.target.guid]
    f.predict = { interrupts_casts = { v = "it interrupts your casts", p = 0.8, conf = 0.8, reliability = 0.6, sure = true, adapting = false } }
    local why = G.I.press_veto("Aimed Shot", G.target, { cast = 3 })
    has(why, "Enemy interrupts your casts (p 0.80) and its Kick reaches you", "refused")
    assert_eq(G.I.press_veto("Arcane Shot", G.target, { cast = 0 }), nil, "an instant passes")
    f.dist = 10
    assert_eq(G.I.press_veto("Aimed Shot", G.target, { cast = 3 }), nil, "out of Kick's reach")
    f.dist = 4
    f.predict.interrupts_casts.sure = false
    assert_eq(G.I.press_veto("Aimed Shot", G.target, { cast = 3 }), nil, "forming: no veto")
    f.predict.interrupts_casts.sure = true
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of("Kick") })
    step(G)                                                -- the ledger settles on the tick
    f.predict = { interrupts_casts = { v = "it interrupts your casts", p = 0.8, conf = 0.8, reliability = 0.6, sure = true, adapting = false } }
    f.dist = 4
    assert_eq(G.I.press_veto("Aimed Shot", G.target, { cast = 3 }), nil, "its Kick seen down")
end }

-- --- the field checks: does what it presses work in the game? ------------------------------

local function fc_line(G)
    local out = {}
    for _, l in ipairs(G.I.fieldcheck.lines() or {}) do out[#out + 1] = l end
    return table.concat(out, " / ")
end

T[#T + 1] = { "field check stop_cast: the priest's heal stopped by your Scatter Shot (its bar gone early) is a yes; one that runs on is a no", function()
    local G = bundle()
    G.files = {}
    G.P.ctx.storage = { read_json = function(n) return G.files[n] end, write_json = function(n, v) G.files[n] = v return true end }
    G.known["Scatter Shot"] = true
    G.target.get_class = function() return WARRIOR end
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me, G.row.dist, G.distance = true, true, 20, 20
    G.row.hp, G.health[G.target.guid] = 0.2, 0.2
    group(G, { { name = "Mate", dist = 10 } })
    foe(G, 1, PRIEST, { name = "Priesty", row = { targeting_me = false, dist = 12, target_guid = G.target.guid, engaged = false } })
    G.rows[2].casting = G.casting("Flash Heal", 2.5, 3.0)
    step(G); step(G)
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", 0, G.id_of("Scatter Shot") })
    G.rows[2].casting = nil                                   -- the bar gone at once
    step(G)
    has(fc_line(G), "ends the player's cast: yes (1 of 1)", "stopped")
    -- A second one that runs on.
    G.rows[2].casting = G.casting("Greater Heal", 2.5, 3.0)
    step(G)
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", 0, G.id_of("Scatter Shot") })
    step(G, 0.6); step(G, 0.6)
    has(fc_line(G), "ends the player's cast: mixed (1 of 2)", "one went on")
end }

T[#T + 1] = { "field check peel: the warrior off your healer within 3 s after your peel is a yes", function()
    local G = bundle()
    G.files = {}
    G.P.ctx.storage = { read_json = function(n) return G.files[n] end, write_json = function(n, v) G.files[n] = v return true end }
    G.known["Scatter Shot"] = true
    G.target.get_class = function() return WARRIOR end
    G.in_combat, G.fight_age = true, 8
    local allies = group(G, { { name = "Heals", dist = 14, healer = true } })
    G.row.in_combat, G.row.targeting_me, G.row.target_guid, G.row.dist, G.distance = true, false, allies[1].guid, 12, 12
    step(G); step(G)
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", 0, G.id_of("Scatter Shot") })
    G.row.target_guid = nil                                   -- scattered: off the healer
    step(G)
    has(fc_line(G), "takes the enemy off your ally: yes (1 of 1)", "peeled")
end }

return T

-- Jambix AIO: the PvP intelligence for every class (PVP_INTEL_PLAN.md Stage
-- 14) -- the layer played as a warrior and a mage, not the hunter its first
-- stages were written for (tools/jtest/mock/intel_bundle.lua).
--
-- What these hold it to: the kill window counts your class's finishers and
-- bursts (a warrior's Execute is damage ready); the peel is your class's
-- tool in reach -- Intercept from 8 to 25 yd, Hamstring in melee, a mage's
-- Frost Nova cast on yourself; a melee class is never told to keep its
-- distance; the advice never names a hunter's ability to a warrior, and a
-- state with nothing left takes the class's own kit; the fight's record
-- knows your class.

local B = require("mock/intel_bundle")
local assert_eq, has = B.assert_eq, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, WARRIOR = B.ROGUE, B.WARRIOR

local function bundle(class_name, known)
    local G = B.bundle({ class = { key = class_name:lower(), class_name = class_name, power = class_name == "WARRIOR" and "RAGE" or "MANA",
                                    interrupts = {}, defensives = {}, escapes = {} } })
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.by_guid["nameplate1"] = G.target
    for _, n in ipairs(known or {}) do G.known[n] = true end
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me = true, true
    return G
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function settle(G) step(G) step(G, 1.0) step(G) end
local function healer_ally(G)
    G.group.in_group = true
    local h = unit(G, "Player-1-00000971", { name = "Heals", player = true, hostile = false })
    G.dist = { [h.guid] = 12 }
    G.members, G.healer = { h }, h
    return h
end
local function names(list) return table.concat(list or {}, "; ") end

local T = {}

T[#T + 1] = { "a warrior's kill window counts Execute as damage ready: a rogue at 20% with every out seen down is high confidence", function()
    local G = bundle("WARRIOR", { "Execute", "Recklessness" })
    G.target.get_class = function() return ROGUE end
    G.row.dist, G.distance = 4, 4
    step(G)
    for _, n in ipairs({ "Vanish", "Sprint", "Evasion" }) do G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of(n) }) end
    step(G)
    G.row.hp, G.health[G.target.guid] = 0.2, 0.2
    step(G)
    local k = G.S.kill.target
    assert_eq(k.v, "HIGH_CONFIDENCE_KILL_WINDOW", "high: " .. tostring(k.why))
    assert_eq(k.actions[1], "Recklessness", "the warrior's burst first")
end }

T[#T + 1] = { "a warrior's peel: Intercept from 8 to 25 yd, Hamstring in melee", function()
    local G = bundle("WARRIOR", { "Intercept", "Hamstring" })
    G.target.get_class = function() return ROGUE end
    local h = healer_ally(G)
    G.row.targeting_me, G.row.target_guid, G.row.dist, G.distance = false, h.guid, 15, 15
    step(G); step(G)
    assert_eq(G.S.team.peel and G.S.team.peel.action, "Intercept", "at 15 yd")
    G.row.dist, G.distance = 4, 4
    step(G)
    assert_eq(G.S.team.peel.action, "Hamstring", "in melee")
end }

T[#T + 1] = { "a mage's peel goes off around it: Frost Nova sent on yourself", function()
    local G = bundle("MAGE", { "Frost Nova" })
    G.target.get_class = function() return WARRIOR end
    local h = healer_ally(G)
    G.row.targeting_me, G.row.target_guid, G.row.dist, G.distance = false, h.guid, 7, 7
    settle(G)
    local p = G.S.team.peel
    assert_eq(p and p.action, "Frost Nova", "the nova")
    assert_eq(p.around, true, "around you")
    local sent = nil
    for i = 1, #G.casts do if G.names[G.casts[i].spell_id] == "Frost Nova" then sent = G.casts[i] end end
    assert(sent, "Frost Nova sent")
    assert(sent.target == G.player, "on yourself")
end }

T[#T + 1] = { "a warrior is never told to keep its distance, and never a hunter's ability; a state with nothing left takes the warrior's kit", function()
    local G = bundle("WARRIOR", { "Execute", "Mortal Strike" })
    G.target.get_class = function() return ROGUE end
    G.row.dist, G.distance = 3, 3
    settle(G)
    assert(G.S.tactic.state ~= "CONTROL_DISTANCE", "not the hunter's distance: " .. G.S.tactic.state)
    for _, a in ipairs(G.S.tactic.actions) do
        for _, hunter in ipairs({ "Wing Clip", "Concussive Shot", "Aimed Shot", "Scatter Shot", "Freezing Trap", "Feign Death", "Hunter's Mark" }) do
            assert(not a:find(hunter, 1, true), "no hunter's ability in the advice: " .. names(G.S.tactic.actions))
        end
    end
    -- At 20%, a kill window: the warrior's finishers.
    G.row.hp, G.health[G.target.guid] = 0.2, 0.2
    settle(G)
    if G.S.tactic.state == "KILL_WINDOW" then
        has(names(G.S.tactic.actions), "Execute", "the warrior's own: " .. names(G.S.tactic.actions))
    end
end }

T[#T + 1] = { "the fight's record knows your class (it said \"?\" before)", function()
    local G = bundle("WARRIOR", {})
    G.target.get_class = function() return ROGUE end
    G.row.dist, G.distance = 3, 3
    step(G); step(G)
    G.target.dead, G.row.dead, G.health[G.target.guid], G.row.hp = true, true, 0, 0
    step(G)
    local f = G.I.debrief.T.last
    assert(f, "closed")
    assert_eq(f.me.class, "WARRIOR", "your class")
end }

return T

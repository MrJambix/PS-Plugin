-- The melee swing on Forever, as a level 9 paladin (1.76.1). The live report:
-- "it uses blessing using also Seal when out of combat however it does not
-- hitting the mobs". Nothing a paladin presses before Crusader Strike starts
-- the swing, and the rotation never pressed Attack, so the mob was sealed at
-- and judged every ten seconds and never hit. Here the swing is off at the
-- pull (sim.swing_off) and only a running swing hits.
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever paladin (level 9): the swing started once, Holy Strike and Judgement on cooldown", function()
        local r = sim.check("paladin_level9", {
            min = 3, must = { "Attack", "Seal of Righteousness", "Holy Strike", "Judgement" },
            setup = function(s) s.swing_off() end,
        })
        assert(r.swinging, "the melee swing was never started")
        -- A START on a running swing does nothing, and the rule does not ask
        -- for one while the swing reads on.
        assert(r.count("Attack") == 1,
            "Attack pressed " .. r.count("Attack") .. " times (" .. r.summary() .. ")")
        -- Holy Strike (1.77.1): on its 10 s cooldown through a 24 s fight.
        assert(r.count("Holy Strike") >= 2,
            "Holy Strike pressed " .. r.count("Holy Strike") .. " times (" .. r.summary() .. ")")
    end },
}

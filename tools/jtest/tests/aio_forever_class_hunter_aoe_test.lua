-- The hunter's AOE melee weave (1.7.6, ALPHA/TEST) on Forever: the whole
-- plugin on the whole of JCore, as aio_forever_class_hunter_test, with its
-- class option on. It has to fight without an error and be the profile
-- running; from 20 yd that is the side out of melee (Auto Shot, the sting).
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever hunter: the AOE melee weave (ALPHA) fights, and is the profile running", function()
        local r = sim.check("hunter", { min = 3, distance = 20, pet = true, must = { "Auto Shot", "Serpent Sting" },
            setup = function(s) s.set("Rotation", "rot_hunter_aoe_weave", true) end })
        local P = r.b.P
        local stats = P.rotation.stats()
        if stats.profile ~= "aoe_weave" then
            error("the profile running is " .. tostring(stats.profile) .. ", not aoe_weave")
        end
        local class_module = P.rotation.active_class()
        print("    hunter: " .. tostring(stats.label) .. "; " .. tostring(class_module.aoe_status()))
    end },
}

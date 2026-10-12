-- The hunter's AOE melee weave on Forever: the whole plugin on the whole of
-- JCore, as aio_forever_class_hunter_test. It shipped as an option of its own
-- (1.7.6, ALPHA/TEST) running a profile of its own; since 1.8.1 it is Beast
-- Mastery's, with no switch: the old switch saved on changes nothing, Beast
-- Mastery is the profile running, it fights without an error, and from 20 yd
-- that is the side out of melee (Auto Shot, the sting).
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever hunter: the AOE melee weave is Beast Mastery's -- the old switch on changes nothing (1.8.1)", function()
        local r = sim.check("hunter", { min = 3, distance = 20, pet = true, must = { "Auto Shot", "Serpent Sting" },
            setup = function(s) s.set("Rotation", "rot_hunter_aoe_weave", true) end })
        local P = r.b.P
        local stats = P.rotation.stats()
        if stats.profile ~= "beast_mastery" then
            error("the profile running is " .. tostring(stats.profile) .. ", not beast_mastery")
        end
        local class_module = P.rotation.active_class()
        if class_module.weave_running() ~= true then error("Beast Mastery's weave is not running") end
        print("    hunter: " .. tostring(stats.label) .. "; " .. tostring(class_module.weave_status()))
    end },
}

-- The hunter's Beast Mastery (1.7.6) on Forever: the whole plugin on the
-- whole of JCore, as aio_forever_class_hunter_test. The Forever guides'
-- build shipped as an ALPHA behind a switch, then became the Beast Mastery
-- profile with the switch removed: a hunter led by Beast Mastery (or with no
-- points yet) runs it with nothing set, and a value the old switch saved
-- changes nothing. The mob here is on us from the start, so nothing waits
-- for the pet (the wait itself is tested in aio_hunter_test).
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever hunter: Beast Mastery is the profile running, with no switch to set", function()
        local r = sim.check("hunter", { min = 3, distance = 20, pet = true, must = { "Auto Shot", "Serpent Sting" },
            setup = function(s) s.set("Rotation", "rot_hunter_bm_alpha", false) end })
        local stats = r.b.P.rotation.stats()
        if stats.profile ~= "beast_mastery" then
            error("the profile running is " .. tostring(stats.profile) .. ", not beast_mastery")
        end
        print("    hunter: " .. tostring(stats.label))
    end },
}

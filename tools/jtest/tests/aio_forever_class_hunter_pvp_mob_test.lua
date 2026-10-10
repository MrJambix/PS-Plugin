-- The PvP hunter (1.7.6, ALPHA/TEST) switched on, on Forever, against a mob:
-- the PvE profile keeps running. One boot per file (mock/aio_boot), so this
-- is not in aio_forever_class_hunter_pvp_test.

local sim = require("mock/forever_class")

return {
    { "Forever hunter: the PvP hunter (ALPHA) switched on against a mob leaves the PvE profile running", function()
        local r = sim.check("hunter", { min = 3, distance = 20, pet = true, must = { "Auto Shot" },
            setup = function(s) s.set("Rotation", "rot_hunter_pvp_alpha", true) end })
        local stats = r.b.P.rotation.stats()
        if stats.profile == "pvp" then error("a mob ran the PvP profile") end
        print("    hunter: " .. tostring(stats.label) .. "; " .. tostring(r.b.P.pvphunter.status()))
    end },
}

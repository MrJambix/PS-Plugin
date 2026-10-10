-- The PvP hunter (1.7.6, ALPHA/TEST) on Forever: the whole plugin on the
-- whole of JCore, as aio_forever_class_hunter_test, with the class option on
-- and the mob made an enemy rogue (a player). It has to fight without an
-- error and be the PvP profile running. The option on against a mob
-- (aio_forever_class_hunter_pvp_mob_test) leaves the PvE profile in charge. Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

local function rogue_player(s)
    s.set("Rotation", "rot_hunter_pvp_alpha", true)
    s.mob.is_player = function() return true end
    s.mob.get_class = function() return 4 end
    s.mob.get_guid = function() return "Player-4619-0ABCDEF0" end
end

return {
    { "Forever hunter: the PvP hunter (ALPHA) fights an enemy rogue, and is the profile running", function()
        local r = sim.check("hunter", { min = 3, distance = 20, pet = true, must = { "Hunter's Mark" },
            setup = rogue_player })
        local stats = r.b.P.rotation.stats()
        if stats.profile ~= "pvp" then
            error("the profile running is " .. tostring(stats.profile) .. ", not pvp")
        end
        print("    hunter: " .. tostring(stats.label) .. "; " .. tostring(r.b.P.pvphunter.status()))
    end },
}

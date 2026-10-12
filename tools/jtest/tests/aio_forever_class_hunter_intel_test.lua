-- The PvP intelligence state model (PVP_INTEL_PLAN.md, Phase 2) on Forever:
-- the whole plugin on the whole of JCore, as aio_forever_class_hunter_pvp_test,
-- against an enemy rogue. It has to fight without an error, the picture has
-- to be on with the rogue carried, and the client's gaps (the combat log,
-- threat) have to be listed rather than read as safety.

local sim = require("mock/forever_class")

local function rogue_player(s)
    s.set("Rotation", "rot_hunter_pvp_alpha", true)
    s.mob.is_player = function() return true end
    s.mob.get_class = function() return 4 end
    s.mob.get_guid = function() return "Player-4619-0ABCDEF0" end
end

return {
    { "Forever hunter: the intel picture is on against an enemy rogue, and lists what Forever leaves out", function()
        local r = sim.check("hunter", { min = 3, distance = 20, pet = true, must = { "Hunter's Mark" },
            setup = rogue_player })
        local I = r.b.P.react and r.b.P.react.intel
        if not I then error("no intel layer on the reactions") end
        local S = I.S
        if not S.active then error("the picture is off: " .. tostring(S.why)) end
        if S.ticks < 10 then error("built only " .. S.ticks .. " times") end
        local f = S.foes["Player-4619-0ABCDEF0"]
        if not f then error("the rogue is not carried") end
        if f.class ~= "ROGUE" then error("its class reads " .. tostring(f.class)) end
        local role = I.sure(f.inferred.role, 0.6)
        if role ~= "melee" then error("its role reads " .. tostring(role)) end
        if not S.client.forever or S.client.combat_log then error("the client is not read as Forever") end
        local listed = false
        for _, line in ipairs(S.unavailable) do if line:find("combat log", 1, true) then listed = true end end
        if not listed then error("the combat log is not listed as unavailable") end
        local lines = I.lines()
        if not lines[2]:find("not on Forever", 1, true) then error("the readout does not say what Forever leaves out: " .. lines[2]) end
        print("    intel: " .. lines[1])
        print("    intel: " .. lines[2])
    end },
}

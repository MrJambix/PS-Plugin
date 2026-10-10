-- The rotation on Forever, as a hunter: the whole plugin on the whole of JCore,
-- the client answering as the JCore API recorder saw Forever answer (every
-- power read 0, no pet from get_pet, no range data, no shapeshift form), a
-- level-20 spellbook and a mob in melee range. The rotation must fight: press
-- the class's abilities, error nowhere, and not flip a form in and out.
-- Fights from 20 yd, and finds the pet get_pet does not name (JCore 1.5.14)
-- and sends it at the target.
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever hunter: the rotation fights with the class's abilities", function()
        sim.check("hunter", { min = 3, distance = 20, pet = true, must = { "Auto Shot", "Serpent Sting", "Arcane Shot" } })
    end },
}

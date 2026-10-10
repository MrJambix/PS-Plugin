-- The rotation on Forever, as a rogue: the whole plugin on the whole of JCore,
-- the client answering as the JCore API recorder saw Forever answer (every
-- power read 0, no pet from get_pet, no range data, no shapeshift form), a
-- level-20 spellbook and a mob in melee range. The rotation must fight: press
-- the class's abilities, error nowhere, and not flip a form in and out.
-- Builds counted combo points with Sinister Strike and spends them.
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever rogue: the rotation fights with the class's abilities", function()
        sim.check("rogue", { min = 2, must = { "Sinister Strike", "Slice and Dice" } })
    end },
}

-- The rotation on Forever, as a priest: the whole plugin on the whole of JCore,
-- the client answering as the JCore API recorder saw Forever answer (every
-- power read 0, no pet from get_pet, no range data, no shapeshift form), a
-- level-20 spellbook and a mob in melee range. The rotation must fight: press
-- the class's abilities, error nowhere, and not flip a form in and out.
-- Casts on a mana bar it cannot read.
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever priest: the rotation fights with the class's abilities", function()
        sim.check("priest", { min = 3, must = { "Smite", "Shadow Word: Pain", "Mind Blast" } })
    end },
}

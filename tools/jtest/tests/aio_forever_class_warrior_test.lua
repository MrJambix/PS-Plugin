-- The rotation on Forever, as a warrior: the whole plugin on the whole of JCore,
-- the client answering as the JCore API recorder saw Forever answer (every
-- power read 0, no pet from get_pet, no range data, no shapeshift form), a
-- level-20 spellbook and a mob in melee range. The rotation must fight: press
-- the class's abilities, error nowhere, and not flip a form in and out.
-- Takes its stance ONCE (the client cannot read it), then Rend, Sunder Armor
-- to five stacks and Heroic Strike with the rage the counted bar says is spare.
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever warrior: the rotation fights with the class's abilities", function()
        sim.check("warrior", { min = 4, seconds = 45, max_forms = 1, must = { "Rend", "Sunder Armor", "Heroic Strike" } })
    end },
}

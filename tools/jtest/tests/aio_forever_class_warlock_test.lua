-- The rotation on Forever, as a warlock: the whole plugin on the whole of JCore,
-- the client answering as the JCore API recorder saw Forever answer (every
-- power read 0, no pet from get_pet, no range data, no shapeshift form), a
-- level-20 spellbook and a mob in melee range. The rotation must fight: press
-- the class's abilities, error nowhere, and not flip a form in and out.
-- Dots on a mana bar it cannot read, and finds and sends the pet get_pet does
-- not name (JCore 1.5.14).
-- Shared by every class: tools/jtest/mock/forever_class.lua.
-- AIO 1.80.0: the spellbook calls Agony "Bane of Agony" on Forever, as the client
-- does; the rotation must put it up (it asked for "Curse of Agony" until then).

local sim = require("mock/forever_class")

return {
    { "Forever warlock: the rotation fights with the class's abilities", function()
        sim.check("warlock", { min = 3, pet = true, must = { "Corruption", "Immolate", "Bane of Agony" } })
    end },
}

-- The rotation on Forever, as a level 10 druid (AIO 1.8.1): Bear Form is
-- trained, Cat Form is not (20). The levelling rules were a cat's, so from 10
-- to 19 nothing was pressed. It must shift into Bear Form ONCE and fight in
-- it: Maul on the rage the swings give.
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever druid (level 10): Bear Form once, then the bear's rules", function()
        local r = sim.check("druid_level10", { min = 2, max_forms = 1, must = { "Bear Form", "Maul" } })
        assert(r.form == "Bear Form", "ended the fight in " .. tostring(r.form))
        assert(r.count("Wrath") == 0, "no Wrath from a bear (" .. r.summary() .. ")")
    end },
}

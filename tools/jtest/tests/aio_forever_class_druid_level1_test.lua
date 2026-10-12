-- The rotation on Forever, as a level 1 druid (AIO 1.8.1): the book of the
-- live dump -- Wrath, Healing Touch, the Night Elf racials. Every levelling
-- rule was a cat's, Cat Form comes at 20, and the live log has the druid
-- standing still in every fight: "no rotation rule passed". It must cast
-- Wrath, and never shift.
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever druid (level 1): Wrath, no form", function()
        local r = sim.check("druid_level1", { min = 1, max_forms = 0, must = { "Wrath" } })
        assert(r.count("Wrath") >= 3, "Wrath pressed " .. r.count("Wrath") .. " times (" .. r.summary() .. ")")
        assert(r.count("Shadowmeld") == 0, "Shadowmeld is no attack (" .. r.summary() .. ")")
    end },
}

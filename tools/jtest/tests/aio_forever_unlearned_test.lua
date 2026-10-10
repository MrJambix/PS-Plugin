-- Forever: a spell the client says is NOT known stays out of the AIO
-- spellbook even when has_spell vouches for it (a row the book shows but the
-- character has not learned), so nothing that asks known() presses it, and
-- the spellbook's trace line names it. The user (2026-10-03): "Stop trying to
-- use spells that aren't learned -- we need to be able to identify these."
-- Shared Forever fight: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever: a spell is_spell_known denies is left out, never pressed, and named in the trace", function()
        local lines = {}
        local book
        local r = sim.run("hunter", 24, function(s)
            local P = s.b.P
            book = P.spellbook
            P.ctx.on("jcore.recorder.trace", function(text) lines[#lines + 1] = text end)
            local arcane = s.spells["Arcane Shot"].id
            local sb = s.b.mock.core.spell_book
            local known = sb.is_spell_known
            -- is_spell_known says no; has_spell (untouched) still says yes.
            rawset(sb, "is_spell_known", function(id)
                if id == arcane then return false end
                return known(id)
            end)
            book.refresh()
        end, 20, true)

        print("    " .. r.summary())
        if r.errors ~= "" then error("core.log_error while fighting: " .. r.errors) end
        if book.known("Arcane Shot") then error("Arcane Shot is known although is_spell_known said no") end
        if r.count("Arcane Shot") > 0 then error("Arcane Shot was pressed " .. r.count("Arcane Shot") .. " time(s)") end
        if not book.known("Serpent Sting") then error("Serpent Sting dropped out of the spellbook") end
        if r.count("Serpent Sting") == 0 then error("the rotation stopped fighting: " .. r.summary()) end

        local named = nil
        for i = 1, #lines do
            if lines[i]:find("^spellbook: ") and lines[i]:find("not learned, left out: Arcane Shot", 1, true) then
                named = lines[i]
            end
        end
        if not named then
            error("no spellbook trace line names Arcane Shot as left out; saw:\n      " .. table.concat(lines, "\n      "))
        end
        if named:find("Word of Recall", 1, true) then error("array positions reported as spells: " .. named) end
        print("    " .. named)
    end },
}

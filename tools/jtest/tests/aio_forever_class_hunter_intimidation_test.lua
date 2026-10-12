-- The hunter's Intimidation on Forever (1.8.1): the whole plugin on the whole
-- of JCore, as aio_forever_class_hunter_test, with Intimidation trained and a
-- pet the client says nothing about -- not by get_pet, and not what it is
-- attacking (1.73.1). The user: "what about intimidation? I learned it
-- recently from my talents but i dont see it being used". Two things kept it
-- in the book: the catalogue's "pet on the target" need compared the player
-- (Intimidation is cast on yourself) with the pet's target, and the rule
-- asked the client for that target, which Forever never names. Then: "it
-- should be used ina Burst, Interrupt (stunt) or when I really need a mob off
-- me and Disengage is not available" -- so here it has to go out inside a
-- burst window, once.
-- Shared by every class: tools/jtest/mock/forever_class.lua.

local sim = require("mock/forever_class")

return {
    { "Forever hunter: Intimidation goes out in a burst window though the client never says what the pet attacks (1.8.1)", function()
        local windows, open = 0, false
        local in_window = 0
        local r = sim.check("hunter_intimidation", { min = 3, distance = 20, pet = true, pet_blind = true,
            must = { "Auto Shot", "Intimidation" },
            setup = function(s)
                s.b.P.ctx.on("jambix.aio.burst", function(opened)
                    open = opened == true
                    if open then windows = windows + 1 end
                end)
                s.b.P.ctx.on("jcore.cast.sent", function(request)
                    if open and type(request) == "table" and request.spell_id == 19577 then
                        in_window = in_window + 1
                    end
                end)
            end })
        if r.count("Intimidation") > 1 then
            error("Intimidation pressed " .. r.count("Intimidation") .. " times in one 60 s cooldown")
        end
        if windows < 1 then error("no burst window opened, yet Intimidation went out") end
        if in_window ~= 1 then error("Intimidation went out outside a burst window (" .. in_window .. " inside)") end
        print(string.format("    burst windows %d; Intimidation sent inside one: %d", windows, in_window))
    end },
}

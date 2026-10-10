-- Jambix AIO 1.7.5: a druid in Travel Form, the rotation on, on Forever (the
-- whole plugin, tools/jtest/mock/forever_class.lua). The form keeper shifted
-- it straight back into Cat Form. Now: out of combat it is left alone; in a
-- fight while moving (running away) too; standing still in the fight, the
-- profile's form again.

local sim = require("mock/forever_class")

local IDLE, FLEE = 10, 20       -- s after the pull: idle until, running until
-- The class window's buffs (Mark of the Wild, Thorns) are not the rotation's:
-- the client greys them out in a form, the mock does not.
local WINDOW = { ["Travel Form"] = true, ["Mark of the Wild"] = true, ["Thorns"] = true }

return {
    { "Forever druid: Travel Form is left alone out of combat and while running, not standing in a fight", function()
        local r = sim.run("druid", 30, function(x)
            local base = x.b.mock.time
            local function at() return x.b.mock.time - base - 0.5 end   -- the pull is 30 frames on
            x.enter_form("Travel Form")
            local target = x.me.get_target
            x.me.is_in_combat = function() return at() >= IDLE end
            x.me.get_target = function() if at() >= IDLE then return target() end return nil end
            x.me.is_moving = function() local t = at() return t >= IDLE and t < FLEE end
            x.me.is_auto_attacking = function() return at() >= FLEE end
        end)
        local first_shift = nil
        for i = 1, #r.casts do
            local c = r.casts[i]
            if (c.name == "Cat Form" or c.name == "Bear Form") and not first_shift then first_shift = c end
        end
        print(string.format("    druid in Travel Form: %s; first shift %s", r.summary(),
            first_shift and string.format("%s at %.1fs", first_shift.name, first_shift.t) or "none"))
        assert(r.errors == "", "errors: " .. tostring(r.errors))
        assert(first_shift ~= nil, "standing still in the fight: back into the profile's form")
        assert(first_shift.t >= FLEE, string.format("not before %ds: %s at %.1fs", FLEE, first_shift.name, first_shift.t))
        for i = 1, #r.casts do
            local c = r.casts[i]
            assert(c.t >= FLEE or WINDOW[c.name], string.format("the rotation pressed nothing while travelling: %s at %.1fs", c.name, c.t))
        end
    end },
}

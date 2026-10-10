-- Jambix AIO 1.64.1: the hunter's "Run and shoot before there is a pet" is
-- off by default. It shipped on, and the menu saves a default as the
-- player's value, so a player who has played has it saved on: it is switched
-- off once, a second after load, and noted; after that the switch is the
-- player's again. The whole plugin booted as Era.
local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local T = {}
local b

T[#T + 1] = { "boots clean as Era, kiting saved on as it shipped", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" }, function(mock)
        mock.menu:set("Jambix AIO/Rotation", "rot_hunter_kite", true)
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
end }

T[#T + 1] = { "switched off once, a second after load, and noted", function()
    b.mock.frame(90)
    b.P.opt_invalidate()
    assert_eq(b.P.opt("rot_hunter_kite", true), false, "switched off")
    b.ctx.storage.flush(true)
    local text = b.mock.data_fs["jcore/jambix.aio.migrations.json"]
    assert(text and text:find("hunter_kite_off", 1, true), "and noted: " .. tostring(text))
end }

T[#T + 1] = { "after that the switch is the player's", function()
    b.mock.menu:set("Jambix AIO/Rotation", "rot_hunter_kite", true)
    b.mock.frame(400)
    b.P.opt_invalidate()
    assert_eq(b.P.opt("rot_hunter_kite", false), true, "switched on by hand, it stays on")
    assert_eq(b.errors(), "", "core.log_error while running")
end }

return T

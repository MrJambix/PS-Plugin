-- Jambix AIO 1.7.6: the user, 2026-10-10, "enemies should not have Curtain
-- up by default should be off". JCore draws a beacon as a narrow curtain, and
-- the ESP stood one on every far rare, boss and quest mob. A curtain now: off
-- by default, in the World marks list, and switched off once by a second
-- pass. That pass is for a player the first one (curtains_off_1) already ran
-- for: it touches the beacons alone, so a curtain switched back on by hand
-- stays on. The whole plugin booted as Forever. (The battleground flag
-- carriers' beacon, the other one of this pass, left with the PvP extras on
-- 2026-10-11.)
local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local ESP = "Jambix AIO/Forever ESP"
local MIGRATIONS = "jcore/jambix.aio.migrations.json"

local T = {}
local b

T[#T + 1] = { "boots clean as Forever, the first curtain pass done, the beacons saved on, the aurora back on by hand", function()
    b = boot.run("Forever", "wow_forever_us", { "_classic_era_" }, function(mock)
        mock.data_fs[MIGRATIONS] = '{"curtains_off_1:Forever ESP":true}'
        mock.menu.values[ESP] = { esp_beacons = true, aurora_on = true }
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert_eq(b.P.forever, true, "Forever")
end }

T[#T + 1] = { "the beacons switched off once and noted; the aurora left on", function()
    b.mock.frame(90)
    b.P.opt_invalidate()
    local m = b.mock.menu
    assert_eq(m:get(ESP, "esp_beacons"), false, "the ESP's beacons")
    assert_eq(m:get(ESP, "aurora_on"), true, "a curtain switched back on by hand: the second pass leaves it")
    b.ctx.storage.flush(true)
    local text = b.mock.data_fs[MIGRATIONS]
    assert(text and text:find("curtains_off_2:Forever ESP", 1, true), "and noted: " .. tostring(text))
end }

T[#T + 1] = { "the beacons are in the World marks list, the second pass's; the flag carriers' beacon is gone", function()
    local seen = {}
    for _, c in ipairs(b.P.CURTAINS) do seen[c[2]] = c[5] end
    assert_eq(seen.esp_beacons, 2, "the ESP's beacons, the second pass's")
    assert_eq(seen.pvpx_bg, nil, "the flag carriers' beacon left with the PvP extras")
    assert_eq(seen.show_beacon, nil, "not the Classic ESP's pillars on Forever")
end }

T[#T + 1] = { "after that the switches are the player's", function()
    b.mock.menu:set(ESP, "esp_beacons", true)
    b.mock.frame(400)
    b.P.opt_invalidate()
    assert_eq(b.P.opt("esp_beacons", false), true, "switched on by hand, it stays on")
    assert_eq(b.errors(), "", "core.log_error while running")
end }

return T

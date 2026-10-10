-- Jambix Market on Classic Era: Forever only, so it registers, says so on
-- its page, and touches nothing -- no auction house call, no window, no
-- store, no job of its own. Forever is market_test.lua.

local mock = require("mock_core")
mock.install()
mock.frame_dt = 0.05
package.loaded["common/utility/spell_helper"] = { is_spell_castable = function() return false end }
package.loaded["common/utility/inventory_helper"] = { get_character_bag_slots = function() return {} end }
package.loaded["common/utility/icons_helper"] = {
    get_spell_icon_name = function() return nil end, draw_spell_icon = function() return false end,
}
mock.game_version = "Vanilla"
mock.exact_game_version = "wow_vanilla_us"

-- Every auction house call is counted, whatever its name.
local ah_calls = 0
mock.core.auction_house = setmetatable({}, {
    __index = function() return function() ah_calls = ah_calls + 1 return nil end end,
})

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local T = {}

T[#T + 1] = { "on Era it registers, explains, and does nothing", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("JCore boot raised: " .. tostring(err)) end
    local ok2, err2 = pcall(require, "jambix_market/main")
    if not ok2 then error("market boot raised: " .. tostring(err2)) end
    mock.frame(40)
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    mock.frame(40)
    if #mock.errors > 0 then error("core.log_error was called:\n" .. mock.error_text()) end
    assert(_G.JCore.is_running("jambix.market"), "registered")
    assert_eq(_G.JambixMarket, nil, "no bundle published")
    assert_eq(ah_calls, 0, "no auction house call")
    local page = mock.menu.pages["Jambix Market"]
    assert(page, "its page is there")
    assert_eq(#page.sections, 1, "one section: the Forever-only note")
    for name in pairs(mock.data_fs) do
        assert(not name:find("jambix.market", 1, true), "no file written: " .. name)
    end
end }

return T

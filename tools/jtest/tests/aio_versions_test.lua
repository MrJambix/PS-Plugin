-- Jambix AIO: the overlay's data for the clients past Classic -- gathering
-- nodes by name across the expansions, and the faction of every race.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local cfg = require("jambix_aio/modules/config")

local T = {}

T[#T + 1] = { "herbs: Classic and TBC by name, the later expansions inside variant names", function()
    for _, name in ipairs({ "Peacebloom", "Black Lotus", "Felweed", "Glowcap" }) do
        assert(cfg.is_herb(name), name)
    end
    for _, name in ipairs({ "Goldclover", "Frozen Herb", "Lush Hochenblume", "Windswept Writhebark",
        "Irradiated Mycobloom", "Crystallized Luredrop", "Sporefused Arathor's Spear", "Star Moss" }) do
        assert(cfg.is_herb(name), name)
    end
    for _, name in ipairs({ "Copper Vein", "Battered Chest", "Mailbox", "Campfire" }) do
        assert(not cfg.is_herb(name), name .. " is not a herb")
    end
end }

T[#T + 1] = { "ore: veins and deposits everywhere, and The War Within's seams and names", function()
    for _, name in ipairs({ "Copper Vein", "Fel Iron Deposit", "Saronite Deposit", "Serevite Deposit",
        "Bismuth", "Rich Ironclaw", "Aqirite Seam", "Crystallized Bismuth" }) do
        assert(cfg.is_ore(name), name)
    end
    for _, name in ipairs({ "Peacebloom", "Battered Chest" }) do
        assert(not cfg.is_ore(name), name .. " is not ore")
    end
end }

T[#T + 1] = { "factions: the classic races, the allied races, and both Pandaren halves", function()
    local want = {
        [1] = "alliance", [2] = "horde", [8] = "horde", [11] = "alliance",
        [22] = "alliance", [25] = "alliance", [26] = "horde", [29] = "alliance",
        [36] = "horde", [52] = "alliance", [70] = "horde", [84] = "horde", [85] = "alliance",
    }
    for race, side in pairs(want) do
        if cfg.RACE_FACTION[race] ~= side then
            error(string.format("race %d: expected %s, got %s", race, side, tostring(cfg.RACE_FACTION[race])))
        end
    end
    assert(cfg.RACE_FACTION[24] == nil, "the neutral Pandaren has no side")
end }

return T

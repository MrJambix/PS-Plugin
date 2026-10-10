-- Jambix AIO 1.73.2: soul shards in Forever's bags (modules/hardcore.lua).
-- Bag 0 on Forever is the whole item array, the merchant's Buyback list
-- included, and the loader's helper lists Buyback rows past the backpack.
-- Shards are counted and destroyed in JCore's corrected bag rows there; a
-- destroy the client said yes to must leave the bags one shorter, or nothing
-- more is destroyed. Era keeps its own walk.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function item(name, id)
    return { get_name = function() return name end, get_item_id = function() return id or 6265 end }
end

--- The bags: `inside` rows in the backpack, `sold` rows past it (Buyback).
local function build(opts)
    local W = { clock = 1000, destroyed = {}, warned = {}, gone = opts.gone ~= false }
    local inside, sold = {}, {}
    for i = 1, opts.inside or 0 do inside[i] = { item = item("Soul Shard"), bag_id = 0, bag_slot = i, stack_count = 1 } end
    for i = 1, opts.sold or 0 do sold[i] = { item = item("Soul Shard"), bag_id = 0, bag_slot = 38 + i, stack_count = 1 } end
    W.inside = inside
    local function helper_rows()
        local all = {}
        for i = 1, #sold do all[#all + 1] = sold[i] end           -- Buyback first: the trap
        for i = 1, #inside do all[#all + 1] = inside[i] end
        return all
    end
    _G.core = {
        time = function() return W.clock end,
        inventory = {
            get_items_in_bag = function(bag)
                if bag ~= 0 then return {} end
                local out = {}
                for _, r in ipairs(helper_rows()) do out[#out + 1] = { object = r.item, slot_id = r.bag_slot } end
                return out
            end,
        },
        input = {
            destroy_container_item = function(bag, slot)
                W.destroyed[#W.destroyed + 1] = { bag = bag, slot = slot }
                if W.gone then
                    for i = #inside, 1, -1 do
                        if inside[i].bag_id == bag and inside[i].bag_slot == slot then table.remove(inside, i) end
                    end
                end
                return true
            end,
        },
    }
    package.loaded["common/utility/inventory_helper"] = {
        get_character_bag_slots = function() return helper_rows() end,
        get_current_consumables_list = function() return {} end,
    }
    local P = {
        ctx = setmetatable({
            every = function() end, on = function() end, tick = function() end, emit = function() end,
            render = function() end,
            world = { client = function() return { forever = opts.forever == true } end },
            inventory = { bag_rows = function() return inside end },
        }, { __index = function() return function() end end }),
        log = {
            fmt = function(level, f, ...) if level == "warn" then W.warned[#W.warned + 1] = string.format(f, ...) end end,
            once = function() end, info = function() end, warn = function() end, debug = function() end,
        },
        units = setmetatable({}, { __index = function() return function() return nil end end }),
        combat = setmetatable({}, { __index = function() return function() return false end end }),
        draw = setmetatable({}, { __index = function() return function() end end }),
        spellbook = setmetatable({}, { __index = function() return function() return nil end end }),
        opt = function(_, default) return default end,
        derived = function(_, default) return default / 100 end,
        tune = function(_, default) return default / 100 end,
    }
    package.loaded["jambix_aio/modules/hardcore"] = nil
    W.hc = require("jambix_aio/modules/hardcore")(P)
    return W
end

local T = {}

T[#T + 1] = { "Forever: shards sold to a vendor are not counted, and a destroy goes to the backpack, not Buyback", function()
    local W = build({ forever = true, inside = 3, sold = 2 })
    assert_eq(W.hc.count_now("soulshard"), 3, "the three in the backpack, not the two in Buyback")
    assert_eq(W.hc.destroy_one("soulshard", "test"), true, "destroyed")
    assert_eq(W.destroyed[1].slot <= 20, true, "a backpack slot, not Buyback's " .. tostring(W.destroyed[1].slot))
    assert_eq(W.hc.count_now("soulshard"), 2, "one fewer")
end }

T[#T + 1] = { "a destroy the client said yes to but that left the shard: nothing more is destroyed this session", function()
    local W = build({ forever = true, inside = 4, gone = false })
    assert_eq(W.hc.destroy_one("soulshard", "test"), true, "the client said yes")
    W.clock = W.clock + 3
    assert_eq(W.hc.destroy_one("soulshard", "test"), false, "still four: destroying does nothing here")
    local said = 0
    for _, line in ipairs(W.warned) do if line:find("did nothing", 1, true) then said = said + 1 end end
    assert_eq(said, 1, "and says so once")
    W.clock = W.clock + 3
    assert_eq(W.hc.destroy_one("soulshard", "test"), false, "and stays off")
    assert_eq(#W.destroyed, 1, "one call in all")
    said = 0
    for _, line in ipairs(W.warned) do if line:find("did nothing", 1, true) then said = said + 1 end end
    assert_eq(said, 1, "said once, not every try")
end }

T[#T + 1] = { "Era: its own walk, as before (bag 0's rows, sold ones and all, are what Era's client hands out)", function()
    local W = build({ forever = false, inside = 3, sold = 0 })
    assert_eq(W.hc.count_now("soulshard"), 3, "counted by the walk")
end }

return T

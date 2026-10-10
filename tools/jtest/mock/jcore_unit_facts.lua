-- JCore 1.6.0's names and loot services, the real ones, on a test's hand-built
-- world: for AIO module tests that used to own these reads themselves.
--
--   local facts = require("mock/jcore_unit_facts").build({
--       units = units, list = list, enemies = erows, combat = combat,
--       creatures = cache, group = group, handlers = handlers, forever = true,
--   })
--   P.ctx.on = facts.on            -- one bus for the module and for JCore
--   P.ctx.names, P.ctx.loot = facts.names, facts.loot
--   facts.poll()                   -- what JCore does once a tick
--
-- `handlers[name](args)` then fires every subscriber, the module's and JCore's.

local M = {}

function M.build(o)
    local handlers = o.handlers or {}
    local subs = {}
    local function on(name, fn)
        if not subs[name] then
            subs[name] = {}
            handlers[name] = function(...) for _, f in ipairs(subs[name]) do f(...) end end
        end
        table.insert(subs[name], fn)
    end
    local stores = {}
    local erows = o.enemies or {}
    local list = o.list or {}
    local rt = {
        log = { for_tag = function() return { fmt = function() end } end },
        events = { on = function(name, fn) on(name, fn) end, emit = function() end },
        world = { client = function() return { forever = o.forever ~= false } end },
        storage = { store = function(name)
            stores[name] = stores[name] or { data = {}, touch = function() end }
            return stores[name]
        end },
        units = o.units,
        combat = o.combat or { target = function() return nil end },
        creatures = o.creatures,
        group = { objects = function()
            local out = {}
            local members = o.group and o.group.members and o.group.members() or {}
            for i = 1, #members do out[i] = { guid = members[i].guid } end
            return out
        end },
        enemies = { all = function()
            local out = {}
            for guid, row in pairs(erows) do
                row.guid = guid
                for i = 1, #list do if list[i].guid == guid then row.obj = list[i] end end
                out[#out + 1] = row
            end
            return out
        end },
    }
    package.loaded["jcore/services/names"] = nil
    package.loaded["jcore/services/loot"] = nil
    rt.names = require("jcore/services/names")(rt)
    rt.loot = require("jcore/services/loot")(rt)
    return {
        on = on, handlers = handlers, stores = stores,
        names = rt.names, loot = rt.loot,
        poll = function() rt.loot._poll() end,
    }
end

return M

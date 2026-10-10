-- Jambix AIO 1.54.2: the loot window on Forever (modules/world.lua). There
-- loot_object opens the corpse but the items stay in the window (session 31:
-- one corpse opened five times, its Rough Stone still there twice, a
-- nameless coin slot every time), and the stuck-window closer shut it with the
-- loot inside. On Forever the slots are now taken with loot_item before that.
-- Era closes a stuck window exactly as before and takes nothing.
--
-- 1.78.2 (JCore 1.8.11): slots 0 to the count minus 1. The client numbers
-- them from 0 (the loot study, 2026-10-05), and loot_item raises "specified
-- invalid slot" for the one at the count, which the old inclusive pass asked
-- for on every window. The fake client here raises the same way.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- world.lua on a hand-built bundle, with a loot window whose slots are
--- numbered from 0, as Forever's are. A slot outside the window raises, as
--- Forever's loot_item does.
local function world(forever, slots)
    local W = { clock = 100, taken = {}, closed = 0, traces = {}, slots = {}, raised = 0 }
    for i, name in ipairs(slots) do W.slots[i - 1] = name end
    local size = #slots
    local function left()
        local n = 0
        for _ in pairs(W.slots) do n = n + 1 end
        return n
    end
    W.locked = false
    _G.core = {
        time = function() return W.clock end,
        game_ui = {
            get_loot_item_count = function() return left() end,
            get_loot_item_name = function(i) return W.slots[i] end,
        },
        input = {
            loot_item = function(i)
                W.taken[#W.taken + 1] = i
                if i < 0 or i >= size then
                    W.raised = W.raised + 1
                    error("loot_item, specified invalid slot")
                end
                if not W.locked then W.slots[i] = nil end
            end,
            close_loot = function()
                W.closed = W.closed + 1
                W.slots = {}
            end,
        },
    }
    local tick
    -- JCore's loot service, the real one, as this client would run it.
    local facts = require("mock/jcore_unit_facts").build({
        forever = forever, units = { guid = function(u) return u and u.guid end },
    })
    local P = {
        forever = forever,
        master_on = function() return true end,
        opt = function(id, default)
            if id == "autoloot_on" then return true end
            return default
        end,
        log = { fmt = function() end, debug = function() end },
        actions = { blocked_reason = function() return "test" end },
        esp = { corpses = function() return {} end, nodes = function() return {} end, stats = function() return {} end },
        ctx = {
            loot = facts.loot,
            render = function() end,
            on = function() end,
            tick = function(fn) tick = fn end,
            emit = function(name, text)
                if name == "jcore.recorder.trace" then W.traces[#W.traces + 1] = text end
            end,
        },
    }
    package.loaded["jambix_aio/modules/world"] = nil
    require("jambix_aio/modules/world")(P)
    function W.run(seconds)
        local steps = math.floor(seconds / 0.5 + 0.5)
        for _ = 1, steps do
            W.clock = W.clock + 0.5
            tick()
        end
    end
    W.tick = function() tick() end
    W.left = left
    return W
end

local function has(list, text)
    for i = 1, #list do if list[i]:find(text, 1, true) then return true end end
    return false
end

local T = {}

T[#T + 1] = { "Forever: the slots are taken, 0 to the count minus 1, none past them; the window is not closed on them (1.78.2)", function()
    local W = world(true, { "Rough Stone", "" })
    W.tick()                      -- the window is seen open
    W.run(0.5)                    -- 0.5 s on: the first pass
    assert_eq(W.left(), 0, "everything taken")
    assert_eq(table.concat(W.taken, ","), "0,1", "slots 0 and 1, and not slot 2")
    assert_eq(W.raised, 0, "no slot the client calls invalid")
    assert(has(W.traces, "loot window: 2 slot(s): Rough Stone, coins; took slots 0-1 (pass 1)"),
        "the pass is traced: " .. table.concat(W.traces, " | "))
    W.run(0.5)
    assert(has(W.traces, "loot window: emptied after 1 pass(es)"), "and its end")
    assert_eq(W.closed, 0, "nothing closed")
end }

T[#T + 1] = { "Forever: a window that will not empty gets two passes, then the closer, and says what was left", function()
    local W = world(true, { "Rough Stone", "" })
    W.locked = true
    W.tick()
    W.run(3.5)
    assert_eq(#W.taken, 4, "two passes over slots 0-1")
    assert_eq(W.raised, 0, "neither pass asks past the window")
    assert_eq(W.closed, 1, "then closed")
    assert(has(W.traces, "loot window: closed with 2 slot(s) left after 2 pass(es)"),
        "said: " .. table.concat(W.traces, " | "))
end }

T[#T + 1] = { "Era: nothing is taken, a stuck window is closed after the timeout as before, no trace", function()
    local W = world(false, { "Rough Stone" })
    W.tick()
    W.run(3.0)
    assert_eq(#W.taken, 0, "no loot_item on Era")
    assert_eq(W.closed, 0, "not before the timeout")
    W.run(0.5)
    assert_eq(W.closed, 1, "closed once it is stuck")
    assert_eq(#W.traces, 0, "no trace lines on Era")
end }

return T

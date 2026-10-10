-- JCore 1.6.0 / services/dump.lua: the whole of JCore booted as Forever, a
-- small spellbook and trait tree in the mock client, the dump written, and the
-- file read back: spells with their ids and details, the trait nodes, the
-- active talents, the API surface. Nothing is learned or cast.

local mock = require("mock_core")
mock.install()
package.loaded["common/utility/spell_helper"] = { is_spell_castable = function() return false end }
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"
mock.wow_fs["WTF/Config.wtf"] = 'SET textLocale "enUS"\n'

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local JCore, ctx

local T = {}

T[#T + 1] = { "boot as Forever", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(err)) end
    JCore = _G.JCore
    mock.frame(3)
    ctx = JCore.register({ id = "jtest.dump", name = "Dump test", version = "1.0.0" })
    assert(ctx.dump and ctx.dump.dump, "ctx.dump is handed to plugins")
end }

T[#T + 1] = { "the dump: spells with ids and details, trait nodes, active talents, the API", function()
    local names = { [75] = "Auto Shot", [2973] = "Raptor Strike", [1259719] = "Mace Specialization" }
    local learned_calls = 0
    local book = mock.core.spell_book
    rawset(book, "get_spells", function() return { 75, 2973, 1259719, 999999 } end)
    rawset(book, "get_spell_name", function(id) return names[id] or "" end)
    rawset(book, "is_spell_known", function(id) return names[id] ~= nil end)
    rawset(book, "get_spell_cast_time", function(id) return id == 75 and 0 or 0 end)
    rawset(book, "get_spell_costs", function(id)
        if id == 2973 then return { { cost = 15, cost_type = 0 } } end
        return {}
    end)
    rawset(book, "get_spell_description", function(id)
        return id == 2973 and "A strong attack that increases melee damage by 11." or ""
    end)
    rawset(book, "learn_spell", function() learned_calls = learned_calls + 1 end)
    local ui = mock.core.game_ui
    rawset(ui, "get_talent_tree_ids", function() return { 1091 } end)
    rawset(ui, "get_talent_tree_nodes", function() return { 104960, 104961 } end)
    rawset(ui, "get_talent_node_info", function(node)
        return { node_id = node, node_type = 0, max_ranks = 5, active_rank = 0, entry_ids = { node + 24661 } }
    end)
    rawset(ui, "get_active_talents", function()
        return { { node_id = 104961, spell_id = 1259719, name = "Mace Specialization", rank = 1 } }
    end)
    rawset(ui, "learn_talent", function() learned_calls = learned_calls + 1 end)

    local file, info = ctx.dump.dump()
    assert_eq(file, "jcore/jcore.dump.forever.json", "the file is named for the client")
    assert_eq(info.spells, 3, "three named spells; an id the client cannot name is left out")
    assert_eq(info.nodes, 2, "both trait nodes")
    assert(info.functions > 50, "the core API surface: " .. tostring(info.functions))
    assert_eq(learned_calls, 0, "nothing learned, bought or cast")

    local doc = JCore.json.decode(mock.data_fs[file])
    assert_eq(doc.client.forever, true, "the client's flags")
    local raptor
    for _, s in ipairs(doc.spells) do if s.id == 2973 then raptor = s end end
    assert(raptor, "Raptor Strike by id")
    assert_eq(raptor.name, "Raptor Strike", "its name")
    assert_eq(raptor.known, true, "known")
    assert_eq(raptor.costs[1].cost, 15, "its cost")
    assert(raptor.description:find("melee damage", 1, true), "its tooltip")
    assert_eq(doc.talents.trees["1091"][1].entry_ids[1], 129621, "a node's entry ids")
    assert_eq(doc.talents.active[1].spell_id, 1259719, "an active talent's spell")
    assert(type(doc.api.core.spell_book) == "table" and #doc.api.core.spell_book > 10, "the spell_book namespace")
    if type(rawget(mock.core, "addons")) == "table" and type(rawget(mock.core.addons, "questie")) == "table" then
        assert(type(doc.api.core["addons.questie"]) == "table", "a sub-namespace")
    end
    assert_eq(#mock.errors, 0, "no core.log_error")
end }

T[#T + 1] = { "the click-to-move probe: each call's answer or error, to a file (1.6.13)", function()
    local seen = {}
    rawset(mock.core.input, "cm", function(...)
        local n = select("#", ...)
        seen[#seen + 1] = n
        local first = ...
        if first == nil then error("cm: core.vec3 expected, got nil") end
        return true
    end)
    local file, doc = ctx.dump.probe_cm()
    assert_eq(file, "jcore/jcore.probe.forever.json", "the file is named for the client")
    assert_eq(doc.exists, true, "cm exists here")
    assert_eq(#doc.results, 3, "three calls")
    assert_eq(seen[1], 0, "first with nothing")
    assert_eq(seen[2], 1, "then with nil")
    assert(doc.results[1].error:find("vec3 expected", 1, true), "its error says what it takes: " .. tostring(doc.results[1].error))
    assert_eq(doc.results[3].label, "cm(where you stand)", "then with a position")
    local back = JCore.json.decode(mock.data_fs[file])
    assert_eq(back.results[1].ok, false, "written")
end }

return T

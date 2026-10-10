-- Scratch: nodememory on the whole booted plugin (Era), real JCore services.
local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2) end
end

local function thing(p, pos)
    local methods = {}
    for k, v in pairs(p) do methods[k] = function() return v end end
    methods.get_position = function() return pos end
    local none = function() return nil end
    return setmetatable({}, { __index = function(_, k) return methods[k] or none end })
end

local T = {}
T[#T + 1] = { "Forever boot: a herb taken in front of you is remembered through the real services", function()
    local me = thing({ is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001", get_name = "Me",
        get_class = 1, get_level = 30, get_health = 900, get_max_health = 1000, is_player = true, is_unit = true,
        is_channelling_spell = false, get_type = 6 }, { x = 100, y = 100, z = 0 })
    local herb = thing({ is_valid = true, get_guid = "GameObject-0-1-0-0-1617-00000ABC", get_name = "Peacebloom",
        is_unit = false, is_player = false, get_type = 8, can_be_used = true, get_npc_id = 1617 }, { x = 110, y = 100, z = 0 })
    local visible = { me, herb }
    local b = boot.run("Forever", "wow_forever_us", { "_classic_era_" }, function(mock)
        rawset(mock.core.object_manager, "get_local_player", function() return me end)
        rawset(mock.core.object_manager, "get_visible_objects", function() return visible end)
        rawset(mock.core.object_manager, "get_object_from_guid", function(g)
            for i = 1, #visible do if visible[i]:get_guid() == g then return visible[i] end end
            return nil
        end)
        rawset(mock.core, "get_server_time", function() return 1790000000 + math.floor(mock.time or 0) end)
    end)
    assert_eq(b.errors(), "", "boot errors")
    b.mock.menu:set("Jambix AIO/Forever ESP", "gather_skill_only", false)
    b.mock.menu:set("Jambix AIO/Forever ESP", "toggle_key", { vk = 0x5A, active = true, toggled = true })
    package.loaded["jambix_aio/modules/nodememory"] = nil
    local N = require("jambix_aio/modules/nodememory")(b.P)
    for _ = 1, 20 do b.mock.frame(); N.render() end
    local list = b.P.esp.forever.node_marks()
    assert(#list >= 1, "the Forever ESP marks the herb: " .. #list)
    visible[2] = nil
    for _ = 1, 20 do b.mock.frame(); N.render() end
    assert_eq(#N.spots(), 1, "remembered")
    local s = N.spots()[1]
    assert_eq(s.n, "Peacebloom", "named"); assert_eq(s.k, "herb", "a herb")
    assert_eq(N.stats().clock, "realm", "on the realm's clock")
    assert_eq(b.errors(), "", "no errors")
    -- the store: written by JCore's storage
    local store = b.ctx.store("nodememory")
    assert(store.data.zones and next(store.data.zones), "in the plugin's store")
    assert(store.dirty, "marked for the debounced write")
    b.mock.frame(200)
    for _ = 1, 3 do b.mock.frame(); N.render() end
    assert_eq(b.errors(), "", "no errors after the store's write")
end }
return T

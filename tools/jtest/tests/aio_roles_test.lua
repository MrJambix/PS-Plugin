-- Jambix AIO: the player role resolver (modules/esp/roles.lua), and the config
-- rows it and the class-icon drawer read. Runs against a hand-built bundle so
-- each tier of the answer -- group role, spec id, form aura, class default --
-- can be exercised on its own.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local cfg = require("jambix_aio/modules/config")
local make_roles = require("jambix_aio/modules/esp/roles")

-- Ids as common/enums numbers them.
local CLASS = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6,
    SHAMAN = 7, MAGE = 8, WARLOCK = 9, MONK = 10, DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
}
local ROLE = { NONE = 0, TANK = 1, HEALER = 2, DAMAGER = 3 }

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A unit stub. `auras` is a list of spell ids on it.
local function unit(opts)
    local auras = {}
    for i = 1, #(opts.auras or {}) do auras[opts.auras[i]] = { buff_id = opts.auras[i] } end
    return {
        _auras = auras,
        get_group_role = function() return opts.group_role or ROLE.NONE end,
        get_specialization_id = function() return opts.spec or 0 end,
        is_valid = function() return true end,
    }
end

local function bundle(opts)
    opts = opts or {}
    local enums = {
        class_id = CLASS,
        group_role = ROLE,
        class_spec_to_role = opts.spec_roles and {
            get_group_role_backup = opts.spec_roles,
        } or nil,
    }
    return {
        cfg = cfg,
        enums = enums,
        units = { aura_index = function(u) return u._auras end },
        ctx = {
            ROLE = ROLE,
            group = opts.no_group_service and nil or {
                role = function(u) return u:get_group_role() end,
            },
        },
    }
end

local T = {}

T[#T + 1] = { "config: every class has a default role and an icon-worthy name", function()
    for name in pairs(cfg.CLASS_RGB) do
        local d = cfg.ROLE_DEFAULT[name]
        assert(d, "ROLE_DEFAULT missing " .. name)
        assert(cfg.ROLE_RGB[d[1]], name .. " defaults to unknown role " .. tostring(d[1]))
        assert(type(d[2]) == "boolean", name .. " default certainty is not a boolean")
    end
    for class_name, rows in pairs(cfg.ROLE_TELLS) do
        assert(cfg.CLASS_RGB[class_name], "ROLE_TELLS names unknown class " .. class_name)
        for i = 1, #rows do
            assert(type(rows[i][1]) == "table" and #rows[i][1] > 0, class_name .. " tell " .. i .. " has no ids")
            assert(cfg.ROLE_RGB[rows[i][2]], class_name .. " tell " .. i .. " names unknown role")
        end
    end
    for role in pairs(cfg.ROLE_RGB) do
        assert(cfg.ROLE_LETTER[role], "no badge letter for " .. role)
    end
    local el = cfg.ELEMENT_BY_KEY.show_class_icon
    assert(el and el.kind == "unit" and el.lod == "mid", "show_class_icon row")
end }

T[#T + 1] = { "class names map back from the enum ids", function()
    local roles = make_roles(bundle())
    assert_eq(roles.class_name(CLASS.WARRIOR), "WARRIOR", "warrior")
    assert_eq(roles.class_name(CLASS.EVOKER), "EVOKER", "evoker")
    assert_eq(roles.class_name(99), nil, "unknown id")
    assert_eq(roles.class_name(nil), nil, "nil id")
end }

T[#T + 1] = { "tier 1: the group role wins over everything", function()
    local roles = make_roles(bundle())
    local u = unit({ group_role = ROLE.HEALER, auras = { 71 } })   -- healer in Defensive Stance
    local role, certain = roles.role(u, { is_player = true, class_id = CLASS.WARRIOR })
    assert_eq(role, "healer", "role")
    assert_eq(certain, true, "certain")
end }

T[#T + 1] = { "tier 1: works without the group service", function()
    local roles = make_roles(bundle({ no_group_service = true }))
    local u = unit({ group_role = ROLE.TANK })
    local role, certain = roles.role(u, { is_player = true, class_id = CLASS.MAGE })
    assert_eq(role, "tank", "role")
    assert_eq(certain, true, "certain")
end }

T[#T + 1] = { "tier 2: a spec id is mapped through the enums", function()
    local asked = nil
    local roles = make_roles(bundle({
        spec_roles = function(class_id, spec)
            asked = { class_id, spec }
            return ROLE.TANK
        end,
    }))
    local u = unit({ spec = 250 })
    local role, certain = roles.role(u, { is_player = true, class_id = CLASS.DEATHKNIGHT })
    assert_eq(role, "tank", "role")
    assert_eq(certain, true, "certain")
    assert(asked and asked[1] == CLASS.DEATHKNIGHT and asked[2] == 250, "backup asked with class and spec")
end }

T[#T + 1] = { "tier 2: spec 0 is not a spec", function()
    local roles = make_roles(bundle({
        spec_roles = function() error("must not be asked for spec 0") end,
    }))
    local role = roles.role(unit({ spec = 0 }), { is_player = true, class_id = CLASS.ROGUE })
    assert_eq(role, "dps", "falls through to the class")
end }

T[#T + 1] = { "tier 3: forms and stances give the role away", function()
    local roles = make_roles(bundle())
    local cases = {
        { CLASS.WARRIOR, { 71 },    "tank" },
        { CLASS.WARRIOR, { 2458 },  "dps" },
        { CLASS.DRUID,   { 9634 },  "tank" },
        { CLASS.DRUID,   { 768 },   "dps" },
        { CLASS.DRUID,   { 24858 }, "dps" },
        { CLASS.DRUID,   { 33891 }, "healer" },
        { CLASS.PRIEST,  { 15473 }, "dps" },
        { CLASS.PALADIN, { 25780 }, "tank" },
        { CLASS.DEATHKNIGHT, { 48263 }, "tank" },
        { CLASS.MONK,    { 115070 }, "healer" },
    }
    for i = 1, #cases do
        local c = cases[i]
        local role, certain = roles.role(unit({ auras = c[2] }), { is_player = true, class_id = c[1] })
        assert_eq(role, c[3], "case " .. i)
        assert_eq(certain, true, "case " .. i .. " certain")
    end
end }

T[#T + 1] = { "tier 3: the first matching tell wins", function()
    local roles = make_roles(bundle())
    -- Bear Form outranks Cat Form in the table; both present is nonsense
    -- but the answer must still be deterministic.
    local role = roles.role(unit({ auras = { 768, 5487 } }), { is_player = true, class_id = CLASS.DRUID })
    assert_eq(role, "tank", "bear first")
end }

T[#T + 1] = { "tier 3: single-job classes are certain, hybrids are guesses", function()
    local roles = make_roles(bundle())
    local role, certain

    role, certain = roles.role(unit({}), { is_player = true, class_id = CLASS.HUNTER })
    assert_eq(role, "dps", "hunter"); assert_eq(certain, true, "hunter certain")

    role, certain = roles.role(unit({}), { is_player = true, class_id = CLASS.WARLOCK })
    assert_eq(role, "dps", "warlock"); assert_eq(certain, true, "warlock certain")

    role, certain = roles.role(unit({}), { is_player = true, class_id = CLASS.PALADIN })
    assert_eq(role, "healer", "paladin"); assert_eq(certain, false, "paladin is a guess")

    role, certain = roles.role(unit({}), { is_player = true, class_id = CLASS.WARRIOR })
    assert_eq(role, "dps", "warrior"); assert_eq(certain, false, "warrior with no stance is a guess")

    role, certain = roles.role(unit({}), { is_player = true, class_id = CLASS.DRUID })
    assert_eq(role, "healer", "druid"); assert_eq(certain, false, "caster-form druid is a guess")
end }

T[#T + 1] = { "nothing to guess from: not a player, or no class", function()
    local roles = make_roles(bundle())
    local role, certain = roles.role(unit({}), { is_player = false, class_id = CLASS.WARRIOR })
    assert_eq(role, nil, "npc"); assert_eq(certain, false, "npc certain")
    role, certain = roles.role(unit({}), { is_player = true, class_id = nil })
    assert_eq(role, nil, "no class"); assert_eq(certain, false, "no class certain")
    role = roles.role(nil, { is_player = true, class_id = CLASS.WARRIOR })
    assert_eq(role, nil, "nil unit")
end }

T[#T + 1] = { "a throwing native is a miss, not a crash", function()
    local roles = make_roles(bundle({ no_group_service = true }))
    local u = unit({})
    u.get_group_role = function() error("boom") end
    u.get_specialization_id = function() error("boom") end
    local role, certain = roles.role(u, { is_player = true, class_id = CLASS.MAGE })
    assert_eq(role, "dps", "mage still answered")
    assert_eq(certain, true, "mage certain")
end }

T[#T + 1] = { "no enums module: class ids fall back to WoW's own numbering", function()
    local P = bundle()
    P.enums = nil
    local roles = make_roles(P)
    local role, certain = roles.role(unit({ group_role = ROLE.DAMAGER }), { is_player = true, class_id = CLASS.MAGE })
    assert_eq(role, "dps", "group role"); assert_eq(certain, true, "certain")
    role, certain = roles.role(unit({}), { is_player = true, class_id = CLASS.MAGE })
    assert_eq(role, "dps", "mage named through the fallback"); assert_eq(certain, true, "mage certain")
    role = roles.role(unit({ auras = { 71 } }), { is_player = true, class_id = CLASS.WARRIOR })
    assert_eq(role, "tank", "warrior stance read through the fallback")
    assert_eq(roles.class_name(CLASS.DRUID), "DRUID", "class_name through the fallback")
    for name, id in pairs(cfg.CLASS_IDS) do
        assert_eq(roles.class_name(id), name, "fallback id " .. id)
    end
end }

T[#T + 1] = { "the enums win over the fallback when they answer", function()
    local P = bundle()
    P.enums.class_id = { WARRIOR = 42 }
    local roles = make_roles(P)
    assert_eq(roles.class_name(42), "WARRIOR", "renumbered warrior")
    assert_eq(roles.class_name(1), nil, "the fallback id is not also claimed")
    assert_eq(roles.class_name(CLASS.MAGE), "MAGE", "unlisted classes still fall back")
end }

T[#T + 1] = { "the spec rides along: from the tell, the role, or the client", function()
    local roles = make_roles(bundle())
    local function spec_of(u, class_id)
        local _, _, spec = roles.role(u, { is_player = true, class_id = class_id })
        return spec
    end
    assert_eq(spec_of(unit({ auras = { 71 } }), CLASS.WARRIOR), 73, "defensive stance: protection")
    assert_eq(spec_of(unit({ auras = { 2458 } }), CLASS.WARRIOR), 72, "berserker stance: fury")
    assert_eq(spec_of(unit({ auras = { 24858 } }), CLASS.DRUID), 102, "moonkin: balance")
    assert_eq(spec_of(unit({ auras = { 768 } }), CLASS.DRUID), 103, "cat: feral")
    assert_eq(spec_of(unit({}), CLASS.MAGE), 64, "mage default: frost")
    assert_eq(spec_of(unit({}), CLASS.PALADIN), 65, "paladin guess healer: holy")
    assert_eq(spec_of(unit({ group_role = ROLE.TANK }), CLASS.PALADIN), 66, "group tank paladin: protection")
    assert_eq(spec_of(unit({ spec = 250 }), CLASS.DEATHKNIGHT), 250, "the client's own spec id wins")
    assert_eq(spec_of(unit({}), CLASS.WARRIOR), 71, "warrior guess dps: arms")
end }

T[#T + 1] = { "config: the sheets cover every class and every spec the resolver can answer", function()
    for name in pairs(cfg.CLASS_RGB) do
        local c = cfg.CLASS_SHEET.cells[name]
        assert(c, "no crest cell for " .. name)
        assert(c[1] < c[2] and c[3] < c[4] and c[1] >= 0 and c[2] <= 1 and c[3] >= 0 and c[4] <= 1,
            "crest cell out of range for " .. name)
    end
    for name, by_role in pairs(cfg.ROLE_SPEC) do
        assert(cfg.CLASS_RGB[name], "ROLE_SPEC names unknown class " .. name)
        for role, spec in pairs(by_role) do
            assert(cfg.ROLE_RGB[role], name .. " ROLE_SPEC names unknown role " .. role)
            assert(cfg.SPEC_CELLS[spec], name .. " " .. role .. " spec " .. spec .. " has no sheet cell")
        end
    end
    for name, rows in pairs(cfg.ROLE_TELLS) do
        for i = 1, #rows do
            local spec = rows[i][3]
            assert(spec == nil or cfg.SPEC_CELLS[spec], name .. " tell " .. i .. " spec has no sheet cell")
        end
    end
    for spec, c in pairs(cfg.SPEC_CELLS) do
        assert(c[1] < c[2] and c[3] < c[4] and c[2] <= 1 and c[4] <= 1, "spec cell out of range " .. spec)
    end
    assert_eq(#cfg.SPEC_SHEETS, 2, "two spec sheet sources")
end }

T[#T + 1] = { "config: every creature type has an icon and a name", function()
    for id = 1, 15 do
        assert(type(cfg.CREATURE_ICON[id]) == "string" and cfg.CREATURE_ICON[id]:match("^[%w_]+$"),
            "creature icon " .. id)
        assert(type(cfg.CREATURE_TYPE_NAME[id]) == "string", "creature name " .. id)
    end
    for role in pairs(cfg.NPC_ROLE_RGB) do
        assert(cfg.NPC_ROLE_LETTER[role], "no badge letter for " .. role)
    end
    local el = cfg.ELEMENT_BY_KEY.show_creature_icon
    assert(el and el.kind == "unit" and el.lod == "mid", "show_creature_icon row")
end }

return T

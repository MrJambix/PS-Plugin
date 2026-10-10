-- Jambix AIO 1.72.0: which beasts a hunter can tame, and what they teach
-- (modules/tame.lua). The client's creature cache says tameable and the family
-- (JCore's ctx.creatures.beast, mocked here); the spell tables say every rank
-- and its level (modules/beasts_data.lua, the real generated file).
-- 1.7.6: Petopia's lists (modules/petopia_data.lua, the real generated file)
-- say which beast teaches what. The first four tests run without them (every
-- family skill a guess, as before); the rest with them.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local DATA = require("jambix_aio/modules/beasts_data")
local BEASTS = DATA.vanilla
local PETOPIA = require("jambix_aio/modules/petopia_data")

local function bundle(opts)
    opts = opts or {}
    local beasts = opts.forever and DATA.forever or BEASTS
    local W = { clock = 1000, class = opts.class or 3, level = opts.level or 30, handlers = {}, saved = {},
                beasts = opts.beasts or { [3566] = { tameable = true, family = 2, type = 1 },
                                          [4310] = { tameable = false, family = 0, type = 7 } },
                pet_ids = opts.pet_ids or {} }
    _G.core = { time = function() return W.clock end }
    local player = {
        get_class = function() return W.class end,
        get_level = function() return W.level end,
    }
    local store = {
        get = function(_, key, default) if W.saved[key] ~= nil then return W.saved[key] end return default end,
        set = function(_, key, value) W.saved[key] = value end,
    }
    local P = {
        ctx = {
            on = function(event, fn)
                W.handlers[event] = W.handlers[event] or {}
                table.insert(W.handlers[event], fn)
            end,
            store = function() return store end,
            creatures = { beast = function(npc) return W.beasts[npc] end },
        },
        units = { player = function() return player end },
        pet = {
            beasts = function() return beasts end,
            spell_id = function(name) return W.pet_ids[name] end,
        },
        forever = opts.forever == true,
    }
    -- Petopia's lists: none unless asked for; true is the real file for the
    -- client (tame.lua loads it itself), a table stands in for it.
    if opts.petopia == true then
        P.petopia = nil
    elseif type(opts.petopia) == "table" then
        P.petopia = opts.petopia
    else
        P.petopia = false
    end
    if opts.saved then W.saved.seen = opts.saved end
    for k in pairs(package.loaded) do
        if k == "jambix_aio/modules/tame" then package.loaded[k] = nil end
    end
    W.T = require("jambix_aio/modules/tame")(P)
    function W.fire(event, data)
        for _, fn in ipairs(W.handlers[event] or {}) do fn(data) end
    end
    return W
end

local function mark(npc, level, fields)
    local e = { kind = "unit", guid = "Creature-0-1-2-3-" .. npc .. "-0001", dead = false,
                info = { npc_id = npc, level = level, creature_type = 1, is_player = false } }
    for k, v in pairs(fields or {}) do e.info[k] = v end
    return e
end

local T = {}

T[#T + 1] = { "a tameable cat at your level: TAME, its family, and the ranks a level 30 cat carries", function()
    local W = bundle()
    local t = W.T.info(mark(3566, 30))
    assert(t, "tameable")
    assert_eq(t.can_now, true, "level 30 at your 30: tame it now")
    assert_eq(t.family_name, "Cat", "the family")
    local by = {}
    for _, s in ipairs(t.skills) do by[s.name] = s end
    assert_eq(by.Claw.rank, 4, "Claw 4: learned at 24, Claw 5 at 32")
    assert_eq(by.Prowl.rank, 1, "Prowl 1 at 30")
    assert_eq(by.Dash.rank, 1, "Dash 1 at 30")
    assert_eq(by.Claw.seen, false, "not seen yet: the client is never told which it has")
    assert(t.text:find("Claw 4? new", 1, true), "the line: " .. t.text)
    assert(t.text:find("^Cat: "), "starts with the family: " .. t.text)
end }

T[#T + 1] = { "seen using a skill: no '?', listed first, kept between sessions", function()
    local W = bundle()
    W.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", {
        0, "SPELL_CAST_SUCCESS", false, "Creature-0-1-2-3-3566-0002", "Flatland Prowler", 0, 0,
        "Player-1-2", "Me", 0, 0, 0, "Prowl", 1,
    })
    local t = W.T.info(mark(3566, 30))
    assert_eq(t.skills[1].name, "Prowl", "the seen one first")
    assert_eq(t.skills[1].seen, true, "seen")
    assert(t.text:find("Prowl 1 new", 1, true) and not t.text:find("Prowl 1?", 1, true), "no '?': " .. t.text)
    assert(W.saved.seen and W.saved.seen["3566"] and W.saved.seen["3566"].Prowl, "stored by npc id")

    -- Next session: read back.
    local W2 = bundle({ saved = W.saved.seen })
    local t2 = W2.T.info(mark(3566, 30))
    assert_eq(t2.skills[1].seen, true, "still seen after a reload")

    -- A skill the family cannot have, or a stranger's spell, is not kept.
    local W3 = bundle()
    W3.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", {
        0, "SPELL_CAST_SUCCESS", false, "Creature-0-1-2-3-3566-0002", "x", 0, 0, "y", "z", 0, 0, 0, "Fireball", 4,
    })
    assert_eq(W3.T.seen(3566), nil, "Fireball is nobody's pet skill")
end }

T[#T + 1] = { "new: only above the rank your pet has of it now", function()
    local claw3, claw4 = BEASTS.skills.Claw.ranks[3][1], BEASTS.skills.Claw.ranks[4][1]
    local W = bundle({ pet_ids = { Claw = claw3 } })
    assert(W.T.info(mark(3566, 30)).text:find("Claw 4? new", 1, true), "your pet has Claw 3: Claw 4 is new")
    local W2 = bundle({ pet_ids = { Claw = claw4 } })
    local t = W2.T.info(mark(3566, 30)).text
    assert(t:find("Claw 4?", 1, true) and not t:find("Claw 4? new", 1, true), "Claw 4 already: not new -- " .. t)
end }

T[#T + 1] = { "above your level: no TAME yet, the line says when; nothing for the untameable, players, pets, non-hunters", function()
    local W = bundle({ level = 20 })
    local t = W.T.info(mark(3566, 32))
    assert_eq(t.can_now, false, "level 32 at your 20")
    assert(t.text:find("Cat, tame at 32", 1, true), "says when: " .. t.text)

    assert_eq(W.T.info(mark(4310, 30, { creature_type = 1 })), nil, "the client says it cannot be tamed")
    assert_eq(W.T.info(mark(9999, 30)), nil, "the cache does not know it")
    assert_eq(W.T.info(mark(3566, 30, { is_player = true })), nil, "a player")
    assert_eq(W.T.info(mark(3566, 30, { pet = true })), nil, "someone's pet")
    assert_eq(W.T.info(mark(3566, 30, { creature_type = 7 })), nil, "not a beast")

    local M = bundle({ class = 8 })
    assert_eq(M.T.info(mark(3566, 30)), nil, "a mage sees nothing of it")
end }

-- --- 1.7.6: Petopia's lists ----------------------------------------------------------

local function by_name(t)
    local by = {}
    for _, s in ipairs(t.skills) do by[s.name] = s end
    return by
end

T[#T + 1] = { "the generated file: Forever's page has Dismember with no known teacher, both pages list Classic npcs only", function()
    local f, v = PETOPIA.forever, PETOPIA.vanilla
    assert(f and v, "both clients")
    local dis = f.skills.Dismember
    assert(dis and dis.wild, "Dismember is learned from beasts on Forever")
    for r = 1, 5 do assert_eq(dis.ranks[r].from, "unknown", "Dismember " .. r .. ": no known source") end
    assert_eq(dis.ranks[2].level, 24, "Dismember 2 at pet level 24, as in the client")
    assert_eq(v.skills.Dismember, nil, "not on the Era page")
    assert_eq(f.skills.Claw.ranks[4].from, "beast", "Claw 4: Petopia knows who teaches it")
    assert_eq(f.skills["Slower Attack"].ranks[1], nil, "Slower Attack starts at rank 2")
    assert_eq(f.npcs[2476].teaches.Bite, 3, "Large Loch Crocolisk teaches Bite 3")
    assert_eq(f.npcs[2476].family, "Crocolisk", "and is a crocolisk")
    for id in pairs(f.npcs) do assert(id < 100000, "a Classic npc: " .. id) end
    for id in pairs(v.npcs) do assert(id < 100000, "a Classic npc: " .. id) end
end }

T[#T + 1] = { "the game's own icons: Bite is the pet's bloody jaws, not Petopia's Ferocious Bite (2026-10-10)", function()
    -- The client's SpellMisc.SpellIconFileDataID, by beasts_extract.js. 132278 is
    -- Ability_Racial_Cannibalize, the pet's Bite on its bar; 132127 (Petopia's
    -- Ability_Druid_FerociousBite) is the druid's.
    assert_eq(DATA.forever.skills.Bite.icon, 132278, "Forever's Bite")
    assert_eq(DATA.vanilla.skills.Bite.icon, 132278, "Era's Bite")
    assert_eq(DATA.forever.skills["Demoralizing Screech"].icon, 132200, "Forever's Demoralizing Screech, not the bat's")
    assert_eq(DATA.forever.skills.Dismember.icon, 132187, "Dismember: the crocolisk")
    assert_eq(DATA.forever.skills.Claw.icon, 132140, "Claw: the rake")
    assert_eq(PETOPIA.forever.skills.Bite.icon, nil, "Petopia's file carries no icons")
end }

T[#T + 1] = { "the art pack has the game's icon of every skill a hunter's beast can teach, on both clients", function()
    local pack = require("jambix_aio/modules/esp/art_pack")
    local n = 0
    for client, d in pairs(DATA) do
        local own = { Cower = true }
        for _, fam in pairs(d.families) do
            if fam.hunter then for _, name in ipairs(fam.own) do own[name] = true end end
        end
        for name in pairs(own) do
            local skill = d.skills[name]
            if skill and not skill.trainer then
                n = n + 1
                assert(skill.icon, client .. ": " .. name .. " has no icon")
                assert(pack.cells["pet." .. skill.icon], client .. ": no cell pet." .. skill.icon .. " for " .. name)
            end
        end
    end
    assert(n >= 40, "both clients' beast skills: " .. n)
    assert(pack.cells["pet.458223"], "Trickster's Dance, cut from the Forever client (Era has no such file)")
    assert_eq(pack.cells["pet.132127"], nil, "not the druid's Ferocious Bite")
end }

T[#T + 1] = { "Forever, a listed crocolisk: Bite 3 for sure, Dismember a guess at its level's rank, each with its icon and spell", function()
    local W = bundle({ forever = true, petopia = true, level = 30,
                       beasts = { [2476] = { tameable = true, family = 6, type = 1 } } })
    local t = W.T.info(mark(2476, 22))
    assert(t, "tameable")
    assert_eq(t.family_name, "Crocolisk", "family")
    assert_eq(t.listed, true, "Petopia lists it")
    assert_eq(#t.skills, 2, "Bite and Dismember; Dash only from 30")
    local bite, dis = t.skills[1], t.skills[2]
    assert_eq(bite.name, "Bite", "the sure one first")
    assert_eq(bite.rank, 3, "Petopia's rank")
    assert_eq(bite.how, "petopia", "from the list")
    assert_eq(bite.sure, true, "sure")
    assert_eq(bite.icon, 132278, "the game's own Bite icon")
    assert_eq(bite.spell, DATA.forever.skills.Bite.ranks[3][1], "the rank's spell id")
    assert_eq(dis.name, "Dismember", "the family's Forever skill")
    assert_eq(dis.rank, 1, "a level 22 crocolisk: Dismember 1 (2 at 24)")
    assert_eq(dis.how, "guess", "nobody knows who teaches it")
    assert_eq(dis.sure, false, "not sure")
    assert_eq(dis.icon, 132187, "the game's own Dismember icon")
    assert_eq(dis.spell, DATA.forever.skills.Dismember.ranks[1][1], "Dismember 1's spell id")
    assert_eq(t.text, "Crocolisk: Bite 3 new, Dismember 1? new", "the line")
end }

T[#T + 1] = { "seen using a Forever skill: sure at its level's rank, after Petopia's", function()
    local W = bundle({ forever = true, petopia = true, level = 30,
                       beasts = { [2476] = { tameable = true, family = 6, type = 1 } } })
    W.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", {
        0, "SPELL_DAMAGE", false, "Creature-0-1-2-3-2476-0007", "Large Loch Crocolisk", 0, 0,
        "Player-1-2", "Me", 0, 0, 0, "Dismember", 1,
    })
    local by = by_name(W.T.info(mark(2476, 24)))
    assert_eq(by.Dismember.how, "seen", "seen")
    assert_eq(by.Dismember.sure, true, "sure now")
    assert_eq(by.Dismember.rank, 2, "level 24: Dismember 2")
    assert_eq(by.Bite.how, "petopia", "Bite still Petopia's")
end }

T[#T + 1] = { "a Classic beast Petopia does not list teaches nothing it knows the teachers of: no guesses", function()
    local W = bundle({ forever = true, petopia = true })
    local t = W.T.info(mark(3566, 30))
    assert(t, "still tameable")
    assert_eq(#t.skills, 0, "Bite 4, Claw 4, Dash 1 and Prowl 1 all have known teachers, and it is none")
    assert_eq(t.text, "Cat", "the line is the family alone")
end }

T[#T + 1] = { "a beast Petopia never covered (Forever's own, id past 100000): every family skill a guess", function()
    local W = bundle({ forever = true, petopia = true,
                       beasts = { [276500] = { tameable = true, family = 2, type = 1 } } })
    local by = by_name(W.T.info(mark(276500, 30)))
    for _, n in ipairs({ "Bite", "Claw", "Dash", "Prowl" }) do
        assert(by[n], n .. " guessed")
        assert_eq(by[n].how, "guess", n)
    end
    assert_eq(by.Claw.rank, 4, "Claw 4 at 30")
end }

T[#T + 1] = { "not in the creature cache yet: Petopia's word that it can be tamed, its family by name", function()
    local W = bundle({ forever = true, petopia = true, level = 40, beasts = {} })
    local t = W.T.info(mark(684, 37))
    assert(t, "Shadowmaw Panther is on Petopia's list")
    assert_eq(t.family_name, "Cat", "Petopia's family")
    assert_eq(t.family, 2, "the client's Cat")
    assert_eq(#t.skills, 1, "Prowl alone: Bite, Claw and Dash have known teachers")
    assert_eq(t.skills[1].name, "Prowl", "Prowl")
    assert_eq(t.skills[1].rank, 1, "Prowl 1")
    assert_eq(W.T.info(mark(9999, 30)), nil, "neither the cache nor Petopia knows it")
end }

T[#T + 1] = { "the client's word wins: listed by Petopia but the cache says it cannot be tamed", function()
    local W = bundle({ forever = true, petopia = true,
                       beasts = { [2476] = { tameable = false, family = 0, type = 1 } } })
    assert_eq(W.T.info(mark(2476, 22)), nil, "not tameable")
end }

T[#T + 1] = { "a stand-in file: a rank whose teachers are known is no guess for a Classic kind, one with none is", function()
    local fake = {
        skills = {
            Bite = { wild = true, ranks = { [1] = { level = 1, tp = 1, from = "beast" },
                                                        [2] = { level = 8, tp = 4, from = "unknown" } } },
        },
        npcs = {},
    }
    local W = bundle({ petopia = fake, beasts = { [3566] = { tameable = true, family = 2, type = 1 } } })
    assert_eq(by_name(W.T.info(mark(3566, 5))).Bite, nil, "Bite 1: known teachers, not this one")
    local W2 = bundle({ petopia = fake, beasts = { [3566] = { tameable = true, family = 2, type = 1 } } })
    local b = by_name(W2.T.info(mark(3566, 9))).Bite
    assert(b and b.how == "guess" and b.rank == 2, "Bite 2: no known teacher, so a guess")
    assert_eq(b.icon, BEASTS.skills.Bite.icon, "the game's icon, whatever Petopia's file says")
end }

T[#T + 1] = { "beast(): the Forever ESP's way in, by npc id and level; hunters only", function()
    local W = bundle({ forever = true, petopia = true, level = 30,
                       beasts = { [2476] = { tameable = true, family = 6, type = 1 } } })
    local t = W.T.beast(2476, 22, "Creature-0-1-2-3-2476-0001", 1000)
    assert(t and t.skills[1].name == "Bite", "the same answer as info()")
    assert_eq(W.T.beast(2476, 0, "g2", 1000), nil, "no level read yet")
    local M = bundle({ class = 8, forever = true, petopia = true,
                       beasts = { [2476] = { tameable = true, family = 6, type = 1 } } })
    assert_eq(M.T.beast(2476, 22, "g", 1000), nil, "a mage")
    assert(W.T.petopia() and W.T.petopia().Dismember, "the skills table, for the art")
end }

return T

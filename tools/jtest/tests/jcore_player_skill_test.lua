-- JCore 1.8.5 / services/player.lua: a profession's skill (player.skill) and
-- whether a corpse can be skinned at it (player.can_skin). Three sources, the
-- first that answers: the profession info (GetProfessions), the Skill window
-- (Era), and the highest rank in the spellbook, whose cap is then the skill.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A client answering `opts`, and the player service on it.
--- opts.professions: { [index] = info } for get_professions/get_profession_info
--- opts.lines: Skill window rows; opts.known: { [spell_id] = true }
local function player(opts)
    opts = opts or {}
    local W = { clock = 1000.0, reads = 0 }
    local slots = {}
    for index in pairs(opts.professions or {}) do slots["prof" .. index] = index end
    _G.core = {
        time = function() return W.clock end,
        spell_book = {
            get_professions = function()
                W.reads = W.reads + 1
                return slots
            end,
            get_profession_info = function(index) return (opts.professions or {})[index] end,
            is_spell_known = function(id) return (opts.known or {})[id] == true end,
        },
        skill = opts.lines and {
            get_num_skill_lines = function() return #opts.lines end,
            get_skill_line_info = function(i) return opts.lines[i] end,
        } or nil,
    }
    local rt = {
        util = require("jcore/lib/util"),
        log = { for_tag = function() return { fmt = function() end, debug = function() end } end },
        units = { player = function() return nil end },
        world = { client = function() return { forever = opts.forever == true } end },
        spells = { learned = function(id) return (opts.known or {})[id] == true end },
    }
    package.loaded["jcore/lib/cache"] = nil
    package.loaded["jcore/services/player"] = nil
    rt.cache = require("jcore/lib/cache")(rt)
    return require("jcore/services/player")(rt), W
end

local T = {}

T[#T + 1] = { "the game's rule: anyone to level 10, ten a level to 100 at 20, then five a level", function()
    local P = player()
    assert_eq(P.skin_required(1), 1, "level 1")
    assert_eq(P.skin_required(10), 1, "level 10")
    assert_eq(P.skin_required(11), 10, "level 11")
    assert_eq(P.skin_required(15), 50, "level 15")
    assert_eq(P.skin_required(20), 100, "level 20")
    assert_eq(P.skin_required(21), 105, "level 21")
    assert_eq(P.skin_required(60), 300, "level 60")
end }

T[#T + 1] = { "the profession info first, with gear's bonus; kept five seconds", function()
    local P, W = player({
        professions = { [3] = { name = "Leatherworking", skill_line = 165, skill_level = 120 },
            [5] = { name = "Skinning", skill_line = 393, skill_level = 87, skill_modifier = 10, max_skill_level = 150 } },
        lines = { { name = "Skinning", skill_rank = 1 } },
    })
    local level, how, max = P.skill("skinning")
    assert_eq(level, 97, "87 and Finkle's Skinner")
    assert_eq(how, "profession", "from the profession info")
    assert_eq(max, 150, "Journeyman's cap")
    P.skill("skinning")
    assert_eq(W.reads, 1, "read once")
    W.clock = W.clock + 6
    P.skill("skinning")
    assert_eq(W.reads, 2, "read again after five seconds: a skill goes up by using it")
end }

T[#T + 1] = { "Era: the Skill window's line, headers skipped, temporary points and gear counted", function()
    local P = player({ lines = {
        { name = "Professions", is_header = true },
        { name = "Herbalism", skill_rank = 40, skill_max_rank = 75 },
        { name = "Skinning", skill_rank = 112, num_temp_points = 0, skill_modifier = 5, skill_max_rank = 150 },
    } })
    local level, how, max = P.skill("skinning")
    assert_eq(level, 117, "112 and 5")
    assert_eq(how, "skill", "from the Skill window")
    assert_eq(max, 150, "its max")
    assert_eq((P.skill("herbalism")), 40, "another profession, by its own name")
end }

T[#T + 1] = { "Forever, no read answering: the highest rank known, its cap the skill", function()
    local P = player({ forever = true, known = { [8613] = true, [8617] = true } })
    local level, how = P.skill("skinning")
    assert_eq(level, 150, "Journeyman's cap")
    assert_eq(how, "rank", "an upper bound, said so")
    local ok, required, skill, said = P.can_skin(30)
    assert_eq(ok, true, "level 30 asks 150: within the rank")
    assert_eq(required, 150, "what it asks")
    assert_eq(skill, 150, "weighed against the cap")
    assert_eq(said, "rank", "and how")
    assert_eq((P.can_skin(31)), false, "level 31 asks 155: past Journeyman")
end }

T[#T + 1] = { "can_skin: at or under the skill yes, over it no; no Skinning at all no; no level never no", function()
    local P = player({ professions = { [5] = { name = "Skinning", skill_line = 393, skill_level = 60 } } })
    assert_eq((P.can_skin(16)), true, "level 16 asks 60")
    assert_eq((P.can_skin(17)), false, "level 17 asks 70")
    assert_eq((P.can_skin(nil)), true, "a level that did not read")
    assert_eq((P.can_skin(0)), true, "level 0")

    local none = player({ forever = true })
    local ok, required, skill = none.can_skin(5)
    assert_eq(ok, false, "no Skinning: nothing is yours to skin")
    assert_eq(required, 1, "even a level 5 asks for 1")
    assert_eq(skill, nil, "no skill")
    assert_eq((none.skill("skinning")), nil, "no profession")
    assert_eq((none.skill("tailoring")), nil, "an unknown key")
end }

return T

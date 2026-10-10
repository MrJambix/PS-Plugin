-- Jambix AIO 1.7.6, the WHOLE plugin on the whole of JCore as the Forever
-- client: the two experience bars (modules/xpbar.lua) are painted by the ESP
-- through JCore's draw queue with no window, read the experience the core
-- answers and the quest log the core lists, hide with the ESP's switch while
-- the rate keeps counting, put a JCore handle above each to move them, follow
-- their switches on the Forever ESP page, and learn a Forever quest's pay
-- from QUEST_TURNED_IN.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local PAGE = "Jambix AIO/Forever ESP"

--- A level-18 warrior, served the way a native usertype serves its methods.
local function player()
    local p = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0002",
        get_name = "Warrior", get_class = 1, get_race_id = 1, get_level = 18,
        get_health = 900, get_max_health = 1000, get_power = 0, get_max_power = 100,
        is_moving = false, is_mounted = false, is_in_combat = false, is_casting_spell = false,
        is_channelling_spell = false, get_rotation = 0, get_auras = {}, get_buffs = {}, get_debuffs = {},
        get_loss_of_control_info = { valid = false }, is_player = true, is_unit = true, get_type = 6,
    }
    local methods = {}
    for k, v in pairs(p) do methods[k] = function() return v end end
    methods.get_position = function() return { x = 100, y = 100, z = 0 } end
    local none = function() return nil end
    return setmetatable({}, { __index = function(_, k) return methods[k] or none end })
end

-- The log: The Defias Brotherhood (65, the table's 1350) ready to hand in,
-- and one of Forever's own (91733, not in the table) to do.
local LOG = {
    { quest_id = 0, title = "Westfall", is_header = true, level = 0 },
    { quest_id = 65, title = "The Defias Brotherhood", level = 18, is_header = false },
    { quest_id = 91733, title = "A Forever Quest", level = 18, is_header = false },
}

local XP = { xp = 18500, max = 19400 }
local texts = {}

local function painted(pattern)
    for i = 1, #texts do
        if tostring(texts[i]):find(pattern) then return texts[i] end
    end
    return nil
end

local T = {}
local b, me

T[#T + 1] = { "Forever: the plugin boots clean with the experience bars", function()
    me = player()
    b = boot.run("Forever", "wow_forever_us", { "_classic_era_" }, function(mock)
        core.object_manager.get_local_player = function() return me end
        core.object_manager.get_visible_objects = function() return { me } end
        core.character.get_xp = function() return XP.xp end
        core.character.get_xp_max = function() return XP.max end
        core.character.get_rested_xp = function() return nil end
        core.quests.get_quest_log_quest_ids = function() return { 65, 91733 } end
        core.quests.get_num_quest_log_entries = function() return #LOG end
        core.quests.get_quest_log_title = function(i) return LOG[i] or {} end
        core.quests.is_quest_complete = function(id) return id == 65 end
        core.quests.get_quest_objectives = function() return {} end
        core.quests.is_on_quest = function(id) return id == 65 or id == 91733 end
        local text_2d = core.graphics.text_2d
        core.graphics.text_2d = function(s, ...)
            texts[#texts + 1] = s
            return text_2d(s, ...)
        end
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert(b.P.xpbar, "built on Forever")
    -- The ESP's toggle key, active as it starts in game (default_active).
    b.mock.menu:set(PAGE, "toggle_key", { vk = 0x5A, active = true, toggled = true })
    b.P.opt_invalidate()
end }

local function xp_windows()
    local n, ids = 0, {}
    for _, w in ipairs(b.JCore.ui.windows()) do
        if tostring(w.id):find("xp_bar", 1, true) and w.live then
            n = n + 1
            ids[#ids + 1] = w.id
        end
    end
    return n, ids
end

T[#T + 1] = { "Forever: both bars painted by the ESP, no window, with the log's quests and what they give", function()
    texts = {}
    b.mock.frame(90)
    assert_eq(b.errors(), "", "core.log_error while running")
    local st = b.P.xpbar.stats()
    assert_eq(st.xp, 18500, "the core's get_xp")
    assert_eq(st.level, 18, "the player's level")
    assert_eq(st.shown.ready, true, "the turn-ins bar is drawn")
    assert_eq(st.shown.log, true, "the quest log bar is drawn")
    assert_eq(xp_windows(), 0, "no JCore window")
    for _, want in ipairs({ "^TURN%-INS$", "^QUEST LOG$", "^18,500 / 19,400   95%.4%%$",
        "^%+1,350 XP$", "^%-> Level 19 %(2%%%)$", "^%+~2,700 XP$", "^%-> Level 19 %(8%%%)$",
        "^1 finished quest to hand in$" }) do
        assert(painted(want), "painted: " .. want)
    end
end }

T[#T + 1] = { "Forever: the bars hide with the ESP's switch and its toggle key; the rate keeps counting", function()
    b.mock.menu:set(PAGE, "enabled", false)
    b.P.opt_invalidate()
    texts = {}
    XP.xp = 18600
    b.mock.frame(60)
    assert_eq(b.P.xpbar.stats().shown.ready, false, "hidden with the ESP")
    assert(not painted("^TURN%-INS$"), "nothing painted")
    assert_eq(b.P.xpbar.stats().gained, 100, "the experience still read")
    b.mock.menu:set(PAGE, "enabled", true)
    b.P.opt_invalidate()
    b.mock.frame(5)
    assert_eq(b.P.xpbar.stats().shown.ready, true, "back with it")
    b.mock.menu:set(PAGE, "toggle_key", { vk = 0x5A, active = false, toggled = false })
    b.P.opt_invalidate()
    b.mock.frame(5)
    assert_eq(b.P.xpbar.stats().shown.ready, false, "hidden with the toggle key")
    b.mock.menu:set(PAGE, "toggle_key", { vk = 0x5A, active = true, toggled = true })
    b.P.opt_invalidate()
    b.mock.frame(5)
    assert_eq(b.P.xpbar.stats().shown.ready, true, "and back")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "Forever: Move the XP bars puts a JCore handle above each, gone when it is off", function()
    b.mock.menu:set(PAGE, "xpbar_move", true)
    b.P.opt_invalidate()
    b.mock.frame(5)
    local n, ids = xp_windows()
    assert_eq(n, 2, "two handles: " .. table.concat(ids, ", "))
    b.mock.menu:set(PAGE, "xpbar_move", false)
    b.P.opt_invalidate()
    b.mock.frame(5)
    assert_eq(xp_windows(), 0, "gone")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "Forever: each bar has its own switch on the Forever ESP page", function()
    b.mock.menu:set(PAGE, "xpbar_log", false)
    b.P.opt_invalidate()
    texts = {}
    b.mock.frame(5)
    local st = b.P.xpbar.stats()
    assert_eq(st.shown.ready, true, "the turn-ins bar stays")
    assert_eq(st.shown.log, false, "the log's is off")
    assert(not painted("^QUEST LOG$"), "and not painted")
    b.mock.menu:set(PAGE, "xpbar_ready", false)
    b.P.opt_invalidate()
    texts = {}
    b.mock.frame(5)
    assert_eq(b.P.xpbar.stats().shown.ready, false, "both off")
    assert(not painted("^TURN%-INS$"), "nothing painted")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "Forever: a Forever quest handed in teaches its pay; the experience is the session's", function()
    b.mock.game_event("QUEST_TURNED_IN", { 91733, 1400, 0 })
    XP.xp = 18600 + 1400
    b.mock.frame(60)
    local xp, how = b.P.xpbar.reward(91733, 18, 18)
    assert_eq(how, "learned", "learned from the event")
    assert_eq(xp, 1400, "its pay")
    assert_eq(b.P.xpbar.stats().gained, 1500, "the rise is counted")
    assert_eq(b.errors(), "", "core.log_error")
end }

return T

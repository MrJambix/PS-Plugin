-- Jambix AIO 1.65.1 on JCore 1.8: telegraphs, end to end.
--
-- The whole plugin on the whole JCore (mock/aio_boot) as the Era client, with
-- the real telegraph data (scripts_data/jcore/telegraphs/vanilla) laid into
-- the mock's scripts_data. Onyxia stands fifteen yards in front of the player,
-- facing them, casting Flame Breath (a 45-yard, 120-degree cone): its danger
-- ground is painted on the danger layer, see-through (the user, 1.65.1: "it
-- shouldnt be Full one color cant see other mobs or myself in it"), its label
-- says so, and the alert at the top of the screen says the player is standing
-- in it. Then the switches: off, the overlay's toggle key, boss-mod-only,
-- range, no fill, and raids and dungeons only, before and after the player
-- walks into a raid. The player started from 1.65.0's 25% fill, which the
-- one-off migration moves to 15%.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local PX, PY, PZ = 100, 100, 0

--- A game object answering from `spec`; a function value is called with the
--- object and the arguments.
local function object(spec)
    local o = { spec = spec }
    return setmetatable(o, {
        __index = function(_, key)
            return function(self, ...)
                local v = spec[key]
                if type(v) == "function" then return v(self, ...) end
                return v
            end
        end,
    })
end

local function at(x, y, z) return { x = x, y = y, z = z or PZ } end

local me = object({
    is_valid = true, is_unit = true, is_player = true, is_dead = false, is_ghost = false,
    get_guid = "Player-1-0001", get_name = "Me", get_class = 3, get_race_id = 1, get_level = 60,
    get_health = 900, get_max_health = 1000, get_power = 800, get_max_power = 1000,
    get_position = at(PX, PY), get_rotation = 0, is_moving = false, is_mounted = false,
    is_in_combat = true, get_auras = {}, get_buffs = {}, get_debuffs = {},
    get_loss_of_control_info = { valid = false },
})
me.spec.can_attack = function(_, other) return other and other.spec and other.spec.hostile or false end
me.spec.is_enemy_with = function(_, other) return other and other.spec and other.spec.hostile or false end
me.spec.is_friend_with = function() return false end

local cast_start, cast_end = 0, 0
local ony = object({
    is_valid = true, is_unit = true, is_player = false, is_dead = false, hostile = true,
    get_guid = "Creature-0-0-0-0-10184-1", get_name = "Onyxia", get_level = 63, get_npc_id = 10184,
    get_creature_type = 2, get_classification = 3,
    get_health = 80000, get_max_health = 100000, get_power = 0, get_max_power = 0,
    is_in_combat = true, get_bounding_radius = 3, get_height = 8, get_combat_reach = 7,
    get_position = at(PX + 15, PY),
    -- Facing the player: along -x.
    get_rotation = math.pi,
    is_casting_spell = true, is_channelling_spell = false,
    get_active_spell_id = 18435,
    get_active_spell_cast_start_time = function() return cast_start end,
    get_active_spell_cast_end_time = function() return cast_end end,
    is_active_spell_interruptable = false,
    get_loss_of_control_info = { valid = false },
    get_auras = {}, get_buffs = {}, get_debuffs = {},
})
ony.spec.can_attack = function() return true end
ony.spec.get_target = function() return me end

-- 1.69.1: a group member twenty yards ahead, and a Dark Iron Engineer beside
-- them throwing dynamite at them (7978: a 5-yard circle on its target).
local buddy = object({
    is_valid = true, is_unit = true, is_player = true, is_dead = false, is_ghost = false, hostile = false,
    get_guid = "Player-1-0002", get_name = "Alfred", get_class = 1, get_race_id = 1, get_level = 14,
    get_health = 300, get_max_health = 300, get_power = 0, get_max_power = 100,
    get_position = at(PX + 20, PY), get_rotation = math.pi, is_moving = false, is_mounted = false,
    is_in_combat = true, get_auras = {}, get_buffs = {}, get_debuffs = {},
    get_loss_of_control_info = { valid = false },
})
buddy.spec.can_attack = function() return false end
buddy.spec.is_friend_with = function() return true end

local engineer = object({
    is_valid = true, is_unit = true, is_player = false, is_dead = false, hostile = true,
    get_guid = "Creature-0-0-0-0-8913-1", get_name = "Dark Iron Engineer", get_level = 14, get_npc_id = 8913,
    get_creature_type = 7, get_classification = 1,
    get_health = 434, get_max_health = 1035, get_power = 300, get_max_power = 300,
    is_in_combat = true, get_bounding_radius = 0.4, get_height = 1.5, get_combat_reach = 1.5,
    get_position = at(PX + 21, PY + 2), get_rotation = math.pi,
    is_casting_spell = true, is_channelling_spell = false,
    get_active_spell_id = 7978,
    get_active_spell_cast_start_time = function() return cast_start end,
    get_active_spell_cast_end_time = function() return cast_end end,
    is_active_spell_interruptable = true,
    get_loss_of_control_info = { valid = false },
    get_auras = {}, get_buffs = {}, get_debuffs = {},
})
engineer.spec.can_attack = function() return true end
engineer.spec.get_target = function() return buddy end
engineer.spec.get_active_spell_target = function() return buddy end

local visible = { ony }

--- A camera at the player looking along +x.
local function w2s(pos)
    if type(pos) ~= "table" or not pos.x then return nil end
    local depth = pos.x - PX
    if depth < 2 then return nil end
    local sx = 960 + (pos.y - PY) * 600 / depth
    local sy = 540 - ((pos.z or 0) - PZ - 1) * 600 / depth
    if sx < 0 or sx > 1920 or sy < 0 or sy > 1080 then return nil end
    return { x = sx, y = sy }
end

-- What was submitted on the danger layer, and the text that reached the client.
-- `rings` keeps each unfilled circle's radius and fade (1.69.1).
local painted = { fills = 0, max_fill_alpha = 0, edges = 0, texts = {}, rings = {} }
local function reset() painted.fills, painted.max_fill_alpha, painted.edges, painted.texts, painted.rings = 0, 0, 0, {}, {} end
local function alpha_of(c) return type(c) == "table" and tonumber(c.a) or 255 end
local function filled_with(c)
    painted.fills = painted.fills + 1
    if alpha_of(c) > painted.max_fill_alpha then painted.max_fill_alpha = alpha_of(c) end
end
local function said(text)
    for i = 1, #painted.texts do
        if tostring(painted.texts[i]):find(text, 1, true) then return true end
    end
    return false
end

local DATA = "scripts_data/jcore/telegraphs/vanilla"
local instance = "none"
local map_id = 1

local b
local function set(id, value)
    b.mock.menu:set("Jambix AIO/ESP", id, value)
    b.P.opt_invalidate()
end

local T = {}

T[#T + 1] = { "boot as Era with the telegraph data, from a 1.65.0 player's 25% fill", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" }, function(mock)
        for _, rel in ipairs({ "index.json", "spells/18.json", "spells/7.json" }) do
            local bytes = jtest.read_file(DATA .. "/" .. rel)
            assert(bytes, "the extracted data is missing: run tools/jcheck/telegraph_extract.js (" .. rel .. ")")
            mock.data_fs["jcore/telegraphs/vanilla/" .. rel] = bytes
        end
        -- What 1.65.0 saved as the player's value.
        mock.menu:set("Jambix AIO/ESP", "tele_fill", 25)
        rawset(mock.core, "get_instance_type", function() return instance end)
        rawset(mock.core, "get_map_id", function() return map_id end)
        rawset(mock.core.object_manager, "get_local_player", function() return me end)
        rawset(mock.core.object_manager, "get_visible_objects", function() return visible end)
        rawset(mock.core.graphics, "w2s", w2s)
        local g = mock.core.graphics
        local text3, text2 = rawget(g, "text_3d"), rawget(g, "text_2d")
        rawset(g, "text_3d", function(text, ...) painted.texts[#painted.texts + 1] = text return text3(text, ...) end)
        rawset(g, "text_2d", function(text, ...) painted.texts[#painted.texts + 1] = text return text2(text, ...) end)
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    -- Only telegraphs paint on JCore's danger layer: count what is submitted there.
    local draw = b.ctx.draw
    local DANGER = draw.LAYER.DANGER
    local circle, polygon, path = draw.circle_3d, draw.polygon_3d, draw.path_3d
    draw.circle_3d = function(center, r, c, opts)
        if opts and opts.layer == DANGER then
            if opts.filled then
                filled_with(c)
            else
                painted.edges = painted.edges + 1
                painted.rings[#painted.rings + 1] = { r = r, fade = opts.fade }
            end
        end
        return circle(center, r, c, opts)
    end
    draw.polygon_3d = function(points, c, opts)
        if opts and opts.layer == DANGER and opts.filled then filled_with(c) end
        return polygon(points, c, opts)
    end
    draw.path_3d = function(points, c, opts)
        if opts and opts.layer == DANGER then painted.edges = painted.edges + 1 end
        return path(points, c, opts)
    end
    assert(b.ctx.telegraphs, "ctx.telegraphs: JCore hands the service to plugins")
    assert(b.P.telegraphs, "P.telegraphs")
    cast_start = b.mock.core.game_time()
    cast_end = cast_start + 600000
    set("toggle_key", { vk = 0x5A, active = true, toggled = true })
    b.mock.frame(90)                      -- past the migration's first second
    assert_eq(b.errors(), "", "core.log_error while running")
    assert_eq(b.mock.menu:get("Jambix AIO/ESP", "tele_fill"), 15, "1.65.0's 25% moved to 15%")
end }

T[#T + 1] = { "Flame Breath: see-through danger ground with an edge, named, and the alert says I am in it", function()
    reset()
    b.mock.frame(5)
    local list = b.ctx.telegraphs.active()
    assert(#list >= 1, "the service has it")
    local t = list[1]
    assert_eq(t.spell_id, 18435, "Flame Breath")
    assert_eq(t.shape, "cone", "a cone")
    assert_eq(t.inside, true, "she is facing me: in it")
    assert_eq(painted.fills, 5, "one fill a frame: no second fill growing over it")
    assert(painted.max_fill_alpha <= 128, "the fill is see-through: alpha " .. painted.max_fill_alpha)
    assert(painted.max_fill_alpha > 0, "and there is one")
    assert(painted.edges > 0, "the edge and the sweep are lines")
    assert(said("Flame Breath"), "its name on the ground")
    assert(said("Standing in Flame Breath"), "and the alert at the top of the screen")
    assert(b.P.telegraphs.summary():find("1 live", 1, true), "summary: " .. b.P.telegraphs.summary())
    assert_eq(b.P.telegraphs.boss_mechanic(t), true, "Onyxia's breath is a boss mechanic: the heavier edge")
end }

T[#T + 1] = { "the fill slider: 0 leaves the edge, and it never goes past half", function()
    set("tele_fill", 0)
    reset()
    b.mock.frame(3)
    assert_eq(painted.fills, 0, "no fill")
    assert(painted.edges > 0, "the edge is still there")
    set("tele_fill", 100)                 -- a saved value past the slider's new top
    reset()
    b.mock.frame(3)
    assert(painted.max_fill_alpha <= 128, "capped at half: alpha " .. painted.max_fill_alpha)
    set("tele_fill", 15)
end }

T[#T + 1] = { "the switches: off, the overlay's toggle, boss-mod-only, range", function()
    set("tele_on", false)
    reset()
    b.mock.frame(3)
    assert_eq(painted.edges + painted.fills, 0, "Show telegraphs off: nothing")
    set("tele_on", true)

    set("toggle_key", { vk = 0x5A, active = false, toggled = false })
    reset()
    b.mock.frame(3)
    assert_eq(painted.edges + painted.fills, 0, "the overlay toggled off: nothing")
    set("toggle_key", { vk = 0x5A, active = true, toggled = true })

    set("tele_who", 3)
    reset()
    b.mock.frame(3)
    assert(painted.edges > 0, "boss-mod spells only: Flame Breath is one (Onyxia's mod)")
    set("tele_who", 1)

    set("tele_range", 20)
    ony.spec.get_position = at(PX + 80, PY)
    reset()
    b.mock.frame(3)
    assert_eq(painted.edges + painted.fills, 0, "80 yards away, past a 20-yard range plus its 45: nothing")
    ony.spec.get_position = at(PX + 15, PY)
    set("tele_range", 60)
    reset()
    b.mock.frame(3)
    assert(painted.edges > 0, "back in range")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "raids and dungeons only: nothing in the open world, all of it in a raid", function()
    set("tele_where", 2)
    reset()
    b.mock.frame(3)
    assert_eq(painted.edges + painted.fills, 0, "the open world: nothing")
    instance, map_id = "raid", 249        -- Onyxia's Lair
    b.mock.frame(3)
    reset()
    b.mock.frame(3)
    assert(painted.edges > 0, "in the raid: painted")
    instance, map_id = "none", 1
    b.mock.frame(3)
    set("tele_where", 1)
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "she turns away: still painted, no longer on me", function()
    ony.spec.get_rotation = 0          -- facing +x, away from the player
    reset()
    b.mock.frame(3)
    local t = b.ctx.telegraphs.active()[1]
    assert_eq(t.inside, false, "behind her: out")
    assert(not said("Standing in"), "no alert")
    ony.spec.get_rotation = math.pi
end }

T[#T + 1] = { "the cast ends: gone", function()
    ony.spec.is_casting_spell = false
    b.mock.frame(5)
    assert_eq(#b.ctx.telegraphs.active(), 0, "nothing live")
    reset()
    b.mock.frame(2)
    assert_eq(painted.edges + painted.fills, 0, "nothing painted")
    assert_eq(b.errors(), "", "core.log_error")
end }

-- 1.69.1, the user: "u cant see shit with it". A 5-yard Throw Dynamite came
-- out solid gold: the native ring glows inward by alpha * (d / r) ^ fade, and
-- JCore's fade of 1.0 spread the rim's glow over the whole disc. Every ring
-- bigger than a yard must have its glow down to a quarter 0.75 yd in.
T[#T + 1] = { "Throw Dynamite on a group member: the rim's glow stays at the rim", function()
    visible = { ony, buddy, engineer }
    cast_start = b.mock.core.game_time()
    cast_end = cast_start + 600000
    reset()
    b.mock.frame(5)
    local t
    local list = b.ctx.telegraphs.active()
    for i = 1, #list do
        if list[i].spell_id == 7978 then t = list[i] end
    end
    assert(t, "the service has Throw Dynamite (" .. #list .. " live)")
    assert_eq(t.shape, "circle", "a circle")
    assert_eq(t.placed, true, "on the group member")
    assert_eq(t.inside, false, "twenty yards off: not on me")
    assert(painted.fills > 0, "the faint fill")
    assert(painted.max_fill_alpha <= 128, "see-through: alpha " .. painted.max_fill_alpha)
    local rims = 0
    for i = 1, #painted.rings do
        local ring = painted.rings[i]
        if ring.r > 1 then
            local fade = ring.fade or 1.0          -- what JCore passes for none
            local left = (1 - 0.75 / ring.r) ^ fade
            assert(left <= 0.25, string.format("a %.1f yd ring glows %.0f%% 0.75 yd in (fade %s)",
                ring.r, left * 100, tostring(ring.fade)))
            if math.abs(ring.r - 5) < 0.01 then rims = rims + 1 end
        end
    end
    assert(rims > 0, "the 5 yd rim was drawn")
    assert(said("Throw Dynamite"), "its name on the ground")
    assert_eq(b.errors(), "", "core.log_error")
end }

return T

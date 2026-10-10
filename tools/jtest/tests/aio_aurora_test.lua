-- Jambix AIO 1.86.0: the aurora around you (modules/aurora.lua).
--
-- Lemons' Aurora Systems curtain, drawn with JCore 1.11's curtain_3d and
-- made to read the fight: calm out of combat and rising in one, warmer as
-- health drops and breathing under a quarter, a fold per enemy on you, your
-- own cast as a ring at your feet. Drawn through a recording draw service.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local clock = { s = 1000.0 }
_G.core = { time = function() return clock.s end, game_time = function() return math.floor(clock.s * 1000) end }

local cfg = require("jambix_aio/modules/config")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end
local function near(got, want, label, eps)
    if type(got) ~= "number" or math.abs(got - want) > (eps or 1e-6) then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local ME = { x = 1, y = 2, z = 3 }

local function bundle(opts)
    opts = opts or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local state = {
        combat = false, hp = 1, class = 8, spell = nil, left = 0, channel = false, enemies = {},
    }
    local settings = opts.settings or {}
    -- 1.7.6: curtains are off by default. These tests are about them, so
    -- each starts on unless a test sets it; `curtains_default` keeps the
    -- shipped defaults.
    if not opts.curtains_default then
        for _, id in ipairs({ "aurora_on" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local P = {
        cfg = cfg,
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = {
            LAYER = { WORLD = 100 },
            player = {
                position = function() return ME end,
                in_combat = function() return state.combat end,
                health_pct = function() return state.hp end,
                class_id = function() return state.class end,
                casting_spell_id = function() return state.spell end,
                cast_remaining = function() return state.left end,
                is_channelling = function() return state.channel end,
            },
            enemies = { all = function() return state.enemies end },
        },
        draw = opts.old_jcore and { ring_3d = rec("ring_3d") } or {
            ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"),
        },
    }
    package.loaded["jambix_aio/modules/aurora"] = nil
    local M = require("jambix_aio/modules/aurora")(P)
    local function frame(dt)
        clock.s = clock.s + (dt or 1 / 60)
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
    end
    return M, calls, state, frame, settings
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end
local function first(calls, name) return all(calls, name)[1] end

local MAGE = cfg.CLASS_RGB.MAGE

local T = {}

T[#T + 1] = { "calm out of combat: a low curtain in your class colour rising into violet, and no ring (1.88.0)", function()
    local M, calls, _, frame = bundle()
    frame()
    local c = first(calls, "curtain_3d")
    assert(c, "a curtain")
    assert_eq(c[1], ME, "around you"); near(c[2], 2.0, "radius")
    assert_eq(c[3].r, MAGE[1], "a mage's colour at the base"); assert_eq(c[3].b, MAGE[3], "a mage's colour")
    assert_eq(c[4].to.r, 147, "violet at the top")
    near(c[4].height, 1.2 * 0.55, "low while calm")
    assert_eq(c[4].folds, 3, "three folds")
    assert_eq(c[4].points, 36, "36 points"); assert_eq(c[4].rings, 4, "4 rings")
    assert_eq(c[4].layer, 100, "world layer")
    assert_eq(#all(calls, "ring_3d"), 0, "no glow ring under it")
    assert_eq(M.stats().lines, 4 * 36 + 12 * 3, "180 lines")
end }

T[#T + 1] = { "a fight: it rises and quickens over about half a second, and each enemy on you adds a fold (three at most)", function()
    local M, calls, st, frame = bundle()
    frame()
    local calm = first(calls, "curtain_3d")[4]
    near(M.stats().rate, 0.5, "calm: half speed")
    st.combat = true
    st.enemies = { { targeting_me = true }, { targeting_me = true }, { targeting_me = false } }
    frame(0.1)
    local early = first(calls, "curtain_3d")[4]
    assert(early.height > calm.height and early.height < 1.2, "on its way up")
    for _ = 1, 20 do frame(0.1) end
    local fight = first(calls, "curtain_3d")[4]
    near(fight.height, 1.2, "full height in a fight")
    assert(M.stats().rate > 0.5 + 1e-9, "quicker: rate " .. tostring(M.stats().rate))
    assert(fight.time > calm.time, "its own clock moves on")
    assert_eq(fight.folds, 5, "two on you: two more folds")
    st.enemies = {}
    for i = 1, 6 do st.enemies[i] = { targeting_me = true } end
    frame(0.3)
    assert_eq(first(calls, "curtain_3d")[4].folds, 6, "never more than three extra")
end }

T[#T + 1] = { "health: amber under half, red under a quarter, and breathing faster the lower it goes", function()
    local M, calls, st, frame = bundle()
    st.hp = 0.3
    frame()
    local warm = first(calls, "curtain_3d")[3]
    assert(warm.g < MAGE[2] and warm.r > MAGE[1], "warming toward amber")
    st.hp = 0.1
    local heights, reds = {}, 0
    for i = 1, 12 do
        frame(0.05)
        local c = first(calls, "curtain_3d")
        heights[i] = c[4].height
        if c[3].r > 200 and c[3].g < 120 then reds = reds + 1 end
    end
    assert_eq(reds, 12, "red under a quarter")
    local lo, hi = math.huge, 0
    for i = 1, #heights do lo, hi = math.min(lo, heights[i]), math.max(hi, heights[i]) end
    assert(hi - lo > 0.05, "breathing: the height moves, " .. lo .. " to " .. hi)
    st.hp = 0.9
    frame()
    local well = first(calls, "curtain_3d")[3]
    assert_eq(well.r, MAGE[1], "back to the class colour when healthy")
end }

T[#T + 1] = { "casting draws no ring at your feet (1.88.0)", function()
    local M, calls, st, frame = bundle()
    st.spell, st.left = 133, 2.0
    frame()
    st.left = 1.0
    frame()
    assert_eq(#all(calls, "ring_3d"), 0, "no cast ring")
    assert_eq(#all(calls, "curtain_3d"), 1, "the curtain only")
end }

T[#T + 1] = { "colours and switches", function()
    local M, calls, st, frame, settings = bundle()
    settings.aurora_style = 3
    frame()
    assert_eq(#all(calls, "curtain_3d"), 1, "a style saved before 1.88.0 changes nothing: the curtain")
    assert_eq(#all(calls, "ring_3d"), 0, "and no ring")
    settings.aurora_style = nil
    settings.aurora_colors = 2
    frame()
    local c = first(calls, "curtain_3d")
    assert_eq(c[4].to.r, MAGE[1], "class colour top and bottom")
    settings.aurora_colors = 4
    frame()
    local a = first(calls, "curtain_3d")[3]
    frame(3)
    local b = first(calls, "curtain_3d")[3]
    assert(a.r ~= b.r or a.g ~= b.g or a.b ~= b.b, "rainbow: the colour moves")
    settings.aurora_colors = nil
    settings.aurora_radius, settings.aurora_height, settings.aurora_detail = 3.5, 2.0, 20
    frame()
    c = first(calls, "curtain_3d")
    near(c[2], 3.5, "size"); assert_eq(c[4].points, 20, "detail")
    settings.aurora_on = false
    frame()
    assert_eq(#calls, 0, "switched off")
end }

T[#T + 1] = { "only in a fight: nothing out of one, and it fades out with the fight rather than vanishing", function()
    local M, calls, st, frame, settings = bundle({ settings = { aurora_combat_only = true } })
    frame()
    assert_eq(#calls, 0, "nothing while calm")
    st.combat = true
    for _ = 1, 20 do frame(0.1) end
    local full = first(calls, "curtain_3d")[3].a
    st.combat = false
    frame(0.1)
    local fading = first(calls, "curtain_3d")
    assert(fading and fading[3].a < full, "fading out")
    for _ = 1, 40 do frame(0.1) end
    assert_eq(#calls, 0, "gone")
end }

T[#T + 1] = { "the wave's clock is its own: a changing rate never makes it jump", function()
    local M, calls, st, frame = bundle()
    frame(0.1)
    local prev = first(calls, "curtain_3d")[4].time
    st.combat = true
    for _ = 1, 30 do
        frame(1 / 60)
        local now = first(calls, "curtain_3d")[4].time
        local step = now - prev
        assert(step >= 0 and step <= (1 / 60) * 1.8 + 1e-9, "one frame moves it at most its rate: " .. step)
        prev = now
    end
end }

T[#T + 1] = { "the sheet (1.87.0): a glowing fill, stronger in a fight, and its switch", function()
    local M, calls, st, frame, settings = bundle()
    frame()
    near(first(calls, "curtain_3d")[4].fill, 0.22, "calm: a faint sheet")
    st.combat = true
    for _ = 1, 20 do frame(0.1) end
    near(first(calls, "curtain_3d")[4].fill, 0.40, "a fight: stronger")
    settings.aurora_fill = false
    frame()
    assert_eq(first(calls, "curtain_3d")[4].fill, nil, "switched off")
end }

T[#T + 1] = { "an older JCore without curtain_3d: nothing, and no error", function()
    local M, calls, _, frame = bundle({ old_jcore = true })
    frame()
    assert_eq(#calls, 0, "nothing drawn")
end }

T[#T + 1] = { "1.7.6: off by default, a curtain like the others; on by its switch", function()
    local _, calls, _, frame = bundle({ curtains_default = true })
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "nothing by default")
    local _, calls2, _, frame2 = bundle({ curtains_default = true, settings = { aurora_on = true } })
    frame2()
    assert_eq(#all(calls2, "curtain_3d"), 1, "switched on: the aurora")
end }

return T

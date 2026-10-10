-- Jambix AIO: the spell window (modules/timeline.lua) and the rotation's
-- forecast it shows (rotation.lua, M.forecast / M.forecast_tick).
--
-- Three things are pinned here:
--   * the forecast plays the priority list forward the way the walk would:
--     priority order, cooldowns, the lane after a GCD or a cast, toggles and
--     presses in flight left out;
--   * the history records each cast once, says who pressed it, and leaves
--     out auto attacks and procs;
--   * the paint never puts an opaque shape over an icon. The loader draws
--     textures beneath every shape (README, "Textures paint beneath every 2D
--     shape"), so a backdrop under an icon would hide it in the game.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local make_rotation = require("jambix_aio/modules/rotation")
local make_timeline = require("jambix_aio/modules/timeline")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function assert_near(got, want, label)
    if type(got) ~= "number" or math.abs(got - want) > 1e-6 then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local IDS = {
    ["Hunter's Mark"] = 14325, ["Auto Shot"] = 75, ["Serpent Sting"] = 13555,
    ["Arcane Shot"] = 14287, ["Raptor Strike"] = 14266, ["Shadow Bolt"] = 686,
}
local NAMES = {}
for name, id in pairs(IDS) do NAMES[id] = name end
NAMES[20007] = "Holy Strength"   -- a weapon proc: reports a cast, not in the spellbook

local ROWS = {
    ["hunter's mark"] = { name = "Hunter's Mark", range = 100, cooldown = 0, cast = 0 },
    ["auto shot"] = { name = "Auto Shot", kind = "toggle", range = "ranged", cooldown = 0, cast = 0 },
    ["serpent sting"] = { name = "Serpent Sting", range = "ranged", cooldown = 0, cast = 0 },
    ["arcane shot"] = { name = "Arcane Shot", range = "ranged", cooldown = 6, cast = 0 },
    ["raptor strike"] = { name = "Raptor Strike", range = "melee", cooldown = 6, on_next_swing = true },
}

local function color(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end

local function bundle(opts)
    local W = {
        ring_2d = opts and opts.ring_2d,
        clock = 1000.0,
        distance = 20,
        gcd = 0, cast_left = 0, casting = nil,
        cooldown = {}, unusable = {}, untrained = {}, cast_time = { [686] = 2.5 },
        want = {}, current = {}, settings = {}, handlers = {}, casts = {},
        sw = 1920, sh = 1080, art_ready = true, rot_active = true,
        ui_depth = 0, ui_calls = 0,
    }

    _G.core = {
        time = function() return W.clock end,
        spell_book = {
            is_current_spell = function(id) return W.current[id] == true end,
        },
    }

    local player = {
        get_guid = function() return "player" end,
        get_class = function() return 3 end,
        get_attack_speed = function() return 2.0 end,
        is_moving = function() return false end,
        is_dead = function() return false end,
        is_mounted = function() return false end,
    }
    local target = {
        is_valid = function() return true end,
        is_dead = function() return false end,
        get_guid = function() return "mob" end,
    }
    W.player, W.target = player, target

    -- --- draw, recorded ---------------------------------------------------------
    local D = { rects = {}, images = {}, texts = {} }
    W.D = D
    local draw = {
        theme = {
            backdrop = color(18, 18, 22, 200), outline = color(0, 0, 0, 180),
            text = color(235, 235, 240), text_dim = color(165, 168, 178),
            accent = color(140, 120, 240), warning = color(240, 180, 60),
        },
        screen_size = function() return W.sw, W.sh end,
        rect_2d = function(at, w, h, col, opts)
            D.rects[#D.rects + 1] = { x = at.x, y = at.y, w = w, h = h, col = col,
                filled = opts and opts.filled == true }
        end,
        image = function(ref, at, w, h, tint)
            if not W.art_ready then return false end
            D.images[#D.images + 1] = { ref = ref, x = at.x, y = at.y, w = w, h = h, tint = tint }
            return true
        end,
        text_2d = function(at, text, col)
            D.texts[#D.texts + 1] = { x = at.x, y = at.y, text = text, col = col }
        end,
        line_2d = function() end,
        arrow_2d = function() end,
        ring_2d = W.ring_2d and function(at, r, frac, col, opts)
            D.rings = D.rings or {}
            D.rings[#D.rings + 1] = { x = at.x, y = at.y, r = r, frac = frac, col = col, opts = opts }
        end or nil,
        measure = function(text, size) return #text * size * 0.55 end,
    }

    -- --- the overlay UI's window: a title bar only -----------------------------
    local ui = {}
    function ui:begin_window(id, opts)
        W.ui_depth = W.ui_depth + 1
        W.ui_calls = W.ui_calls + 1
        W.win_id, W.win_opts = id, opts
        local win = W.win
        if not win then
            win = { x = opts.x, y = opts.y, w = opts.w, h = opts.h, visible = true, collapsed = false }
            W.win = win
        end
        win.w, win.h = opts.w, opts.h
        if W.ui_disabled or win.collapsed or not win.visible then return false, win end
        return true, win
    end
    function ui:end_window()
        W.ui_depth = W.ui_depth - 1
    end

    local P = {
        log = {
            fmt = function() end, once = function() end, info = function() end,
            debug = function() end, warn = function() end, error = function() end,
        },
        ctx = {
            id = "jambix.aio",
            on = function(event, fn)
                W.handlers[event] = W.handlers[event] or {}
                table.insert(W.handlers[event], fn)
            end,
            tick = function() end,
            emit = function() end,
            cast = function(request)
                request.owner = "jambix.aio"
                W.casts[#W.casts + 1] = request
                if W.dispatch then W.fire("jcore.cast.sent", request) end
            end,
            spells = {
                name = function(id) return NAMES[id] or "" end,
                info = function(id) return { cast_time = W.cast_time[id] or 0 } end,
                cooldown = function(id) return W.cooldown[id] or 0 end,
                usable = function(id) return not W.unusable[id] end,
                gcd = function() return W.gcd end,
            },
            player = {
                casting_spell_id = function() return W.casting end,
                cast_remaining = function() return W.cast_left end,
            },
            PRIORITY = { ROTATION = 50, COOLDOWN = 80, EMERGENCY = 100 },
            LAYER = { HUD = 500 },
            ui = ui,
        },
        units = {
            player = function() return player end,
            distance = function() return W.distance end,
            has_aura = function() return false end,
        },
        combat = {
            cast_remaining = function() return W.cast_left end,
            in_combat = function() return W.in_combat == true end,
            target = function() return W.has_target and target or nil end,
        },
        spellbook = {
            id = function(name) return not W.untrained[name] and IDS[name] or nil end,
            ids = function(name) return IDS[name] and { IDS[name] } or nil end,
            known = function(name) return IDS[name] ~= nil and not W.untrained[name] end,
            ready = function(name) return IDS[name] ~= nil end,
            castable = function(name) return IDS[name] ~= nil end,
            names = function() return {} end,
        },
        talents = { rank = function() return 0 end },
        targeting = {},
        catalog = {
            ability = function(name) return ROWS[name:lower()] end,
            current = function() return { ranges = { ranged = { min = 8, max = 35 } } } end,
            with_role = function() return {} end,
        },
        opt = function(id, default)
            local v = W.settings[id]
            if v == nil then return default end
            return v
        end,
        optpct = function(_, default) return default / 100 end,
        draw = draw,
        color = color,
        JCore = {
            ui = {
                theme = {
                    bg = color(19, 20, 25, 236), bg_title = color(27, 29, 37, 248),
                    bg_elevated = color(36, 38, 48), border = color(62, 65, 80),
                    accent = color(140, 120, 240), warning = color(240, 180, 60),
                    track = color(44, 46, 58), text = color(235, 235, 240),
                    text_dim = color(160, 163, 176), text_disabled = color(105, 108, 120),
                    title_h = 24, scale = 1.0,
                },
            },
        },
        master_on = function() return true end,
        rotation_active = function() return W.rot_active end,
    }
    W.P = P

    W.rotation = make_rotation(P)
    P.rotation = W.rotation
    W.timeline = make_timeline(P)
    P.timeline = W.timeline
    W.settings.rot_enabled = true

    function W.fire(event, data)
        for _, fn in ipairs(W.handlers[event] or {}) do fn(data) end
    end

    function W.succeeded(name_or_id)
        local id = type(name_or_id) == "number" and name_or_id or IDS[name_or_id]
        W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-guid", id })
    end

    local function rule(name, extra)
        local r = { name, function() return W.want[name] == true end }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end

    W.profile = {
        label = "Levelling",
        rules = {
            rule("Hunter's Mark", { upkeep = 5 }),
            rule("Auto Shot", { upkeep = 1, direct = true }),
            rule("Serpent Sting", { upkeep = 2, dot = true }),
            rule("Arcane Shot"),
            rule("Raptor Strike"),
            rule("Shadow Bolt"),
        },
    }
    W.rotation.classes.HUNTER = { key = "hunter", profiles = { test = W.profile }, profile_order = { "test" } }

    function W.snapshot()
        return {
            player = player, target = target, in_combat = true,
            distance = W.distance, hold_fire = false, ttd = 20,
        }
    end

    function W.forecast(count)
        return W.rotation.forecast(W.profile, W.snapshot(), count or 4)
    end

    function W.names(rows)
        local out = {}
        for i = 1, #rows do out[i] = rows[i].name end
        return table.concat(out, ", ")
    end

    function W.render()
        D.rects, D.images, D.texts = {}, {}, {}
        W.timeline.render()
    end

    return W
end

local function overlaps(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

local T = {}

-- --- the forecast ------------------------------------------------------------------

T[#T + 1] = { "the opener in priority order, each upkeep once, toggles left out", function()
    local W = bundle()
    W.want["Hunter's Mark"], W.want["Auto Shot"] = true, true
    W.want["Serpent Sting"], W.want["Arcane Shot"] = true, true

    local rows = W.forecast(4)
    assert_eq(W.names(rows), "Hunter's Mark, Serpent Sting, Arcane Shot, Arcane Shot",
        "mark, sting, shot, then the shot again off its cooldown")
    assert_near(rows[1].at, 0, "the mark now")
    assert_near(rows[2].at, 1.5, "the sting a global cooldown later")
    assert_near(rows[3].at, 3.0, "the shot after that")
    assert_near(rows[4].at, 9.0, "and again when its six seconds are up")
end }

T[#T + 1] = { "a spell on cooldown waits; a filler fills the gap and repeats", function()
    local W = bundle()
    W.want["Arcane Shot"], W.want["Shadow Bolt"] = true, true
    W.cooldown[IDS["Arcane Shot"]] = 2.0

    local rows = W.forecast(3)
    assert_eq(W.names(rows), "Shadow Bolt, Arcane Shot, Shadow Bolt", "the bolt covers the cooldown")
    assert_near(rows[1].at, 0, "bolt now")
    assert_near(rows[2].at, 2.5, "the shot as the bolt's cast ends")
    assert_near(rows[3].at, 4.0, "bolt again after the shot's global cooldown")
end }

T[#T + 1] = { "the lane frees when the global cooldown and the cast in flight are both done", function()
    local W = bundle()
    W.want["Arcane Shot"] = true
    W.gcd, W.cast_left = 0.6, 1.2
    local rows = W.forecast(1)
    assert_near(rows[1].at, 1.2, "after the cast, the longer of the two")
end }

T[#T + 1] = { "out of reach, unaffordable, untrained or not wanted: not forecast", function()
    local W = bundle()
    W.want["Arcane Shot"], W.want["Shadow Bolt"], W.want["Serpent Sting"] = true, true, true
    W.distance = 50
    assert_eq(W.names(W.forecast(2)), "Shadow Bolt, Shadow Bolt", "the shots do not reach 50 yards")

    W.distance = 20
    W.unusable[IDS["Arcane Shot"]] = true
    W.untrained["Shadow Bolt"] = true
    assert_eq(W.names(W.forecast(3)), "Serpent Sting", "no mana for the shot, no bolt trained")
end }

T[#T + 1] = { "an off-GCD press takes no time from the lane", function()
    local W = bundle()
    W.want["Raptor Strike"], W.want["Shadow Bolt"] = true, true
    W.distance = 3
    local rows = W.forecast(3)
    assert_eq(W.names(rows), "Raptor Strike, Shadow Bolt, Shadow Bolt", "strike, then the lane")
    assert_eq(rows[1].fast, true, "the strike rides the swing")
    assert_near(rows[2].at, 0, "the bolt goes at the same moment")
end }

T[#T + 1] = { "a press already sent is in flight, not next", function()
    local W = bundle()
    W.want["Arcane Shot"], W.want["Shadow Bolt"] = true, true
    W.dispatch = true
    W.rotation.run_rules(W.profile, W.snapshot())
    assert_eq(#W.casts, 1, "the walk pressed the shot")
    assert_eq(W.casts[1].reason, "Arcane Shot", "the shot")
    assert_eq(W.names(W.forecast(1)), "Shadow Bolt", "the shot is in flight; the bolt is next")

    -- It lands: in the history, marked as the plugin's.
    W.cooldown[IDS["Arcane Shot"]] = 6
    W.succeeded("Arcane Shot")
    local h = W.timeline.history()
    assert_eq(#h, 1, "recorded")
    assert_eq(h[1].ours, true, "pressed by the plugin")
end }

T[#T + 1] = { "predicates know when the forecast is asking, and the flag always comes down", function()
    local W = bundle()
    local H = W.rotation.helpers
    local seen = {}
    W.profile.rules[4][2] = function()
        seen[#seen + 1] = H.forecasting()
        return true
    end

    W.forecast(1)
    assert_eq(seen[1], true, "up while the forecast asks")
    assert_eq(H.forecasting(), false, "down afterwards")

    W.rotation.run_rules(W.profile, W.snapshot())
    assert_eq(seen[#seen], false, "the walk's own question is not a forecast")

    -- Something in the forecast raises outside a predicate's own guard.
    W.P.spellbook.id = function() error("spellbook gone") end
    local ok = pcall(W.forecast, 1)
    assert_eq(ok, false, "the error still surfaces")
    assert_eq(H.forecasting(), false, "and the flag is not left up")
end }

T[#T + 1] = { "the projection runs only while the window shows it, at its own rate", function()
    local W = bundle()
    W.want["Arcane Shot"] = true

    W.rotation._forecast_snapshot(W.profile, W.snapshot())
    W.rotation.forecast_tick()
    assert_eq(W.rotation.projection().at, 0, "no window, no projection")

    W.render()
    assert_eq(W.timeline.wants_forecast(), 3, "the window asks for its three")
    W.rotation._forecast_snapshot(W.profile, W.snapshot())
    W.rotation.forecast_tick()
    local proj = W.rotation.projection()
    assert_eq(W.names(proj.rows), "Arcane Shot, Arcane Shot, Arcane Shot",
        "projected: now, at 6s and at 12s, the edge of the horizon")
    assert_eq(proj.live, true, "from the tick's own snapshot")
    assert_eq(proj.label, "Levelling", "with the profile's name")

    -- Inside the interval nothing is recomputed, whatever changed.
    W.want["Arcane Shot"] = false
    W.clock = W.clock + 0.1
    W.rotation._forecast_snapshot(W.profile, W.snapshot())
    W.rotation.forecast_tick()
    assert_eq(#W.rotation.projection().rows, 3, "throttled")

    W.clock = W.clock + 0.15
    W.rotation._forecast_snapshot(W.profile, W.snapshot())
    W.rotation.forecast_tick()
    assert_eq(#W.rotation.projection().rows, 0, "recomputed after the interval")
end }

T[#T + 1] = { "rotation off and suggestions off: nothing is projected", function()
    local W = bundle()
    W.want["Arcane Shot"] = true
    W.settings.rot_enabled = false
    W.settings.rot_hud_suggest = false
    W.render()
    W.rotation.forecast_tick()   -- no snapshot: the rotation did not tick
    assert_eq(#W.rotation.projection().rows, 0, "no suggestion")
end }

-- --- the history -------------------------------------------------------------------

T[#T + 1] = { "each cast is recorded once; auto shots and procs are not", function()
    local W = bundle()
    W.succeeded("Arcane Shot")
    W.clock = W.clock + 0.1
    W.succeeded("Arcane Shot")
    assert_eq(#W.timeline.history(), 1, "one cast reported twice is one cast")

    W.succeeded("Auto Shot")
    W.succeeded(20007)
    assert_eq(#W.timeline.history(), 1, "no Auto Shot, no weapon proc")

    W.settings.rot_hud_autos = true
    W.clock = W.clock + 1
    W.succeeded("Auto Shot")
    assert_eq(#W.timeline.history(), 2, "Auto Shot when asked for")

    W.clock = W.clock + 1
    W.succeeded("Serpent Sting")
    local h = W.timeline.history()
    assert_eq(h[#h].name, "Serpent Sting", "newest last")
    assert_eq(h[#h].ours, false, "pressed by hand")

    for i = 1, 20 do
        W.clock = W.clock + 1
        W.succeeded(i % 2 == 0 and "Arcane Shot" or "Serpent Sting")
    end
    assert_eq(#W.timeline.history(), 16, "bounded")
end }

T[#T + 1] = { "another plugin's press is not ours", function()
    local W = bundle()
    W.fire("jcore.cast.sent", { spell_id = IDS["Arcane Shot"], owner = "someone.else" })
    W.succeeded("Arcane Shot")
    assert_eq(W.timeline.history()[1].ours, false, "not ours")
end }

T[#T + 1] = { "the cast hook stands in until the event has been seen", function()
    local W = bundle()
    W.fire("jcore.spell.cast", { spell_id = IDS["Arcane Shot"], caster = W.player })
    W.fire("jcore.spell.cast", { spell_id = IDS["Serpent Sting"], caster = W.target })
    assert_eq(#W.timeline.history(), 1, "the player's cast, not the mob's")

    W.clock = W.clock + 1
    W.succeeded("Serpent Sting")
    W.clock = W.clock + 1
    W.fire("jcore.spell.cast", { spell_id = IDS["Hunter's Mark"], caster = W.player })
    assert_eq(#W.timeline.history(), 2, "the hook is dropped once the event answers")
    assert_eq(W.timeline.stats().source, "succeeded", "and says which source it uses")
end }

-- --- the paint ---------------------------------------------------------------------

T[#T + 1] = { "the backdrop is cut around the holes, exactly", function()
    local W = bundle()
    local holes = {
        { x = 18, y = 30, w = 36, h = 36 }, { x = 58, y = 30, w = 36, h = 36 },
        { x = 110, y = 26, w = 47, h = 47 }, { x = 161, y = 30, w = 36, h = 36 },
    }
    local pieces = W.timeline._fill_around(10, 20, 200, 70, holes, color(0, 0, 0, 236), 500)
    assert_eq(pieces, #W.D.rects, "one rect per piece")

    local area = 0
    for i = 1, #W.D.rects do
        local a = W.D.rects[i]
        area = area + a.w * a.h
        for j = 1, #holes do
            assert(not overlaps(a, holes[j]), "a piece covers hole " .. j)
        end
        for k = i + 1, #W.D.rects do
            assert(not overlaps(a, W.D.rects[k]), "pieces " .. i .. " and " .. k .. " overlap")
        end
    end
    local holes_area = 0
    for j = 1, #holes do holes_area = holes_area + holes[j].w * holes[j].h end
    assert_eq(area, 200 * 70 - holes_area, "everything else is filled")
end }

T[#T + 1] = { "no opaque shape is painted over an icon", function()
    local W = bundle()
    W.want["Hunter's Mark"], W.want["Serpent Sting"], W.want["Arcane Shot"] = true, true, true
    for _, name in ipairs({ "Hunter's Mark", "Serpent Sting", "Arcane Shot" }) do
        W.clock = W.clock + 1
        W.succeeded(name)
    end
    W.render()
    W.rotation._forecast_snapshot(W.profile, W.snapshot())
    W.rotation.forecast_tick()
    W.render()

    assert_eq(W.ui_depth, 0, "every begin_window was paired with end_window")
    assert_eq(W.win_opts.h, 24, "the overlay window is only its title bar")
    assert_eq(#W.D.images, 6, "three used, three coming")

    local spells = {}
    for i = 1, #W.D.images do spells[W.D.images[i].ref] = true end
    assert(spells["spell:" .. IDS["Hunter's Mark"]] and spells["spell:" .. IDS["Arcane Shot"]],
        "drawn from each spell's own icon")

    for i = 1, #W.D.images do
        local img = W.D.images[i]
        for k = 1, #W.D.rects do
            local r = W.D.rects[k]
            if r.filled and r.col and (r.col.a or 255) >= 200 then
                assert(not overlaps(img, r), string.format(
                    "an opaque fill at %d,%d %dx%d hides the icon %s", r.x, r.y, r.w, r.h, img.ref))
            end
        end
    end

    -- The window sits right of centre, above the action bars.
    local win = W.win
    assert(win.x > 1920 * 0.5 and win.x + win.w < 1920, "right of centre, on the screen")
    assert(win.y > 1080 * 0.55 and win.y < 1080 * 0.8, "low on the screen")
end }

T[#T + 1] = { "the next spell not ready yet is dimmed with its countdown", function()
    local W = bundle()
    W.want["Arcane Shot"] = true
    W.cooldown[IDS["Arcane Shot"]] = 2.4
    W.render()
    W.rotation._forecast_snapshot(W.profile, W.snapshot())
    W.rotation.forecast_tick()
    W.render()

    local found = false
    for i = 1, #W.D.texts do
        if W.D.texts[i].text == "2.4" then found = true end
    end
    assert(found, "the seconds on the icon")
end }

T[#T + 1] = { "the cast in flight takes the newest slot, with its progress", function()
    local W = bundle()
    W.succeeded("Arcane Shot")
    W.casting, W.cast_left = IDS["Shadow Bolt"], 1.0
    W.render()

    local bolt = nil
    for i = 1, #W.D.images do
        if W.D.images[i].ref == "spell:" .. IDS["Shadow Bolt"] then bolt = W.D.images[i] end
    end
    assert(bolt, "the bolt being cast is shown")

    local shot = nil
    for i = 1, #W.D.images do
        if W.D.images[i].ref == "spell:" .. IDS["Arcane Shot"] then shot = W.D.images[i] end
    end
    assert(shot and shot.x < bolt.x, "after the shot that was cast before it")

    -- 1.5 of 2.5 seconds done: a bar 60% of the icon wide under it.
    local bar = false
    for i = 1, #W.D.rects do
        local r = W.D.rects[i]
        if r.filled and r.x == bolt.x and r.y == bolt.y + bolt.h + 2 and r.w == math.floor(bolt.w * 0.6) then
            bar = true
        end
    end
    assert(bar, "the progress under it")
end }

T[#T + 1] = { "folded away: nothing painted and nothing projected", function()
    local W = bundle()
    W.render()
    W.win.collapsed = true
    W.render()
    assert_eq(#W.D.rects + #W.D.images, 0, "nothing under the folded title bar")
    assert_eq(W.timeline.wants_forecast(), 0, "and no projection to work out")
end }

T[#T + 1] = { "without the overlay UI the window draws its own title bar", function()
    local W = bundle()
    W.P.ctx.ui = nil
    W.succeeded("Arcane Shot")
    W.render()
    local titled = false
    for i = 1, #W.D.texts do
        if W.D.texts[i].text:find("Rotation", 1, true) then titled = true end
    end
    assert(titled, "a title bar of its own")
    assert_eq(#W.D.images, 1, "and the body still paints")
end }

T[#T + 1] = { "the title says when the window is only suggesting", function()
    local W = bundle()
    W.rot_active = false
    W.render()
    assert(W.win_opts.title:find("paused, suggesting", 1, true), "paused: " .. W.win_opts.title)
    W.settings.rot_enabled = false
    W.settings.rot_hud_suggest = false
    W.render()
    assert(W.win_opts.title:find("(off)", 1, true), "off: " .. W.win_opts.title)
end }


T[#T + 1] = { "the next spell not ready yet gets a sweep round it filling as the wait runs down (1.89.0)", function()
    local W = bundle({ ring_2d = true })
    W.want["Arcane Shot"] = true
    W.cooldown[IDS["Arcane Shot"]] = 2.4
    W.render()
    W.rotation._forecast_snapshot(W.profile, W.snapshot())
    W.rotation.forecast_tick()
    W.render()
    local rings = W.D.rings or {}
    assert(#rings >= 1, "a sweep")
    local last = rings[#rings]
    assert(last.frac >= 0 and last.frac < 0.2, "just begun, got " .. tostring(last.frac))
    local W2 = bundle()
    W2.want["Arcane Shot"] = true
    W2.cooldown[IDS["Arcane Shot"]] = 2.4
    W2.render()
    W2.rotation._forecast_snapshot(W2.profile, W2.snapshot())
    W2.rotation.forecast_tick()
    W2.render()
    assert_eq(W2.D.rings, nil, "an older JCore without ring_2d: no sweep, the dim and the seconds as before")
end }

return T

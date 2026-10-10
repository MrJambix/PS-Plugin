-- Jambix AIO 1.69.0: the icon card (modules/esp/card.lua), the one painter
-- every Forever ESP mark goes through. Drawn into a recording draw service.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local make_card = require("jambix_aio/modules/esp/card")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A card on a recording draw service. `loaded` says which images have
--- loaded (all of them when nil). `soft` gives it JCore's plate_2d, bar_2d
--- and blend (1.88.0); without it the draw service is an older JCore's.
local function setup(loaded, soft)
    local calls = {}
    local draw = {
        measure = function(text, size) return #text * size * 0.5 end,
        rect_2d = function(at, w, h, c, o) calls[#calls + 1] = { name = "rect", at = at, w = w, h = h, c = c, o = o } end,
        text_2d = function(at, text, c, o) calls[#calls + 1] = { name = "text", at = at, text = text, c = c, o = o } end,
        image = function(ref, at, w, h, tint, o)
            calls[#calls + 1] = { name = "image", ref = ref, at = at, w = w, h = h, tint = tint, o = o }
            return true
        end,
    }
    if soft then
        draw.plate_2d = function(at, w, h, c, o)
            calls[#calls + 1] = { name = "plate", at = at, w = w, h = h, c = c, o = o }
        end
        draw.bar_2d = function(at, w, h, fraction, c, o)
            calls[#calls + 1] = { name = "bar", at = at, w = w, h = h, fraction = fraction, c = c, o = o }
        end
        draw.blend = function(a, b, t)
            local function mix(x, y) return math.floor(x + (y - x) * t + 0.5) end
            return { r = mix(a.r, b.r), g = mix(a.g, b.g), b = mix(a.b, b.b), a = mix(a.a or 255, b.a or 255) }
        end
    end
    local P = {
        draw = draw,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        JCore = { assets = { request = function(ref) return loaded == nil or loaded[ref] == true end } },
    }
    return make_card(P), calls
end

local function of(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local WHITE = { r = 255, g = 255, b = 255, a = 255 }
local T = {}

T[#T + 1] = { "every icon sits left of its row's text, never on a pill", function()
    local card, calls = setup()
    card.begin_frame()
    card.start(13, 300)
    card.head()
    card.icon("art:creature.1")
    card.text("Ragged Young Wolf", WHITE)
    card.pill()
    card.icon("art:elite")
    card.icon("art:fight.melee")
    card.text("15", WHITE)
    card.text(" \194\183 ", WHITE)
    card.text("42y", WHITE)
    local drawn = card.place(500, 400)
    assert(drawn, "drawn")
    local pills = {}
    for _, r in ipairs(of(calls, "rect")) do if r.o and r.o.filled and r.o.rounding then pills[#pills + 1] = r end end
    assert_eq(#pills, 1, "one pill: the facts row (the name has none)")
    local pill = pills[1]
    local images = of(calls, "image")
    assert_eq(#images, 3, "three icons")
    for i = 2, 3 do
        local img = images[i]
        local overlap = img.at.x < pill.at.x + pill.w and img.at.x + img.w > pill.at.x
            and img.at.y < pill.at.y + pill.h and img.at.y + img.h > pill.at.y
        assert(not overlap, "icon " .. img.ref .. " is not under the pill")
        assert(img.at.x + img.w <= pill.at.x, img.ref .. " left of the pill")
    end
    local name = of(calls, "text")[1]
    assert(images[1].at.x + images[1].w <= name.at.x - (#name.text * 6.5) / 2 + 0.01, "the type icon left of the name")
    assert(name.at.y > 400, "under the feet")
end }

T[#T + 1] = { "an icon that has not loaded leaves no gap; a card with nothing in it is not drawn", function()
    local card, calls = setup({ ["art:kill"] = true })
    card.begin_frame()
    card.start(13, 300)
    card.head()
    assert_eq(card.icon("art:creature.1"), false, "not loaded: not added")
    card.text("Wolf", WHITE)
    card.place(500, 400)
    assert_eq(#of(calls, "image"), 0, "no image")
    assert_eq(of(calls, "text")[1].at.x, 500, "the name centred, as if there were no icon")

    card.start(13, 300)
    card.head()
    card.pill()
    local drawn = card.place(900, 400)
    assert_eq(drawn, false, "an empty card draws nothing")
end }

T[#T + 1] = { "two cards on one spot: the second moves down clear of the first; a crowd prints where it stands", function()
    local card, calls = setup()
    card.begin_frame()
    for i = 1, 2 do
        card.start(13, 300)
        card.head()
        card.text("Kobold " .. i, WHITE)
        local _, crowded = card.place(500, 400)
        assert_eq(crowded, false, "room found")
    end
    local texts = of(calls, "text")
    assert(texts[2].at.y >= texts[1].at.y + 13, "the second below the first")

    local crowded_n = 0
    for i = 1, 12 do
        card.start(13, 300)
        card.head()
        card.text("Kobold " .. i, WHITE)
        local drawn, crowded = card.place(500, 400)
        assert(drawn, "drawn even in a crowd")
        if crowded then crowded_n = crowded_n + 1 end
    end
    assert(crowded_n > 0, "the crowd printed where it stood rather than vanish")
    assert_eq(card.stats().crowded, crowded_n, "counted")
end }

T[#T + 1] = { "above a point, unclaimed: a label over a place on the ground", function()
    local card, calls = setup()
    card.begin_frame()
    card.start(13, 300)
    card.pill(WHITE)
    card.icon("art:quest_turnin")
    card.text("Wolves at the Door \194\183 141y", WHITE)
    card.place(800, 500, { above = true, claim = false })
    local pill
    for _, r in ipairs(of(calls, "rect")) do if r.o and r.o.filled then pill = r end end
    assert(pill.at.y + pill.h <= 500, "above the point")
    -- Unclaimed: a card placed on the same spot afterwards does not move.
    card.start(13, 300)
    card.pill()
    card.text("again", WHITE)
    card.place(800, 500, { above = true })
    local again = of(calls, "text")[2]
    assert(again.at.y < 500, "not pushed down by the unclaimed label")
end }

T[#T + 1] = { "a pill with a bar under it: as wide as the pill, filled to the fraction", function()
    local card, calls = setup()
    card.begin_frame()
    card.start(13, 300)
    card.pill(WHITE)
    card.text("Frostbolt 1.5s", WHITE)
    card.under(0.25, WHITE)
    card.place(500, 400)
    local pill, bars = nil, {}
    for _, r in ipairs(of(calls, "rect")) do
        if r.o and r.o.filled and r.o.rounding then pill = r
        elseif r.o and r.o.filled and r.h == 3 then bars[#bars + 1] = r end
    end
    assert(pill, "the pill")
    assert_eq(#bars, 2, "backing and fill")
    assert_eq(bars[1].w, pill.w, "the backing as wide as the pill")
    assert_eq(bars[2].w, pill.w * 0.25, "the fill a quarter")
    assert(bars[1].at.y >= pill.at.y + pill.h, "under the pill")
end }

-- --- soft cards and bars (1.88.0) ---------------------------------------------

local RED = { r = 200, g = 40, b = 40, a = 255 }

--- One card of every kind of row: a head with an icon, a health bar (the
--- game's texture offered), a pill with icons and a border, a pill with a
--- bar under it.
local function every_row(card)
    card.start(13, 300)
    card.head()
    card.icon("art:creature.1")
    card.text("Ragged Young Wolf", WHITE)
    card.bar(0.5, RED, 54, 4, "art:statusbar", { 0, 0.9, 0.25, 1 })
    card.pill(WHITE)
    card.icon("art:elite")
    card.icon("art:fight.melee")
    card.text("15", WHITE)
    card.pill(RED)
    card.icon("spell:116")
    card.text("Frostbolt 1.5s", WHITE)
    card.under(0.25, RED)
    return card.place(500, 400)
end

T[#T + 1] = { "soft cards (1.88.0): a pill is JCore's plate, its outline the plate's border, no shadow; icons stay left of it", function()
    local card, calls = setup(nil, true)
    card.begin_frame()
    assert(every_row(card), "drawn")
    local plates = of(calls, "plate")
    assert_eq(#plates, 2, "one plate for each pill")
    for _, p in ipairs(plates) do
        assert_eq(p.c.a, 215, "the card's backdrop")
        assert_eq(p.o.rounding, 3, "the same rounding")
        assert_eq(p.o.shadow, false, "no shadow: it would reach the icons")
        assert_eq(p.o.layer, 300, "on the card's layer")
    end
    assert_eq(plates[1].o.border, WHITE, "the outline is the plate's border")
    for _, r in ipairs(of(calls, "rect")) do assert(not (r.o and r.o.filled), "no flat filled rectangle") end
    for _, img in ipairs(of(calls, "image")) do
        for _, p in ipairs(plates) do
            local overlap = img.at.x < p.at.x + p.w and img.at.x + img.w > p.at.x
                and img.at.y < p.at.y + p.h and img.at.y + img.h > p.at.y
            assert(not overlap, img.ref .. " is not on a plate")
        end
    end
end }

T[#T + 1] = { "soft bars (1.88.0): health and a cast's progress are JCore's bar, lighter at the end; the texture bar too", function()
    local card, calls = setup(nil, true)
    card.begin_frame({ soft = true })
    every_row(card)
    local bars = of(calls, "bar")
    assert_eq(#bars, 2, "the health bar and the one under the cast")
    local health, under = bars[1], bars[2]
    assert_eq(health.w, 54, "the health bar's width"); assert_eq(health.h, 4, "and height")
    assert_eq(health.fraction, 0.5, "half full")
    assert_eq(health.c, RED, "its colour")
    assert_eq(health.o.to.r, math.floor(200 + 55 * 0.25 + 0.5), "a quarter of the way to white at its end")
    assert_eq(health.o.to.g, math.floor(40 + 215 * 0.25 + 0.5), "every channel")
    assert_eq(health.o.bg.a, 185, "on the dark rail")
    for _, img in ipairs(of(calls, "image")) do
        assert(img.ref ~= "art:statusbar", "the game's texture is not drawn with the soft look")
    end
    assert_eq(under.h, 3, "a thin bar under the pill")
    assert_eq(under.fraction, 0.25, "a quarter through")
    assert_eq(under.c, RED, "in the cast's colour")
    local plate = of(calls, "plate")[2]
    assert_eq(under.w, plate.w, "as wide as its pill")
    assert(under.at.y >= plate.at.y + plate.h, "under it")
    assert(under.o.to.r > RED.r, "lighter at its end")
end }

T[#T + 1] = { "soft off for the frame, or a JCore without plate_2d and bar_2d: the flat shapes and the texture, as before", function()
    for _, case in ipairs({ { soft = true, opts = { soft = false } }, { soft = false, opts = nil } }) do
        local card, calls = setup(nil, case.soft)
        card.begin_frame(case.opts)
        every_row(card)
        assert_eq(#of(calls, "plate") + #of(calls, "bar"), 0, "no soft shapes")
        local pills, under, textures = 0, 0, 0
        for _, r in ipairs(of(calls, "rect")) do
            if r.o and r.o.filled and r.o.rounding then pills = pills + 1 end
            if r.o and r.o.filled and r.h == 3 then under = under + 1 end
        end
        for _, img in ipairs(of(calls, "image")) do if img.ref == "art:statusbar" then textures = textures + 1 end end
        assert_eq(pills, 2, "the flat pills")
        assert_eq(under, 2, "the cast's backing and fill")
        assert_eq(textures, 2, "the texture bar: backing and fill")
    end
    -- And back on the next frame.
    local card, calls = setup(nil, true)
    card.begin_frame({ soft = false })
    card.begin_frame()
    every_row(card)
    assert_eq(#of(calls, "plate"), 2, "soft again")
end }

return T

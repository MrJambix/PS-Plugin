-- Jambix AIO 1.7.6: the experience bars (modules/xpbar.lua), on a hand-built
-- bundle with a scripted clock, a scripted experience and quest log, and the
-- ESP's draw queue recorded. What a quest pays: the table's
-- (QuestieDB's, modules/questxp_data.lua) with the level penalty, a learned
-- turn-in, a guess at the level's usual pay; the game's own ratio when it
-- pays more. Experience per hour across a level-up. The sums: finished
-- quests, the whole log, past the level. Both bars, drawn by the ESP, each by
-- its switch: their words, the quest list under the cursor, the width their
-- words need, and the handles that move them.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function assert_true(v, label)
    if not v then error(label, 2) end
end

local function world(opts)
    opts = opts or {}
    local W = { clock = 1000, xp = opts.xp or 0, max = opts.max or 7600, level = opts.level or 10, rested = nil,
        settings = opts.settings or {}, handlers = {}, traces = {}, windows = {}, handles = {}, texts = {},
        rects = {}, cursor = nil, quests = {}, order = {} }
    _G.core = {
        time = function() return W.clock end,
        character = {
            get_xp = function() return W.xp end,
            get_xp_max = function() return W.max end,
            get_rested_xp = function() return W.rested end,
        },
    }
    local player = { get_level = function() return W.level end }
    local store = opts.store or { data = {}, touch = function() end }
    W.store = store
    -- The ESP's draw queue, recorded. Text is 8 px a character at size 16.
    local draw = {
        rect_2d = function(pos, w, h, col, o)
            W.rects[#W.rects + 1] = { x = pos.x, y = pos.y, w = w, h = h, col = col, filled = o and o.filled }
        end,
        text_2d = function(pos, s, col, o) W.texts[#W.texts + 1] = s end,
        measure = function(s, size) return #s * size * 0.5 end,
        screen_size = function() return 1920, 1080 end,
    }
    -- JCore's windows, only for the move handles: where each was dragged to.
    local ui = {}
    function ui:begin_window(id, o)
        W.windows[#W.windows + 1] = { id = id, title = o.title, w = o.w, x = o.x, y = o.y }
        local win = W.handles[id] or { x = o.x, y = o.y }
        W.handles[id] = win
        return true, win
    end
    function ui:end_window() end
    function ui:metrics() return { scale = 1, title_h = 24 } end
    local P = {
        ctx = {
            on = function(name, fn) W.handlers[name] = fn end,
            emit = function(_, text) W.traces[#W.traces + 1] = text end,
            store = function() return store end,
            ui = ui,
            input = { cursor_position = function() return W.cursor end },
            LAYER = { HUD = 300 },
        },
        log = { once = function() end, fmt = function() end, info = function() end },
        units = { player = function() return player end },
        draw = draw,
        quests = { index = { order = W.order, quests = W.quests } },
        opt = function(id, d) local v = W.settings[id] if v == nil then return d end return v end,
    }
    package.loaded["jambix_aio/modules/xpbar"] = nil
    W.M = require("jambix_aio/modules/xpbar")(P)
    function W.quest(id, level, complete, extra)
        local q = { id = id, name = (extra and extra.name) or ("Quest " .. id), level = level, complete = complete,
            objectives = {} }
        for k, v in pairs(extra or {}) do q[k] = v end
        W.quests[id] = q
        W.order[#W.order + 1] = id
        return q
    end
    function W.at(seconds)
        W.clock = W.clock + seconds
        W.M.poll()
    end
    function W.turn_in(id, xp)
        W.handlers["jcore.game_event.QUEST_TURNED_IN"]({ id, xp, 0 })
    end
    function W.frame()
        W.windows, W.texts, W.rects = {}, {}, {}
        W.M.render()
    end
    --- The plates drawn this frame (the ESP's pill backdrop), in order.
    function W.plates()
        local out = {}
        for _, r in ipairs(W.rects) do
            if r.filled and r.col[1] == 12 and r.col[2] == 12 and r.col[3] == 16 then out[#out + 1] = r end
        end
        return out
    end
    W.M.poll()
    return W
end

local function has_text(W, pattern)
    for _, s in ipairs(W.texts) do if tostring(s):find(pattern) then return s end end
    return nil
end

local T = {}

T[#T + 1] = { "a table quest pays what QuestieDB says, less past its level + 5", function()
    local W = world({ level = 16 })
    assert_eq(select(1, W.M.reward(244, 16, 16)), 290, "Forever paid 290 for 244: the recorder's example")
    assert_eq(select(2, W.M.reward(244, 16, 16)), "table", "from the table")
    assert_eq(select(1, W.M.reward(65, 18, 18)), 1350, "Forever paid 1350 for 65")
    assert_eq(select(1, W.M.reward(244, 16, 21)), 290, "level + 5: still full")
    assert_eq(select(1, W.M.reward(244, 16, 22)), 230, "level + 6: 80%, to the server's 10")
    assert_eq(select(1, W.M.reward(244, 16, 23)), 170, "level + 7: 60%")
    assert_eq(select(1, W.M.reward(244, 16, 30)), 30, "level + 10 and more: 10%, to the server's 5")
    assert_eq(select(1, W.M.reward(244, 16, 60)), 0, "max level: nothing")
    assert_eq(select(1, W.M.adjusted(1000, 10, 16)), 800, "adjusted: 80% of 1000")
    assert_eq(select(1, W.M.adjusted(1520, 20, 20)), 1500, "over 1000: to the server's 50")
end }

T[#T + 1] = { "Forever's own quest: a guess at its level's usual pay, then what it paid", function()
    local W = world({ level = 10 })
    local xp, how = W.M.reward(91733, 10, 10)
    assert_eq(how, "guess", "not in the table")
    assert_eq(xp, 850, "a standard level-10 quest: 840, to the server's 25")
    W.turn_in(91733, 900)
    xp, how = W.M.reward(91733, 10, 10)
    assert_eq(how, "learned", "handed in once: learned")
    assert_eq(xp, 900, "what it paid")
    assert_true(W.traces[#W.traces]:find("quest 91733 handed in for 900 xp at level 10 %(guessed 850, learned%)"),
        "traced: " .. tostring(W.traces[#W.traces]))
    assert_eq(select(1, W.M.reward(91733, 10, 16)), 725, "learned, then the level penalty like any quest")
end }

T[#T + 1] = { "three guessed turn-ins correct every guess after them", function()
    local W = world({ level = 10 })
    for i = 1, 3 do W.turn_in(91000 + i, 1275) end   -- 1.5 x a standard 850
    local xp, how = W.M.reward(91999, 10, 10)
    assert_eq(how, "guess", "still a guess")
    assert_eq(xp, 1275, "at the pay seen")
    assert_eq(select(1, W.M.reward(65, 18, 18)), 1350, "the table's quests keep their own rate")
end }

T[#T + 1] = { "a game paying more than the table: every table quest follows", function()
    local W = world({ level = 16 })
    W.turn_in(244, 435)
    W.turn_in(244, 435)
    assert_eq(select(1, W.M.reward(65, 18, 18)), 2025, "1.5 x 1350")
    assert_eq(W.M.stats().game_rate, 1.5, "the rate in the stats")
end }

T[#T + 1] = { "experience per hour, from the first minute, across a level-up", function()
    local W = world({ xp = 1000, max = 7600, level = 10 })
    W.at(30)
    W.xp = 2000
    W.at(10)
    assert_eq(W.M.rate(), nil, "under a minute: no rate yet")
    W.xp = 7000
    W.at(560)                                    -- 600 s, 6000 xp
    assert_eq(math.floor(W.M.rate() + 0.5), 36000, "6000 in 10 minutes")
    W.level, W.xp, W.max = 11, 400, 8800        -- 600 to finish 10, then 400
    W.at(600)
    assert_eq(W.M.stats().gained, 7000, "the level-up counted")
    assert_eq(math.floor(W.M.rate() + 0.5), 21000, "7000 in 20 minutes")
    W.settings.xpbar_rate_minutes = 10
    assert_eq(math.floor(W.M.rate() + 0.5), 6000, "the last 10 minutes only: 1000")
    W.M.reset()
    assert_eq(W.M.stats().gained, 0, "started again")
end }

T[#T + 1] = { "a read the client cannot answer (0 / 0, a loading screen) is no level-up", function()
    local W = world({ xp = 5000, max = 7600, level = 10 })
    W.xp, W.max = 0, 0
    W.at(1)
    W.xp, W.max = 5000, 7600
    W.at(1)
    assert_eq(W.M.stats().gained, 0, "nothing gained")
    assert_eq(W.M.stats().xp, 5000, "the good read kept")
    W.xp = 5100
    W.at(1)
    assert_eq(W.M.stats().gained, 100, "then counted as before")
end }

T[#T + 1] = { "a level read that lags the experience: the level-up counted once", function()
    local W = world({ xp = 7000, max = 7600, level = 10 })
    W.xp, W.max = 400, 8800          -- level 11 already, the level still reads 10
    W.at(1)
    assert_eq(W.M.stats().gained, 1000, "600 to finish 10, then 400")
    assert_eq(W.M.stats().level, 11, "the level taken as 11")
    W.level = 11                      -- the read catches up
    W.at(1)
    assert_eq(W.M.stats().gained, 1000, "not a second level-up")
    W.xp = 500
    W.at(1)
    assert_eq(W.M.stats().gained, 1100, "then counted as before")
    W.xp = 20                         -- a drop with the level and its need the same
    W.at(1)
    assert_eq(W.M.stats().gained, 1100, "no experience loss in Classic: a bad read")
    assert_eq(W.M.stats().xp, 500, "and not kept")
end }

T[#T + 1] = { "the sums: finished quests, the whole log, past the level", function()
    local W = world({ xp = 18500, max = 19400, level = 18 })
    W.quest(65, 18, true, { name = "The Defias Brotherhood" })
    W.quest(244, 16, false, { name = "Encroaching Gnolls" })
    W.quest(91733, 18, false, { name = "A Forever Quest" })
    W.quest(66, 18, false, { offered = true })
    W.quest(67, 18, false, { failed = true })
    local s = W.M.summary(true)
    assert_eq(s.ready.n, 1, "one finished")
    assert_eq(s.ready.xp, 1350, "its pay")
    assert_eq(s.open.n, 2, "two to do; a guide's offer and a failed quest are not counted")
    assert_eq(s.open.xp, 290 + 1350, "244, and a standard level-18 guess (1350)")
    assert_eq(s.open.guess, true, "a guess in it")
    assert_eq(s.to_ready.ups, 1, "18500 + 1350 is past 19400")
    assert_eq(s.to_ready.level, 19, "into 19")
    assert_eq(s.to_ready.xp, 450, "450 into it")
    assert_eq(s.to_ready.max, 21300, "of Classic's 21300")
    assert_eq(s.to_log.xp, 450 + 1640, "the log takes it further")
    W.turn_in(65, 1350)
    assert_eq(W.M.summary(true).ready.n, 0, "handed in: not summed while the log still lists it")
    W.clock = W.clock + 11
    assert_eq(W.M.summary(true).ready.n, 1, "listed 10 s on, it is in the log again")
end }

T[#T + 1] = { "both bars by default, drawn by the ESP: no window; their words and the gold", function()
    local W = world({ xp = 3800, max = 7600, level = 10 })
    W.quest(9, 15, true, { name = "Ready One" })            -- 1050
    W.quest(91733, 10, false, { name = "Forever Thing" })   -- ~850
    W.frame()
    assert_eq(#W.windows, 0, "no JCore window")
    assert_eq(W.M.stats().shown.ready, true, "the turn-ins bar")
    assert_eq(W.M.stats().shown.log, true, "the quest log bar")
    local plates = W.plates()
    assert_eq(#plates, 2, "one plate each")
    assert_eq(plates[1].w, 460, "the default width")
    assert_eq(plates[1].x, 960 - 230, "centred")
    assert_eq(plates[2].y, plates[1].y + W.M.layout(16).h + 10, "the log's under the turn-ins'")
    for _, want in ipairs({ "^TURN%-INS$", "^%+1,050 XP$", "^%-> 63%.8%%$", "^%-%- XP/hr$",
        "^3,800 / 7,600   50%.0%%$", "^1 finished quest to hand in$",
        "^QUEST LOG$", "^%+~1,900 XP$", "^%-> 75%.0%%$", "^1 finished %+1,050 XP   |   1 to do %+~850 XP$" }) do
        assert_true(has_text(W, want), "painted: " .. want)
    end
    local gold = 0
    for _, r in ipairs(W.rects) do
        if r.col[1] == 246 and r.col[2] == 190 and r.h == W.M.layout(16).bar_h then gold = gold + 1 end
    end
    assert_eq(gold, 2, "the gold stretch on both bars")
    assert_true(not has_text(W, "Ready One"), "no quest list without the cursor on a bar")

    W.clock = W.clock + 600
    W.xp = 5000
    W.M.poll()
    W.M.summary(true)
    W.frame()
    assert_true(has_text(W, "^7%.2k XP/hr$"), "the rate")
    assert_true(has_text(W, "^Level in 21m$"), "the time to level")

    W.settings.xpbar_log = false
    W.settings.xpbar_width = 600
    W.frame()
    assert_eq(#W.plates(), 1, "the log's switch off")
    assert_eq(W.plates()[1].w, 600, "the width slider")
    W.settings.xpbar_ready = false
    W.frame()
    assert_eq(#W.plates(), 0, "both off: nothing")
    assert_eq(W.M.stats().gained, 1200, "the rate is still kept with both off")
end }

T[#T + 1] = { "the cursor on a bar lists its quests under it", function()
    local W = world({ xp = 3800, max = 7600, level = 10 })
    W.quest(9, 15, true, { name = "Ready One" })
    W.quest(91733, 10, false, { name = "Forever Thing" })
    W.frame()
    local p = W.plates()
    W.cursor = { x = p[1].x + 20, y = p[1].y + 20 }
    W.frame()
    assert_true(has_text(W, "^Finished, to hand in$"), "the turn-ins list's heading")
    assert_true(has_text(W, "^1,050$"), "its pay")
    assert_true(has_text(W, "^Ready One$"), "its name")
    assert_true(not has_text(W, "Forever Thing"), "finished quests only")
    W.cursor = { x = p[2].x + 20, y = p[2].y + 20 }
    W.frame()
    assert_true(has_text(W, "^Still to do$"), "the log's second heading")
    assert_true(has_text(W, "^~850$"), "the guess's pay")
    assert_true(has_text(W, "^Forever Thing$"), "its name")
    assert_true(has_text(W, "^~ estimated"), "and what ~ means")
    W.cursor = { x = -3.4e38, y = -3.4e38 }   -- no cursor this frame
    W.frame()
    assert_true(not has_text(W, "Forever Thing"), "no list")
end }

T[#T + 1] = { "bigger text, and a bar never narrower than its words", function()
    local W = world({ xp = 3800, max = 7600, level = 10, settings = { xpbar_width = 260, xpbar_text_size = 24 } })
    W.quest(9, 15, true, { name = "Ready One" })
    W.frame()
    local p = W.plates()
    assert_true(p[1].w > 260, "widened past the slider: " .. tostring(p[1].w))
    assert_eq(p[1].w, p[2].w, "both bars one width")
    assert_eq(p[1].h, W.M.layout(24).h, "taller for the text")
end }

T[#T + 1] = { "move the bars: a handle above each, the bar under it, kept once moving is off", function()
    local W = world({ xp = 3800, max = 7600, level = 10, settings = { xpbar_move = true } })
    W.frame()
    assert_eq(#W.windows, 2, "a handle each")
    assert_eq(W.windows[1].id, "xp_bar_ready_move", "the turn-ins handle")
    assert_eq(W.windows[1].title, "Drag to move: TURN-INS bar", "says what it is")
    local p = W.plates()
    assert_eq(W.windows[1].y, p[1].y - 24 - 2, "just above its bar")
    W.handles["xp_bar_ready_move"] = { x = 100, y = 200 }   -- dragged
    W.frame()
    assert_eq(W.plates()[1].x, 100, "the bar follows: x")
    assert_eq(W.plates()[1].y, 226, "and y, under the handle")
    W.settings.xpbar_move = false
    W.frame()
    assert_eq(#W.windows, 0, "no handles once moving is off")
    assert_eq(W.plates()[1].x, 100, "the bar stays where it was left")
    assert_eq(W.plates()[1].y, 226, "")
    assert_eq(W.store.data.pos.ready.y, 226, "kept in the store")
end }

T[#T + 1] = { "a sum past the level: where it takes you, and the strip under the bar", function()
    local W = world({ xp = 7000, max = 7600, level = 10 })
    W.quest(9, 15, true)     -- 1050: into 11
    W.frame()
    assert_true(has_text(W, "^%-> Level 11 %(5%%%)$"), "where it takes you")
    local strip = 0
    for _, r in ipairs(W.rects) do
        if r.h == 4 and r.col[1] == 246 and r.col[2] == 190 then strip = strip + 1 end
    end
    assert_eq(strip, 2, "a strip on each bar, 5% into 11: the log holds only that quest")
end }

T[#T + 1] = { "max level: no quest pay, the bar says so", function()
    local W = world({ xp = 0, max = 0, level = 60 })
    W.quest(9, 15, true)
    W.frame()
    assert_true(has_text(W, "^max level$"), "the top row")
    assert_true(has_text(W, "^Max level$"), "the bar")
    assert_eq(W.M.summary(true).ready.xp, 0, "nothing to add")
end }

T[#T + 1] = { "what was learned is kept for the next character", function()
    local store = { data = {}, touch = function() end }
    local A = world({ level = 12, store = store })
    A.turn_in(92000, 1000)
    local B = world({ level = 12, store = store })
    local xp, how = B.M.reward(92000, 12, 12)
    assert_eq(how, "learned", "the second character knows it")
    assert_eq(xp, 1000, "and its pay")
end }

return T

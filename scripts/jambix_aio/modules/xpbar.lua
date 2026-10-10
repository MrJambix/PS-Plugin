-- Jambix AIO / xpbar -- two experience bars on Forever's ESP (1.7.6).
--
-- The user, 2026-10-10: "on ESP for forever Write up a moveable EXP Bar that
-- show's Exp/hour counts how much EXP going to get and fills the bar once
-- completed quests are Turned in and one that does the same but for all
-- quests in my Questlog". Two bars, each with its own switch on the Forever
-- ESP page (esp/page_forever.lua, *Experience bars*):
--
--   TURN-INS   your experience, and in gold on top of it what the quests
--              you have finished will give when you hand them in
--   QUEST LOG  the same, then in blue what the rest of your log will give
--
-- DRAWN BY THE ESP, NOT AS WINDOWS. The first version was a pair of JCore
-- windows; the user: "Make it ESP not like a UI", "also more readable". Each
-- bar is now the ESP's own drawing on its HUD layer, under the ESP's switch
-- and toggle key: one dark plate (the ESP's pill, soft where JCore has
-- plate_2d), and on it, in text with a dark rim at `xpbar_text_size` (16):
--   top     TURN-INS  +1,350 XP  -> Level 19 (2%)             12.3k XP/hr
--   bar     your experience in purple, the quests' on top, the rested pool's
--           end in blue, tenths ticked; "18,500 / 19,400   95.4%" on it. A
--           sum past the level fills it, and a strip under it shows how far
--           into the next level the sum reaches.
--   bottom  what is in the sum                          Level in 1h 05m
-- The cursor on a bar lists its quests under it, each with its pay. Handing
-- a quest in fills the bar for real, and its gold goes.
--
-- MOVING THEM. The ESP cannot take the mouse from the game, and a drag the
-- game sees turns the camera and pins the cursor (the 1.12.0 snap-back). So
-- "Move the XP bars" (`xpbar_move`, off) puts a small JCore handle above each
-- bar while it is on; the bar follows its handle, and stays where it was left
-- (`pos` in the store) once the switch is off.
--
-- WHAT A QUEST PAYS. No client call says (core.quests has no reward reader,
-- and Forever's gamelua bridge is down), so, in this order:
--   table    modules/questxp_data.lua: QuestieDB's own quest xp table, the
--            one Questie's QuestXP reads (tools/jcheck/questxp_extract.js).
--            Exact for Classic's quests: the recorder's two QUEST_TURNED_IN
--            examples on Forever (244 -> 290, 65 -> 1350) are the table's.
--   learned  a quest the table lacks that you have handed in before (any
--            character): what it paid then.
--   guess    the rest -- Forever's own quests, ids past 90000 -- at what a
--            standard quest of its level pays (`typical`), shown with "~".
-- Then Questie's level penalty (cmangos'): full pay up to the quest's level
-- + 5, then 80, 60, 40, 20 and at last 10%, rounded as the server rounds.
-- And then what the game itself has been paying: every quest you hand in is
-- checked against its prediction. A table quest's ratio (paid / predicted,
-- the median of the last few in 6 h) multiplies every table and learned
-- quest once it is 4% or more off 1 -- an xp buff, a server rate. A guessed
-- quest's ratio, from 3 handed in, corrects every guess.
--
-- EXPERIENCE PER HOUR. Your experience is read twice a second
-- (core.character.get_xp and get_xp_max, the 2026-10-06 core; the player's
-- get_xp / get_max_xp otherwise). What it rises by -- across a level-up too
-- -- is the session's; the rate is what the last `xpbar_rate_minutes` (30)
-- gave, from the first minute on. The page's button starts it again.
--
-- Reads only: nothing here acts.

local XP_POLL = 0.5               -- s between reads of your experience
local SUMMARY_EVERY = 1.0         -- s between sums of the quest log
local MIN_RATE_SECONDS = 60       -- s of session before a rate is shown
local RATIO_TTL = 6 * 3600        -- s a turn-in's ratio is believed
local RATIO_KEEP = 7              -- ratios kept, of each kind
local GUESS_RATIO_MIN = 3         -- guessed quests handed in before their ratio is used
local MAX_LEVEL = 60
local TIP_ROWS = 12                -- quests listed under a bar, headings included
local HANDED_IN_HOLD = 10         -- s a quest just handed in is not summed (the log lags it)

-- What each level takes, 1 to 59 (Classic's; they sum to 4,084,700). The
-- level you are on is the game's own get_xp_max; this is for the levels a
-- sum runs into past it.
local XP_TO_LEVEL = {
    400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,
    8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
    25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
    50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,
    95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,
    153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800,
}

local COLOR = {
    plate      = { 12, 12, 16, 215 },    -- the ESP's pill backdrop
    plate_edge = { 60, 62, 78, 230 },
    track      = { 0, 0, 0, 185 },
    bar_edge   = { 0, 0, 0, 230 },
    xp         = { 128, 72, 220, 255 },  -- the game's purple
    xp_hi      = { 168, 120, 244, 255 },
    ready      = { 246, 190, 50, 255 },  -- gold: finished, to hand in
    ready_hi   = { 255, 222, 128, 255 },
    open       = { 58, 150, 226, 235 },  -- blue: still to do
    open_hi    = { 120, 190, 245, 235 },
    open_text  = { 110, 185, 250, 255 },
    rested     = { 100, 200, 255, 255 },
    tick       = { 0, 0, 0, 120 },
    text       = { 255, 255, 255, 255 },
    dim        = { 200, 202, 214, 255 },
    level      = { 120, 230, 150, 255 }, -- a sum that takes you to the next level
    rim        = { 0, 0, 0, 235 },
}

local WINDOWS = {
    { key = "ready", id = "xp_bar_ready", opt = "xpbar_ready", label = "TURN-INS", row = 0 },
    { key = "log", id = "xp_bar_log", opt = "xpbar_log", label = "QUEST LOG", row = 1 },
}

return function(P)
    local ctx, log = P.ctx, P.log
    local floor, max, min = math.floor, math.max, math.min

    local M = {}

    local function now() return core.time() end

    local function call(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function ask(obj, method)
        local fn = obj and obj[method]
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, obj)
        if ok then return v end
        return nil
    end

    local function trace(text)
        if ctx.emit then pcall(ctx.emit, "jcore.recorder.trace", "xp bar: " .. text) end
    end

    -- --- the table ---------------------------------------------------------------

    local DATA = nil
    local function data()
        if DATA == nil then
            local ok, d = pcall(function()
                if P.load then return P.load("modules/questxp_data") end
                return require("jambix_aio/modules/questxp_data")
            end)
            DATA = (ok and type(d) == "table" and type(d.xp) == "table") and d or false
            if not DATA then log.once("warn", "xpbar_data", "XP bars: no quest xp table; every quest is a guess") end
        end
        return DATA or nil
    end

    -- --- what was learned, kept for every character ------------------------------

    local store = ctx.store and ctx.store("xpbar") or nil
    local saved = store and store.data or {}
    saved.learned = type(saved.learned) == "table" and saved.learned or {}
    saved.ratios = type(saved.ratios) == "table" and saved.ratios or {}
    saved.guess_ratios = type(saved.guess_ratios) == "table" and saved.guess_ratios or {}
    local function touch() if store then store:touch() end end

    local function push_ratio(list, r)
        list[#list + 1] = { r = r, at = floor(now()) }
        while #list > RATIO_KEEP do table.remove(list, 1) end
        touch()
    end

    --- The median of the ratios still believed, and how many there are.
    local function median_ratio(list, ttl)
        local t, vals = now(), {}
        for i = 1, #list do
            local e = list[i]
            if type(e) == "table" and tonumber(e.r) and (not ttl or (t - (tonumber(e.at) or 0)) <= ttl) then
                vals[#vals + 1] = e.r
            end
        end
        if #vals == 0 then return nil, 0 end
        table.sort(vals)
        return vals[floor((#vals + 1) / 2)], #vals
    end

    --- What the game has been paying for table quests against the table.
    local function game_rate()
        local r = median_ratio(saved.ratios, RATIO_TTL)
        if not r or math.abs(r - 1) < 0.04 then return 1 end
        return math.max(0.25, math.min(4, r))
    end

    --- The correction every guess takes once a few guessed quests were handed in.
    local function guess_rate()
        local r, n = median_ratio(saved.guess_ratios, nil)
        if not r or n < GUESS_RATIO_MIN then return nil end
        return math.max(0.25, math.min(4, r))
    end

    -- --- what a quest pays --------------------------------------------------------

    --- The level penalty and the server's rounding (Questie's getAdjustedXP,
    --- from cmangos).
    local function adjusted(base, qlevel, plevel)
        local mult = 2 * (qlevel - plevel) + 20
        if mult < 1 then mult = 1 elseif mult > 10 then mult = 10 end
        local xp = base * mult / 10
        if xp <= 100 then xp = 5 * floor((xp + 2) / 5)
        elseif xp <= 500 then xp = 10 * floor((xp + 5) / 10)
        elseif xp <= 1000 then xp = 25 * floor((xp + 12) / 25)
        else xp = 50 * floor((xp + 25) / 50) end
        return xp, mult
    end
    M.adjusted = adjusted

    --- What a quest will pay you, and how that is known.
    ---@param qid integer
    ---@param qlevel integer|nil its level, from the log
    ---@param plevel integer your level
    ---@return integer xp
    ---@return string how "table", "learned", "guess" or "none"
    function M.reward(qid, qlevel, plevel)
        plevel = tonumber(plevel) or 0
        if plevel <= 0 then return 0, "none" end
        if plevel >= MAX_LEVEL then return 0, "none" end
        local d = data()
        local row = d and d.xp[qid]
        if row then
            local xp = adjusted(row[2], row[1], plevel)
            return floor(xp * game_rate()), "table"
        end
        qlevel = tonumber(qlevel)
        local l = saved.learned[tostring(qid)]
        if type(l) == "table" and tonumber(l.base) then
            local lv = qlevel or tonumber(l.level) or plevel
            return adjusted(l.base, lv, plevel), "learned"
        end
        if not qlevel or qlevel <= 0 then qlevel = plevel end
        local typical = d and d.typical and d.typical[math.max(1, math.min(MAX_LEVEL, qlevel))]
        if not typical then return 0, "none" end
        local xp = adjusted(typical, qlevel, plevel)
        local g = guess_rate()
        if g then
            xp = floor(xp * g)
        else
            xp = floor(xp * game_rate())
        end
        return xp, "guess"
    end

    -- --- your experience, and per hour ---------------------------------------------

    local me = { xp = nil, max = nil, level = nil, rested = nil, at = -1e9, how = nil }
    local session = { start = nil, gained = 0, samples = {} }
    local polled_at = -1e9
    local said_readers = false

    local function read_xp()
        local ch = type(core) == "table" and core.character or nil
        local xp = call(ch and ch.get_xp)
        local mx = call(ch and ch.get_xp_max)
        local how = "core.character"
        local player = P.units and P.units.player and P.units.player() or nil
        if type(xp) ~= "number" or type(mx) ~= "number" then
            xp, mx = ask(player, "get_xp"), ask(player, "get_max_xp")
            how = "the player's get_xp"
        end
        local level = ask(player, "get_level")
        local rested = call(ch and ch.get_rested_xp)
        if type(xp) ~= "number" or type(mx) ~= "number" then return nil end
        return xp, mx, tonumber(level), tonumber(rested), how
    end

    --- What a read rose by since the last one, and the level it says you
    --- are on. A level-up is the level going up or, where the level read
    --- lags, the level's need changing: it changes at nothing else. Classic
    --- has no experience loss, so a drop with neither is a bad read (false).
    local function gain_since(xp, mx, level)
        local ups = 0
        if level and me.level and level > me.level then
            ups = level - me.level
        elseif mx ~= me.max then
            ups = 1
        end
        if ups > 0 then
            local gain = max(0, (me.max or 0) - me.xp) + xp
            -- A sum that took two levels at once: the ones between, whole.
            local from = me.level
            if from then
                for lv = from + 1, from + ups - 1 do gain = gain + (XP_TO_LEVEL[lv] or 0) end
                -- Carried, so a level read that catches up later is not a second level-up.
                return gain, max(level or 0, from + ups)
            end
            return gain, level
        end
        if xp < me.xp then return false end
        return xp - me.xp, level or me.level
    end

    --- Reads your experience; what it rose by since the last read is the
    --- session's, a level-up included.
    function M.poll()
        local t = now()
        polled_at = t
        local xp, mx, level, rested, how = read_xp()
        if not xp then return end
        if not said_readers then
            said_readers = true
            trace(string.format("experience from %s: %s / %s at level %s", how, tostring(xp), tostring(mx),
                tostring(level)))
        end
        -- 0 needed is the cap, or a client that cannot answer (a loading
        -- screen): only the cap is believed.
        if mx <= 0 and (level or me.level or 0) < MAX_LEVEL then return end
        if not session.start then
            session.start = t
            session.samples = { { t = t, g = 0 } }
        elseif me.xp and mx > 0 then
            local gain, new_level = gain_since(xp, mx, level)
            if gain == false then return end
            level = new_level
            if gain > 0 then
                session.gained = session.gained + gain
                local s = session.samples
                s[#s + 1] = { t = t, g = session.gained }
                -- Kept: the window and one sample before it.
                local window = (tonumber(P.opt("xpbar_rate_minutes", 30)) or 30) * 60
                while #s > 2 and s[2].t < t - window - 60 do table.remove(s, 1) end
            end
        end
        me.xp, me.max, me.level, me.rested, me.at, me.how = xp, mx, level or me.level, rested, t, how
    end

    --- Experience per hour over the last `xpbar_rate_minutes`, or nil before
    --- the first minute.
    function M.rate()
        if not session.start then return nil end
        local t = now()
        local window = (tonumber(P.opt("xpbar_rate_minutes", 30)) or 30) * 60
        local from = max(session.start, t - window)
        local elapsed = t - from
        if (t - session.start) < MIN_RATE_SECONDS or elapsed <= 0 then return nil end
        local base = 0
        local s = session.samples
        for i = #s, 1, -1 do
            if s[i].t <= from then
                base = s[i].g
                break
            end
        end
        return (session.gained - base) / elapsed * 3600
    end

    --- Starts the session again: the rate and the total from now.
    function M.reset()
        session.start, session.gained, session.samples = nil, 0, {}
        me.xp = nil
        M.poll()
    end

    -- --- the quests and their sums -------------------------------------------------

    local levels_seen = {}            -- quest id -> its level, from the log
    local handed_in = {}              -- quest id -> when QUEST_TURNED_IN said so
    local summary, summed_at = nil, -1e9

    --- The quests in your log: not offered by a guide, not failed, and not
    --- one just handed in. The index drops that on its next rebuild, up to a
    --- second later; till then its pay was in your experience and in the
    --- gold at once.
    local function log_rows()
        local idx = P.quests and P.quests.index or nil
        local out = {}
        if not (idx and type(idx.order) == "table" and type(idx.quests) == "table") then return out end
        local t = now()
        for i = 1, #idx.order do
            local q = idx.quests[idx.order[i]]
            local gone = q and handed_in[q.id] and (t - handed_in[q.id]) < HANDED_IN_HOLD
            if type(q) == "table" and tonumber(q.id) and not q.offered and not q.failed and not gone then
                out[#out + 1] = q
                if tonumber(q.level) then levels_seen[q.id] = tonumber(q.level) end
            end
        end
        return out
    end

    --- Where `add` more experience takes you from here.
    ---@return table { ups, xp, max, level, frac, capped }
    local function project(xp, mx, level, add)
        local have, need, lv, ups = xp + add, mx, level or 0, 0
        while need and need > 0 and have >= need and ups < 20 do
            have = have - need
            lv = lv + 1
            ups = ups + 1
            if lv >= MAX_LEVEL then
                return { ups = ups, xp = 0, max = 0, level = lv, frac = 1, capped = true }
            end
            need = XP_TO_LEVEL[lv]
        end
        if not need or need <= 0 then
            return { ups = ups, xp = have, max = 0, level = lv, frac = 1, capped = true }
        end
        return { ups = ups, xp = have, max = need, level = lv, frac = have / need }
    end
    M.project = project

    local function sum_quests()
        local plevel = me.level or 0
        local ready = { xp = 0, n = 0, guess = false, quests = {} }
        local open = { xp = 0, n = 0, guess = false, quests = {} }
        local rows = log_rows()
        for i = 1, #rows do
            local q = rows[i]
            local xp, how = M.reward(q.id, q.level, plevel)
            local into = q.complete and ready or open
            into.xp = into.xp + xp
            into.n = into.n + 1
            if how == "guess" then into.guess = true end
            into.quests[#into.quests + 1] = { id = q.id, name = q.name, xp = xp, how = how, level = q.level }
        end
        local function by_xp(a, b)
            if a.xp ~= b.xp then return a.xp > b.xp end
            return a.id < b.id
        end
        table.sort(ready.quests, by_xp)
        table.sort(open.quests, by_xp)
        return ready, open
    end

    --- Everything the bars show, worked out at most once a second.
    function M.summary(force)
        local t = now()
        if not force and summary and (t - summed_at) < SUMMARY_EVERY then return summary end
        summed_at = t
        local ready, open = sum_quests()
        local s = {
            xp = me.xp, max = me.max, level = me.level, rested = me.rested,
            known = me.xp ~= nil and me.max ~= nil,
            maxed = (me.level or 0) >= MAX_LEVEL or (me.xp ~= nil and (me.max or 0) <= 0),
            rate = M.rate(), gained = session.gained,
            ready = ready, open = open,
        }
        if s.known and not s.maxed then
            s.to_ready = project(me.xp, me.max, me.level, ready.xp)
            s.to_log = project(me.xp, me.max, me.level, ready.xp + open.xp)
            if s.rate and s.rate > 0 then s.level_in = (me.max - me.xp) / s.rate * 3600 end
        end
        summary = s
        return s
    end

    -- --- turn-ins: learning what the game pays ---------------------------------------

    local function on_turned_in(args)
        if type(args) ~= "table" then return end
        local qid, paid = tonumber(args[1]), tonumber(args[2])
        summed_at = -1e9
        if qid then handed_in[qid] = now() end
        if not qid or not paid or paid <= 0 then return end
        local plevel = me.level
        if not plevel or plevel <= 0 or plevel >= MAX_LEVEL then return end
        local d = data()
        local row = d and d.xp[qid]
        local qlevel = (row and row[1]) or levels_seen[qid]
        local said
        if row then
            local predicted = adjusted(row[2], row[1], plevel)
            if predicted >= 50 then
                local r = paid / predicted
                if r >= 0.2 and r <= 5 then push_ratio(saved.ratios, r) end
            end
            said = string.format("the table said %d", predicted)
        else
            local before, how_before = M.reward(qid, qlevel, plevel)
            local lv = qlevel or plevel
            local _, mult = adjusted(1000, lv, plevel)
            saved.learned[tostring(qid)] = { base = floor(paid * 10 / mult + 0.5), level = qlevel, paid = paid,
                at = floor(now()) }
            touch()
            -- How Forever's own quests compare with a standard one, for the
            -- guesses still to come; a quest already learned says nothing new.
            local typical = d and d.typical and d.typical[math.max(1, math.min(MAX_LEVEL, lv))]
            if typical and how_before == "guess" then
                local plain = adjusted(typical, lv, plevel)
                if plain >= 50 then
                    local r = paid / plain
                    if r >= 0.2 and r <= 5 then push_ratio(saved.guess_ratios, r) end
                end
            end
            said = string.format("%s %d, learned", how_before == "learned" and "had learned" or "guessed", before)
        end
        trace(string.format("quest %d handed in for %d xp at level %d (%s)", qid, paid, plevel, said))
    end

    if ctx.on then
        ctx.on("jcore.game_event.QUEST_TURNED_IN", function(args) pcall(on_turned_in, args) end)
        ctx.on("jcore.game_event.PLAYER_LEVEL_UP", function() summed_at = -1e9 end)
        ctx.on("jcore.game_event.QUEST_LOG_UPDATE", function() summed_at = -1e9 end)
    end

    -- --- drawing: the ESP's own, on its HUD layer -------------------------------------

    local function comma(n)
        local s = tostring(floor((tonumber(n) or 0) + 0.5))
        local sign, digits = s:match("^(%-?)(%d+)$")
        if not digits then return s end
        digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
        return sign .. digits
    end
    M.comma = comma

    local function short(n)
        n = tonumber(n) or 0
        if n >= 100000 then return string.format("%.0fk", n / 1000) end
        if n >= 1000 then return string.format("%.1fk", n / 1000) end
        return tostring(floor(n + 0.5))
    end
    M.short = short

    local function duration(sec)
        if not sec or sec ~= sec or sec < 0 or sec > 99 * 3600 then return nil end
        if sec < 60 then return "<1m" end
        local h, m = floor(sec / 3600), floor((sec % 3600) / 60)
        if h > 0 then return string.format("%dh %02dm", h, m) end
        return string.format("%dm", m)
    end
    M.duration = duration

    --- "+3,450 XP" or "+~3,450 XP" when a guess is in it.
    local function plus(xp, guess)
        return "+" .. (guess and "~" or "") .. comma(xp) .. " XP"
    end

    local draw = P.draw
    local layer = (ctx.LAYER and ctx.LAYER.HUD) or 300

    -- The palette as the draw calls want it, made once.
    local col = nil
    local function C(name)
        if not col then
            col = {}
            local make = P.color or function(r, g, b, a) return { r, g, b, a } end
            for k, v in pairs(COLOR) do col[k] = make(v[1], v[2], v[3], v[4]) end
        end
        return col[name]
    end

    local function width_of(s, size)
        if draw and draw.measure then
            local ok, w = pcall(draw.measure, s, size)
            if ok and tonumber(w) then return w end
        end
        return #s * size * 0.55
    end

    -- Text with a dark rim all round: readable on the bar's colours and on
    -- anything bright behind the plate.
    local RIM = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { 1, 1 } }
    local function text(x, y, s, c, size, align)
        local centered = align == "center"
        if align == "right" then x = x - width_of(s, size) end
        local rim = C("rim")
        for i = 1, #RIM do
            draw.text_2d({ x = x + RIM[i][1], y = y + RIM[i][2] }, s, rim,
                { size = size, centered = centered, layer = layer })
        end
        draw.text_2d({ x = x, y = y }, s, c, { size = size, centered = centered, layer = layer })
        return width_of(s, size)
    end

    local function fill(x, y, w, h, c, round)
        if w < 1 or h < 1 then return end
        draw.rect_2d({ x = x, y = y }, w, h, c, { filled = true, rounding = round or 0, layer = layer })
    end

    local function outline(x, y, w, h, c, round)
        draw.rect_2d({ x = x, y = y }, w, h, c, { thickness = 1.5, rounding = round or 0, layer = layer })
    end

    --- The ESP's pill backdrop: a soft plate where JCore has one and the
    --- ESP's soft look is on, else its flat one.
    local function plate(x, y, w, h)
        if draw.plate_2d and P.opt("esp_shader_look", true) ~= false then
            local ok = pcall(draw.plate_2d, { x = x, y = y }, w, h, C("plate"),
                { rounding = 6, border = C("plate_edge"), shadow = false, layer = layer })
            if ok then return end
        end
        fill(x, y, w, h, C("plate"), 6)
        outline(x, y, w, h, C("plate_edge"), 6)
    end

    --- A stretch of the bar, with a lighter band along its top: the ESP's
    --- shaded bars.
    local function segment(x, y, w, h, base, top)
        fill(x, y, w, h, C(base), 0)
        fill(x, y, w, floor(h * 0.4), C(top), 0)
    end

    --- Where everything in a bar's block sits, for a text size.
    local function layout(size)
        local small = max(9, size - 3)
        local pad = max(5, floor(size * 0.5))
        local L = { size = size, small = small, pad = pad }
        L.top_h = size + 2
        L.bar_h = size + 10
        L.strip_h = 4
        L.bottom_h = small + 2
        L.h = pad + L.top_h + 4 + L.bar_h + 3 + L.strip_h + 4 + L.bottom_h + pad
        return L
    end
    M.layout = layout

    local function where_to(p)
        if not p then return nil, nil end
        if p.capped then return "-> max level", "level" end
        if p.ups > 0 then return string.format("-> Level %d (%d%%)", p.level, floor(p.frac * 100)), "level" end
        return string.format("-> %.1f%%", p.frac * 100), "dim"
    end

    --- A bar's words, before anything is placed: the top row's pieces
    --- (text, colour), its right end, the bottom row and its right end.
    local function words(w, s)
        local b = { top = {}, p = nil }
        local add, guess
        if w.key == "ready" then
            add, guess, b.p = s.ready.xp, s.ready.guess, s.to_ready
        else
            add, guess, b.p = s.ready.xp + s.open.xp, s.ready.guess or s.open.guess, s.to_log
        end
        b.top[1] = { w.label, w.key == "ready" and "ready" or "open_text" }
        if not s.known then
            b.top[2] = { "experience not read yet", "dim" }
            return b
        end
        if s.maxed then
            b.top[2] = { "max level", "dim" }
            return b
        end
        b.top[2] = { plus(add, guess), "text" }
        local to, tone = where_to(b.p)
        if to and add > 0 then b.top[3] = { to, tone } end
        b.right = s.rate and (short(s.rate) .. " XP/hr") or "-- XP/hr"
        local r, o = s.ready, s.open
        if w.key == "ready" then
            b.low = r.n == 0 and "No finished quests to hand in"
                or string.format("%d finished quest%s to hand in", r.n, r.n == 1 and "" or "s")
        else
            b.low = (r.n + o.n) == 0 and "Your quest log is empty"
                or string.format("%d finished %s   |   %d to do %s", r.n, plus(r.xp, r.guess), o.n,
                    plus(o.xp, o.guess))
        end
        local eta = duration(s.level_in)
        if eta then b.low_right = "Level in " .. eta end
        return b
    end

    --- How wide a plate the words need: nothing overlaps at any text size.
    local function need_width(b, L)
        local gap = floor(L.size * 0.6)
        local top = 0
        for i = 1, #b.top do top = top + width_of(b.top[i][1], L.size) + (i > 1 and gap or 0) end
        if b.right then top = top + gap * 2 + width_of(b.right, L.size) end
        local low = b.low and width_of(b.low, L.small) or 0
        if b.low_right then low = low + gap * 2 + width_of(b.low_right, L.small) end
        return floor(max(top, low) + L.pad * 2 + 0.5)
    end
    M.need_width = need_width

    local function paint(w, s, b, x, y, W, L)
        plate(x, y, W, L.h)
        local size, small, pad = L.size, L.small, L.pad
        local inner = W - pad * 2
        local tx, ty = x + pad, y + pad
        local gap = floor(size * 0.6)
        local p = b.p

        -- Top row: what the bar is, what its quests add and where to; the rate.
        local cx = tx
        for i = 1, #b.top do
            cx = cx + text(cx, ty, b.top[i][1], C(b.top[i][2]), size) + gap
        end
        if b.right then text(x + W - pad, ty, b.right, C("dim"), size, "right") end

        -- The bar.
        local by = ty + L.top_h + 4
        local bh = L.bar_h
        fill(tx, by, inner, bh, C("track"), 4)
        if s.known and s.maxed then
            segment(tx, by, inner, bh, "xp", "xp_hi")
        elseif s.known then
            local mx = max(1, s.max)
            local function x_of(v) return floor(inner * min(1, max(0, v / mx)) + 0.5) end
            local x0 = x_of(s.xp)
            segment(tx, by, x0, bh, "xp", "xp_hi")
            local at = s.xp
            local function stretch(v, base, top)
                if v <= 0 then return end
                local a, e = x_of(at), x_of(at + v)
                segment(tx + a, by, e - a, bh, base, top)
                at = at + v
            end
            stretch(s.ready.xp, "ready", "ready_hi")
            if w.key == "log" then stretch(s.open.xp, "open", "open_hi") end
            if s.rested and s.rested > 0 then
                local rx = x_of(s.xp + s.rested)
                if rx < inner then fill(tx + rx - 1, by, 3, bh, C("rested"), 0) end
            end
            for i = 1, 9 do
                local gx = tx + floor(inner * i / 10)
                fill(gx, by + 3, 1, bh - 6, C("tick"), 0)
            end
            -- Past the level: how far into the next, on a strip under the bar.
            if p and p.ups > 0 then
                local sy = by + bh + 3
                fill(tx, sy, inner, L.strip_h, C("track"), 2)
                local last = (w.key == "log" and s.open.xp > 0) and "open" or "ready"
                fill(tx, sy, floor(inner * min(1, p.frac) + 0.5), L.strip_h, C(last), 2)
            end
        end
        outline(tx, by, inner, bh, C("bar_edge"), 4)
        local mid = by + floor((bh - size) / 2) - 1
        if s.known and not s.maxed then
            text(tx + inner / 2, mid,
                string.format("%s / %s   %.1f%%", comma(s.xp), comma(s.max), s.xp / max(1, s.max) * 100),
                C("text"), size, "center")
        elseif s.maxed then
            text(tx + inner / 2, mid, "Max level", C("text"), size, "center")
        end

        -- Bottom row: what is in the sum; the time to the next level.
        local yb = by + bh + 3 + L.strip_h + 4
        if b.low then text(tx, yb, b.low, C("dim"), small) end
        if b.low_right then text(x + W - pad, yb, b.low_right, C("dim"), small, "right") end
    end

    --- The quests behind a bar, listed under it (over it near the bottom of
    --- the screen) while the cursor is on it.
    local function paint_list(w, s, x, y, W, L, sh)
        local rows = {}
        local function add(head, bucket, tone)
            if bucket.n == 0 then return end
            rows[#rows + 1] = { head = head }
            for i = 1, #bucket.quests do
                if #rows >= TIP_ROWS then break end
                local q = bucket.quests[i]
                rows[#rows + 1] = { xp = (q.how == "guess" and "~" or "") .. comma(q.xp), tone = tone,
                    name = tostring(q.name or ("Quest " .. q.id)), guess = q.how == "guess" }
            end
        end
        add("Finished, to hand in", s.ready, "ready")
        if w.key == "log" then add("Still to do", s.open, "open_text") end
        if #rows == 0 then return end
        local guess = false
        for i = 1, #rows do if rows[i].guess then guess = true end end
        if guess then rows[#rows + 1] = { note = "~ estimated: usual pay for its level, until handed in" } end
        local size, pad = L.small, L.pad
        local line_h = size + 5
        local h = pad * 2 + #rows * line_h
        local ly = y + L.h + 4
        if ly + h > sh then ly = y - h - 4 end
        plate(x, ly, W, h)
        local col_w = width_of("~00,000", size) + floor(size * 0.8)
        for i = 1, #rows do
            local r = rows[i]
            local ry = ly + pad + (i - 1) * line_h
            if r.head then
                text(x + pad, ry, r.head, C("dim"), size)
            elseif r.note then
                text(x + pad, ry, r.note, C("dim"), size)
            else
                text(x + pad + col_w, ry, r.xp, C(r.tone), size, "right")
                text(x + pad + col_w + floor(size * 0.6), ry, r.name, C("text"), size)
            end
        end
    end

    local shown = { ready = false, log = false }

    --- Where a bar sits: where it was put, or the default under the middle
    --- of the screen, kept on the screen.
    local function place(w, W, L, sw, sh)
        saved.pos = type(saved.pos) == "table" and saved.pos or {}
        local p = saved.pos[w.key]
        local x, y
        if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then
            x, y = p.x, p.y
        else
            x = floor(sw / 2 - W / 2)
            y = floor(sh * 0.66) + w.row * (L.h + 10)
        end
        x = max(0, min(sw - W, x))
        y = max(0, min(sh - L.h, y))
        return x, y
    end

    --- While "Move the XP bars" is on: a small JCore handle above each bar,
    --- dragged with the bar under it. A bar drawn by the ESP cannot take the
    --- mouse itself: only a JCore window keeps it from the game, which would
    --- turn the camera on the drag and pin the cursor where it was pressed.
    local function move_handle(w, x, y, W)
        local ui = ctx.ui
        if not (ui and ui.begin_window and ui.end_window) then return x, y end
        local th = 24
        if ui.metrics then
            local ok, m = pcall(ui.metrics, ui)
            if ok and type(m) == "table" and tonumber(m.title_h) then th = m.title_h end
        end
        local ok, _, win = pcall(ui.begin_window, ui, w.id .. "_move", {
            title = "Drag to move: " .. w.label .. " bar", x = x, y = y - th - 2, w = W, h = th,
            collapsible = false, closable = false, scroll = false,
        })
        pcall(ui.end_window, ui)
        if ok and type(win) == "table" and tonumber(win.x) and tonumber(win.y) then
            local nx, ny = floor(win.x + 0.5), floor(win.y + th + 2 + 0.5)
            local p = saved.pos[w.key]
            if not (type(p) == "table" and p.x == nx and p.y == ny) then
                saved.pos[w.key] = { x = nx, y = ny }
                touch()
            end
            return nx, ny
        end
        return x, y
    end

    local function cursor()
        local input = ctx.input
        if not (input and input.cursor_position) then return nil end
        local ok, pos = pcall(input.cursor_position)
        local px, py = ok and type(pos) == "table" and tonumber(pos.x), ok and type(pos) == "table" and tonumber(pos.y)
        -- A frame the client has no cursor for answers -FLT_MAX.
        if not px or not py or math.abs(px) > 1e6 or math.abs(py) > 1e6 then return nil end
        local over_ui = P.JCore and P.JCore.ui and P.JCore.ui.is_cursor_over_ui
        if over_ui then
            local ok2, yes = pcall(over_ui)
            if ok2 and yes then return nil end
        end
        return px, py
    end

    -- Read on its own timer, so the rate keeps counting with the bars hidden.
    if ctx.every then
        ctx.every(XP_POLL, function() pcall(M.poll) end)
    end

    --- Both bars, each while its switch is on.
    ---@param visible boolean|nil false while the ESP is hidden: main.lua
    --- passes its switch, its toggle key and "RestedXP guide only", as every
    --- ESP mark obeys. nil draws.
    function M.render(visible)
        if not ctx.every and (now() - polled_at) >= XP_POLL then pcall(M.poll) end
        shown.ready, shown.log = false, false
        if visible == false then return end
        if not (draw and draw.rect_2d and draw.text_2d) then return end
        local any = false
        for i = 1, #WINDOWS do
            if P.opt(WINDOWS[i].opt, true) then any = true end
        end
        if not any then return end

        local ok_s, s = pcall(M.summary)
        if not ok_s or type(s) ~= "table" then
            log.once("error", "xpbar_summary", "XP bars failed: " .. tostring(s))
            return
        end
        local sw, sh = 1920, 1080
        if draw.screen_size then
            local a, b = draw.screen_size()
            if a and a > 0 and b and b > 0 then sw, sh = a, b end
        end
        local L = layout(floor(tonumber(P.opt("xpbar_text_size", 16)) or 16))
        -- Both bars one width: the slider's, or wider when the words need it.
        local W = floor(tonumber(P.opt("xpbar_width", 460)) or 460)
        local built = {}
        for i = 1, #WINDOWS do
            local w = WINDOWS[i]
            if P.opt(w.opt, true) then
                local ok, b = pcall(words, w, s)
                if ok and type(b) == "table" then
                    built[w.key] = b
                    W = max(W, need_width(b, L))
                else
                    log.once("error", "xpbar_words_" .. w.key, "XP bar failed: " .. tostring(b))
                end
            end
        end
        W = min(W, sw)
        local moving = P.opt("xpbar_move", false) == true
        local mx, my = cursor()
        for i = 1, #WINDOWS do
            local w = WINDOWS[i]
            local b = built[w.key]
            if b then
                local x, y = place(w, W, L, sw, sh)
                if moving then x, y = move_handle(w, x, y, W) end
                local ok, err = pcall(paint, w, s, b, x, y, W, L)
                if ok then
                    shown[w.key] = true
                    if mx and mx >= x and mx <= x + W and my >= y and my <= y + L.h then
                        pcall(paint_list, w, s, x, y, W, L, sh)
                    end
                else
                    log.once("error", "xpbar_" .. w.key, "XP bar failed: " .. tostring(err))
                end
            end
        end
    end

    --- For the tests and the Debug page.
    function M.stats()
        local learned = 0
        for _ in pairs(saved.learned) do learned = learned + 1 end
        local d = data()
        return {
            xp = me.xp, max = me.max, level = me.level, how = me.how,
            gained = session.gained, rate = M.rate(),
            table_rows = d and d.count or 0, learned = learned,
            game_rate = game_rate(), guess_rate = guess_rate(),
            shown = { ready = shown.ready, log = shown.log },
            pos = saved.pos,
        }
    end

    return M
end

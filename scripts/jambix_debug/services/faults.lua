-- Jambix Debug / faults -- every error, every native that raised or went
-- nil, written down the moment it happens; and a black box for the crash
-- that leaves no report.
--
-- JAMBIX DEBUG 1.1.0 (with JCore 1.8.1). The user, 2026-10-11, after an
-- evening of crashes that each left only the "Fatal Error: Your game
-- crashed" popup and no report: "add to the Debug All Captures of anything
-- we running thats going Null, or Crashing us for any Error whatso ever and
-- log it on the hit so we can fix it/report it".
--
-- A factory of JCore's runtime, built by JCore's main.lua before the
-- recorder (see jambix_debug/main.lua). It listens on JCore's rt.faults,
-- which hands over:
--   ERROR      a job, timer, event handler or core stage that raised, any
--              plugin's or JCore's own, with the traceback, the locals of
--              the frame that raised and what was running
--   NATIVE     a native (core.* or a game object's method) that raised, even
--              when the caller's pcall swallowed it (the recorder's watch,
--              Forever only)
--   NULL       a native that answered nil after answering values before,
--              once per call site (the recorder's watch, Forever only)
--   SWALLOWED  an error JCore's cache.try swallowed
--   LOG        a warn or error line of JCore's log (every plugin's ctx.log)
-- and writes, at the next start:
--   CRASH      the last session ended without logging out: when, and what
--              was running, from the black box
--
-- ON THE HIT. The first time a fault is seen it is appended to the log at
-- once, in full; a repeat is counted, and written again at its 2nd, 10th,
-- 100th... hit. core.write_data_file appends, so a line written is a line
-- kept, even when the game dies the next moment.
--
-- THE BLACK BOX. A game killed outright runs no Lua: nothing can be written
-- after the fact. So the box writes AHEAD: at "Every pass" a line as each
-- of the loader's passes (update, render, window, menu, a spell-cast
-- callback) begins and ends; at "Every job" a line round every job, handler
-- and core stage too. At the next start the last session's lines are read
-- back: if that game is gone (core.time counts from the injection, so it
-- went back) and it never logged out, the passes still open at the end are
-- what was running when it died, and a CRASH entry says so. A context line
-- (zone, position, combat, target, units, fps) goes in once a second at
-- every level but Off. Two files in turn, BOX_LINES each, so the box never
-- grows. Its cost is measured: three seconds over BOX_BUDGET_MS a second
-- and it steps down a level, and says so in the log.
--
-- IN A GROUP OR AN INSTANCE (2026-10-12). The user: "Seems like in Dungeons
-- is when I'm getting Alot of Crash errors". That day's three deaths in the
-- world were Shadowfang Keep in combat (60-80 units), and a group in Redridge
-- twice (50-74 units). Every one of those sessions had stepped down to a line
-- a second within 30 s of loading (~530 writes, 64 ms a second), so no CRASH
-- entry could say what was running. Two things keep the passes marked now:
-- a pass with no job in it (pre_tick: a quarter of all the writes) is not
-- marked, since nothing of ours can crash there; and in a group or an
-- instance the box holds its level on BOX_COMPANY_BUDGET_MS, and goes back
-- up to it on the way in if it stepped down outside.
--
-- FILES (scripts_data/jcore/)
--   jambix.debug.faults.log            the log; past 2 MB moved to .prev.log at the start
--   jambix.debug.faults.summary.txt    this session's faults by count, rewritten every 30 s
--   jambix.debug.blackbox.1.txt / .2.txt   the black box, in turn

local FAULT_FILE = "jcore/jambix.debug.faults.log"
local FAULT_PREV = "jcore/jambix.debug.faults.prev.log"
local SUMMARY_FILE = "jcore/jambix.debug.faults.summary.txt"
local BOX_FILES = { "jcore/jambix.debug.blackbox.1.txt", "jcore/jambix.debug.blackbox.2.txt" }

local FAULT_FILE_MAX = 2 * 1024 * 1024
local BOX_LINES = 2000
local BOX_BUDGET_MS = 60          -- black box writes, ms a second, before it steps down
local BOX_COMPANY_BUDGET_MS = 120 -- the same in a group or an instance, where the crashes come
local BOX_OVER_SECONDS = 3
local CONTEXT_EVERY = 1.0
local SUMMARY_EVERY = 30
local MAX_KEYS = 2000             -- distinct faults kept
local RECENT = 40
local LAST_MARKS = 30             -- marks quoted in a CRASH entry
local LIVE_ROWS = 14

-- 1: off, 2: a context line a second, 3: every pass, 4: every job and handler.
local LEVEL_NAMES = { "Off", "Once a second (context only)", "Every pass: update, render, window (default)",
    "Every job and handler (heavy)" }
local LEVEL_WORDS = { "off", "second", "pass", "job" }
local DEFAULT_LEVEL = 3

-- Passes the scheduler runs: marked only while some job is registered on them.
local SCHEDULED_PASSES = { pre_tick = true, menu = true, control_panel = true }

-- The client's instance kinds, as a person says them.
local INSTANCE_WORDS = { party = "dungeon", raid = "raid", pvp = "battleground", arena = "arena", scenario = "scenario" }

local AGAIN_AT = { [2] = true, [10] = true, [100] = true, [1000] = true, [10000] = true, [100000] = true }

local KIND_WORD = {
    job = "ERROR", timer = "ERROR", event = "ERROR", stage = "ERROR",
    native = "NATIVE", null = "NULL", swallowed = "SWALLOWED", log = "LOG", crash = "CRASH",
}

--- A message's free-standing numbers blanked, so "12.5 yd" and "13 yd" are
--- one fault; a number after ':' (a file's line) is kept.
local function blank_numbers(s)
    return ((" " .. s):gsub("([^%w:%.])%-?%d+%.?%d*", "%1#"))
end

local function one_line(s, limit)
    s = tostring(s):gsub("[\r\n\t]+", " "):gsub("[^\32-\126]", "?")
    if #s > limit then s = s:sub(1, limit) .. "..." end
    return s
end

--- "@C:\...\scripts\jambix_aio\modules\esp\init.lua" -> "jambix_aio/modules/esp/init".
local function short_source(src)
    src = tostring(src or "?")
    local first = src:sub(1, 1)
    if first == "@" or first == "=" then src = src:sub(2) end
    src = src:gsub("\\", "/")
    local cut = src:lower():find("/scripts/", 1, true)
    if cut then
        src = src:sub(cut + 9)
    elseif src:find("/", 1, true) then
        src = src:match("([^/]+/[^/]+)$") or src
    end
    return (src:gsub("%.lua$", ""))
end

return function(rt)
    local M = { available = true }
    local log = rt.log.for_tag("JambixDebug/faults")

    -- The natives this writes and reads the clock with, kept before the
    -- recorder wraps them: the fault log's own calls are never watched.
    local raw = {
        time = core.time, cpu_time = core.cpu_time, delta_time = core.delta_time,
        get_local_time = core.get_local_time,
        get_game_version = core.get_game_version, get_exact_game_version = core.get_exact_game_version,
        read = core.read_data_file, write = core.write_data_file,
        create = core.create_data_file, folder = core.create_data_folder,
    }
    local function call(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end
    local function now() return tonumber(call(raw.time)) or 0 end
    local function clock_ms()
        local ns = tonumber(call(raw.cpu_time))
        if ns then return ns * 1e-6 end
        return now() * 1000
    end
    local function local_time()
        local t = call(raw.get_local_time)
        if type(t) ~= "table" then return nil end
        return t
    end
    local function stamp()
        local t = local_time()
        if not t then return "??:??:??" end
        return string.format("%02d:%02d:%02d", tonumber(t.hour) or 0, tonumber(t.minute) or 0, tonumber(t.second) or 0)
    end
    local function date_stamp()
        local t = local_time()
        if not t then return "????-??-?? ??:??:??" end
        return string.format("%04d-%02d-%02d %02d:%02d:%02d", tonumber(t.year) or 0, tonumber(t.month) or 0,
            tonumber(t.day) or 0, tonumber(t.hour) or 0, tonumber(t.minute) or 0, tonumber(t.second) or 0)
    end

    -- --- files ---------------------------------------------------------------

    local function read(file)
        local s = call(raw.read, file)
        return type(s) == "string" and s or nil
    end
    -- core.write_data_file APPENDS, and only to a file that exists.
    local function append(file, text) call(raw.write, file, text) end
    local function replace(file, text)
        call(raw.create, file)
        if text ~= "" then call(raw.write, file, text) end
    end
    local function ensure(file)
        local s = read(file)
        if s == nil or s == "" then call(raw.create, file) end
    end

    call(raw.folder, "jcore")

    local started = now()
    local started_stamp = date_stamp()
    local version = tostring(call(raw.get_game_version) or "?")
    local exact = tostring(call(raw.get_exact_game_version) or "?")

    -- --- labels ----------------------------------------------------------------

    local getinfo = type(debug) == "table" and type(debug.getinfo) == "function" and debug.getinfo or nil
    local labels = setmetatable({}, { __mode = "k" })

    local function fn_site(fn)
        if not getinfo or type(fn) ~= "function" then return "?" end
        local ok, info = pcall(getinfo, fn, "S")
        if not ok or type(info) ~= "table" then return "?" end
        if info.what == "C" then return "a native" end
        return short_source(info.source or info.short_src) .. ":" .. tostring(info.linedefined or "?")
    end

    --- What ran: a scheduler job, a timer, an event subscription, a stage's
    --- name, a function (cache.try's). Kept per table.
    local function label_of(x)
        local tx = type(x)
        if tx == "string" then return x end
        if tx ~= "table" and tx ~= "function" then return tostring(x) end
        local l = labels[x]
        if l then return l end
        if tx == "function" then
            l = fn_site(x)
        elseif x.due ~= nil and x.fn then
            l = string.format("timer of %s at %s", tostring(x.owner), fn_site(x.fn))
        elseif x.event ~= nil and x.fn then
            l = string.format("handler of %s by %s at %s", tostring(x.event), tostring(x.owner), fn_site(x.fn))
        elseif x.priority ~= nil and x.fn then
            l = string.format("%s job of %s (priority %s) at %s", tostring(x.phase), tostring(x.owner),
                tostring(x.priority), fn_site(x.fn))
        else
            l = tostring(x)
        end
        labels[x] = l
        return l
    end
    M.label_of = label_of

    -- --- what is running, and the black box ---------------------------------------

    local level = DEFAULT_LEVEL
    local chosen = DEFAULT_LEVEL    -- the page's level; `level` is below it after a step down
    local stack, depth = {}, 0
    local unmarked = {}             -- pass label -> true while a pass left unmarked is open
    local frame = 0
    local seq = 0
    local box_i, box_lines = 1, 0
    local box = { ms = 0, writes = 0, last_ms = 0, last_writes = 0, window = now(), over = 0, stepped = nil,
        company = false }
    local last_context, context_text = -1e9, ""
    local quiet = false             -- this file's own reads: nothing they do is a fault
    -- The box's clock: core.time read once a frame, in the update pass, not
    -- once a line (the ESP's per-frame call budget counts core.time).
    local frame_t = now()

    local function running()
        if depth == 0 then return "between passes" end
        local parts = {}
        for i = 1, depth do parts[i] = label_of(stack[i]) end
        return table.concat(parts, " > ")
    end
    M.running = running

    local header_text

    local function box_write(text)
        seq = seq + 1
        local t0 = clock_ms()
        if box_lines >= BOX_LINES then
            -- The other file, emptied, starts again with the session's header,
            -- so either file read alone still says whose lines they are.
            box_i = 3 - box_i
            call(raw.create, BOX_FILES[box_i])
            box_lines = 0
            seq = seq + 1
            append(BOX_FILES[box_i], string.format("%d %.3f %s\n", seq - 1, frame_t, header_text))
        end
        append(BOX_FILES[box_i], string.format("%d %.3f %s\n", seq, frame_t, text))
        box_lines = box_lines + 1
        box.ms = box.ms + (clock_ms() - t0)
        box.writes = box.writes + 1
    end

    local function context()
        -- At the character select screen the map and zone natives read tables
        -- the game has not loaded yet, and that kills the client (2026-10-12):
        -- nothing is asked until JCore has seen the world.
        if rt.in_world and not rt.in_world() then return "the character screen (no world yet)" end
        local out = {}
        quiet = true
        pcall(function()
            local w = rt.world
            if w and w.map_name then
                local zone = w.map_name() or ""
                local inst = w.instance_name and w.instance_name() or ""
                out[#out + 1] = (zone ~= "" and zone or "?") .. ((inst ~= "" and inst ~= zone) and (" / " .. inst) or "")
            end
            local kind = w and w.instance_type and w.instance_type()
            if kind and kind ~= "none" and kind ~= "" then out[#out + 1] = INSTANCE_WORDS[kind] or tostring(kind) end
            local g = rt.group
            if g and g.in_group and g.in_group() then out[#out + 1] = "in a group" end
            local u = rt.units
            local p = u and u.player_position and u.player_position()
            if type(p) == "table" and p.x then
                out[#out + 1] = string.format("at %.1f, %.1f, %.1f", p.x, p.y or 0, p.z or 0)
            end
            local c = rt.combat
            if c and c.in_combat then out[#out + 1] = c.in_combat() and "in combat" or "out of combat" end
            local t = c and c.target and c.target()
            if t and u and u.name then out[#out + 1] = "target " .. tostring(u.name(t) or "?") end
            local s = u and u.stats and u.stats()
            if type(s) == "table" then
                out[#out + 1] = string.format("%d units (%d enemies, %d players)", s.units or 0, s.enemies or 0, s.players or 0)
            end
            local dt = tonumber(call(raw.delta_time))
            if dt and dt > 0 then out[#out + 1] = string.format("%.0f fps", 1 / dt) end
        end)
        quiet = false
        return table.concat(out, ", ")
    end

    local fault_line   -- forward: the log's own line, below

    local function apply_level(n)
        level = n
        if rt.faults then rt.faults.deep = (n >= 4) end
        if n >= 2 then box_write("L " .. LEVEL_WORDS[n]) end
    end

    --- The page's level: the one the box steps down from, and back up to.
    local function set_level(n)
        n = math.max(1, math.min(4, math.floor(tonumber(n) or DEFAULT_LEVEL)))
        chosen = n
        box.over, box.stepped = 0, nil
        apply_level(n)
    end

    --- In a group or an instance, where the crashes come; and the words for
    --- the log ("in a dungeon", "in a group").
    local function in_company()
        local yes, why = false, nil
        quiet = true
        pcall(function()
            local w = rt.world
            if w and w.in_instance and w.in_instance() then
                local word = INSTANCE_WORDS[w.instance_type()]
                yes = true
                why = word and ("in " .. (word:match("^[aeiou]") and "an " or "a ") .. word) or "in an instance"
                return
            end
            local g = rt.group
            if g and g.in_group and g.in_group() then yes, why = true, "in a group" end
        end)
        quiet = false
        return yes, why
    end

    --- Once a second, from the update pass: the context line, and the box's
    --- own cost against its budget (doubled in a group or an instance, and
    --- back up to the page's level on the way into one).
    local function each_second(t)
        if t - box.window >= 1 then
            box.last_ms, box.last_writes = box.ms, box.writes
            local company, why = false, nil
            if chosen >= 3 then company, why = in_company() end
            local budget = company and BOX_COMPANY_BUDGET_MS or BOX_BUDGET_MS
            -- Back up no higher than 'pass': 'job' wrote ~7000 lines a second
            -- in Shadowfang Keep (500+ ms), three seconds of stutter on every
            -- way in before it stepped down again (2026-10-12 15:31).
            local back_to = math.min(chosen, 3)
            if company and not box.company and level < back_to then
                box.over, box.stepped = 0, nil
                apply_level(back_to)
                fault_line(string.format("[%s +%.1fs] black box: %s; back to %s\n",
                    stamp(), t - started, why, LEVEL_WORDS[level]))
            elseif level >= 3 and box.ms > budget then
                box.over = box.over + 1
                if box.over >= BOX_OVER_SECONDS then
                    local was = level
                    box.over = 0
                    box.stepped = string.format("stepped down from %s (%.0f ms a second)", LEVEL_WORDS[was], box.ms)
                    apply_level(was - 1)
                    fault_line(string.format("[%s +%.1fs] black box: %d writes cost %.0f ms a second, over %d; now %s\n",
                        stamp(), t - started, box.writes, box.ms, budget, LEVEL_WORDS[level]))
                end
            else
                box.over = 0
            end
            box.company = company
            box.ms, box.writes, box.window = 0, 0, t
        end
        if level >= 2 and t - last_context >= CONTEXT_EVERY then
            last_context = t
            context_text = context()
            box_write("C " .. context_text)
        end
    end

    local listener = {}

    --- A scheduler pass with no job in it runs nothing of ours: no mark.
    local function worth_a_mark(label)
        if not SCHEDULED_PASSES[label] then return true end
        local s = rt.scheduler
        if not (s and s.has_jobs) then return true end
        return s.has_jobs(label)
    end

    function listener.enter(label)
        if label == "update" then
            -- The loader runs update from its own loop, never inside another
            -- pass: anything still open is a pass that raised before its end.
            for i = depth, 1, -1 do stack[i] = nil end
            depth = 0
        end
        depth = depth + 1
        stack[depth] = label
        if depth == 1 and label == "update" then
            frame = frame + 1
            frame_t = now()
            each_second(frame_t)
        end
        if level >= 3 then
            -- Its leave follows the same choice, so no mark is left open.
            if worth_a_mark(label) then box_write("> " .. label_of(label)) else unmarked[label] = true end
        end
    end

    function listener.leave(label)
        if unmarked[label] then
            unmarked[label] = nil
        elseif level >= 3 then
            box_write("< " .. label_of(label))
        end
        -- Down to the matching mark, so one left open cannot shift the rest.
        for i = depth, 1, -1 do
            if stack[i] == label then
                for j = depth, i, -1 do stack[j] = nil end
                depth = i - 1
                return
            end
        end
    end

    -- --- the log ---------------------------------------------------------------------

    local rows = {}          -- key -> row
    local n_keys = 0
    local overflow = 0
    local recent = {}        -- rows, newest last
    local totals = { all = 0 }
    local summary_dirty, summary_at = false, now()
    local catching = true

    fault_line = function(text) append(FAULT_FILE, text) end

    local function touch(row)
        for i = #recent, 1, -1 do
            if recent[i] == row then
                table.remove(recent, i)
                break
            end
        end
        recent[#recent + 1] = row
        if #recent > RECENT then table.remove(recent, 1) end
    end

    local function indent(text, pad)
        return pad .. tostring(text):gsub("\n", "\n" .. pad)
    end

    --- "CRASH 1, ERROR 5, NULL 2": the counts by the word written in the log
    --- (a job's, a timer's and a handler's faults are all ERROR).
    local function by_word(counts)
        local words, list = {}, {}
        for kind, n in pairs(counts) do
            if kind ~= "all" then
                local w = KIND_WORD[kind] or string.upper(kind)
                words[w] = (words[w] or 0) + n
            end
        end
        for w, n in pairs(words) do list[#list + 1] = w .. " " .. n end
        table.sort(list)
        return #list > 0 and table.concat(list, ", ") or "none"
    end

    --- One fault. The first of its kind is written in full at once; a repeat
    --- is counted and written again at its 2nd, 10th, 100th... hit.
    local function hit(kind, who, message, detail)
        local t = now()
        totals.all = totals.all + 1
        totals[kind] = (totals[kind] or 0) + 1
        local word = KIND_WORD[kind] or string.upper(kind)
        message = tostring(message)
        local key = kind .. "|" .. who .. "|" .. blank_numbers(message:sub(1, 300))
        local row = rows[key]
        if row then
            row.count = row.count + 1
            row.last = t
            touch(row)
            if AGAIN_AT[row.count] then
                fault_line(string.format("[%s +%.1fs] again, x%d: %s #%d %s: %s\n", stamp(), t - started,
                    row.count, word, row.n, who, one_line(message, 160)))
            end
            summary_dirty = true
            return row
        end
        if n_keys >= MAX_KEYS then
            overflow = overflow + 1
            return nil
        end
        n_keys = n_keys + 1
        row = { key = key, kind = kind, word = word, who = who, message = message, count = 1, first = t, last = t, n = n_keys }
        rows[key] = row
        touch(row)
        summary_dirty = true

        local lines = {}
        lines[#lines + 1] = string.format("[%s +%.1fs] %s #%d  %s", stamp(), t - started, word, row.n, who)
        lines[#lines + 1] = indent(one_line(message, 600), "  ")
        if detail then detail(lines) end
        lines[#lines + 1] = "  running: " .. running() .. string.format("  (frame %d)", frame)
        local where = context()
        if where ~= "" then lines[#lines + 1] = "  where: " .. where end
        fault_line(table.concat(lines, "\n") .. "\n\n")
        return row
    end

    function listener.fault(kind, who, err, trace, locals, at, log_level)
        if not catching or quiet then return end
        local who_text = label_of(who)
        if kind == "log" then who_text = string.format("log [%s] %s", tostring(who), tostring(log_level or "")) end
        hit(kind, who_text, err, function(lines)
            if at then lines[#lines + 1] = "  raised at: " .. short_source(at) end
            if locals and locals ~= "" then lines[#lines + 1] = "  locals: " .. locals end
            if trace then lines[#lines + 1] = indent(trace, "    ") end
        end)
    end

    function listener.native(key, err, site)
        if not catching or quiet then return end
        hit("native", tostring(key) .. " called by " .. tostring(site), err, nil)
    end

    function listener.null(key, site, count)
        if not catching or quiet then return end
        hit("null", tostring(key) .. " called by " .. tostring(site),
            string.format("answered nil after answering values before (nil #%d of this call)", tonumber(count) or 0), nil)
    end

    -- --- the summary ------------------------------------------------------------------

    function M.write_summary(force)
        if not force and not summary_dirty then return false end
        summary_dirty = false
        summary_at = now()
        local list = {}
        for _, row in pairs(rows) do list[#list + 1] = row end
        table.sort(list, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.n < b.n
        end)
        local out = {}
        out[#out + 1] = string.format("Jambix Debug fault summary -- session from %s, written %s (%.0f s in)",
            started_stamp, date_stamp(), now() - started)
        out[#out + 1] = string.format("%d faults, %d distinct%s. Full entries in scripts_data/%s.",
            totals.all, n_keys, overflow > 0 and string.format(" (+%d past the cap)", overflow) or "", FAULT_FILE)
        out[#out + 1] = "by kind: " .. by_word(totals)
        out[#out + 1] = ""
        out[#out + 1] = "  count  kind       #   who / what"
        for i = 1, #list do
            local r = list[i]
            out[#out + 1] = string.format("%7d  %-9s %3d  %s", r.count, r.word, r.n, r.who)
            out[#out + 1] = "                       " .. one_line(r.message, 220)
        end
        local rec = rt.recorder
        if rec and rec.watch_stats then
            local ok, w = pcall(rec.watch_stats, 15)
            if ok and type(w) == "table" then
                out[#out + 1] = ""
                out[#out + 1] = string.format("The native watch (%s): %d raises, %d nils after values.",
                    w.watching and "on" or "off", w.raised or 0, w.nulls or 0)
                for i = 1, #(w.top_nulls or {}) do
                    local n = w.top_nulls[i]
                    out[#out + 1] = string.format("  nil x%d  %s  <- %s", n.count, n.key, table.concat(n.sites or {}, "; "))
                end
                for i = 1, #(w.top_raised or {}) do
                    local r = w.top_raised[i]
                    out[#out + 1] = string.format("  raised x%d  %s", r.count, r.key)
                end
            end
        end
        out[#out + 1] = ""
        out[#out + 1] = string.format("black box: %s, %d writes and %.1f ms in the last second%s",
            LEVEL_WORDS[level], box.last_writes, box.last_ms, box.stepped and ("; " .. box.stepped) or "")
        replace(SUMMARY_FILE, table.concat(out, "\n") .. "\n")
        return true
    end

    -- --- the last session, from the black box ----------------------------------------

    --- Every line of both box files, oldest first.
    local function read_box()
        local lines = {}
        for i = 1, #BOX_FILES do
            local s = read(BOX_FILES[i])
            if s then
                for line in s:gmatch("[^\n]+") do
                    local n, t, text = line:match("^(%d+) (%-?[%d%.]+) (.*)$")
                    if n then lines[#lines + 1] = { seq = tonumber(n), t = tonumber(t), text = text, file = i } end
                end
            end
        end
        table.sort(lines, function(a, b) return a.seq < b.seq end)
        return lines
    end

    --- "21:47:59" plus `seconds`, as a clock time.
    local function clock_plus(hms, seconds)
        local h, m, s = tostring(hms or ""):match("(%d+):(%d+):(%d+)")
        if not h then return "?" end
        local total = (tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + math.floor(seconds + 0.5)) % 86400
        return string.format("%02d:%02d:%02d", math.floor(total / 3600), math.floor(total / 60) % 60, total % 60)
    end

    --- What the box says about the session before this one: nil when there
    --- is none, else { died = bool, reloaded = bool, ... } (the tests read it).
    local function judge_previous(lines, t_now)
        if #lines == 0 then return nil end
        local first = nil
        for i = #lines, 1, -1 do
            if lines[i].text:sub(1, 2) == "S " then
                first = i
                break
            end
        end
        if not first then return nil end
        -- The header is repeated when the box turns to its other file: the
        -- session began at the earliest header with the same start.
        local head = lines[first]
        local start_t = tonumber(head.text:match("start=(%-?[%d%.]+)"))
        for i = first - 1, 1, -1 do
            local l = lines[i]
            if l.text:sub(1, 2) == "S " and tonumber(l.text:match("start=(%-?[%d%.]+)")) == start_t then first = i end
        end
        head = lines[first]
        local last = lines[#lines]
        local out = {
            header = head.text,
            began = head.text:match("^S %d+%-%d+%-%d+ (%d+:%d+:%d+)") or "?",
            start_t = start_t or head.t,
            last_t = last.t,
            last_text = last.text,
            logged_out = last.text:sub(1, 2) == "X ",
        }
        out.same_game = t_now + 0.5 >= last.t
        out.died = not out.logged_out and not out.same_game
        out.reloaded = not out.logged_out and out.same_game
        -- The passes still open at the end: what was running. And the box's
        -- level then: an "L" line is written at every change, so with none
        -- the session never left the level it started at, the default.
        local open = {}
        local context_line, marks = nil, {}
        local box_level = LEVEL_WORDS[DEFAULT_LEVEL]
        for i = first, #lines do
            local text = lines[i].text
            local lead = text:sub(1, 2)
            if lead == "L " then
                box_level = text:sub(3)
                -- Below 'pass' no mark closes what is open: it says nothing more.
                if box_level ~= "pass" and box_level ~= "job" then open = {} end
            elseif lead == "> " then
                local label = text:sub(3)
                if label == "update" then open = {} end
                open[#open + 1] = label
            elseif lead == "< " then
                local label = text:sub(3)
                for j = #open, 1, -1 do
                    if open[j] == label then
                        for k = #open, j, -1 do open[k] = nil end
                        break
                    end
                end
            elseif lead == "C " then
                context_line = text:sub(3)
            end
            if lead == "> " or lead == "< " or lead == "C " or lead == "E " or lead == "W " or lead == "L " then
                marks[#marks + 1] = string.format("%9.3f %s", lines[i].t - (out.start_t or 0), text)
                if #marks > LAST_MARKS then table.remove(marks, 1) end
            end
        end
        out.open = open
        out.box_level = box_level
        out.context = context_line
        out.marks = marks
        out.seconds = last.t - (out.start_t or last.t)
        out.died_at = clock_plus(out.began, out.seconds)
        return out
    end
    M._judge_previous = judge_previous

    --- What a judged session was running at its end, in words.
    ---@param p table judge_previous's answer
    ---@return string
    local function running_at_end(p)
        if #p.open > 0 then return table.concat(p.open, " > ") end
        if p.box_level ~= "pass" and p.box_level ~= "job" then
            return string.format("not known -- the black box was at '%s' then, which marks no pass", tostring(p.box_level))
        end
        return "nothing JCore runs -- between passes (a game event, the loader itself)"
    end
    M._running_at_end = running_at_end

    local previous = nil

    local function report_previous(p)
        if not p or not p.died then return end
        local lines = {}
        lines[#lines + 1] = string.format("[%s +0.0s] CRASH  the last session ended without logging out", stamp())
        lines[#lines + 1] = string.format("  The game died, or was closed, at about %s: %.0f s after the plugins loaded at %s.",
            p.died_at, p.seconds, p.began)
        lines[#lines + 1] = "  Running at the end: " .. running_at_end(p)
        if p.context then lines[#lines + 1] = "  Last context: " .. p.context end
        lines[#lines + 1] = "  Box header: " .. p.header
        lines[#lines + 1] = string.format("  The last %d marks (seconds after load):", #p.marks)
        for i = 1, #p.marks do lines[#lines + 1] = "    " .. p.marks[i] end
        fault_line(table.concat(lines, "\n") .. "\n\n")
        totals.crash = (totals.crash or 0) + 1
    end

    -- --- start ----------------------------------------------------------------------

    do
        local s = read(FAULT_FILE)
        if s and #s > FAULT_FILE_MAX then
            replace(FAULT_PREV, s)
            replace(FAULT_FILE, "")
        end
        ensure(FAULT_FILE)
        fault_line(string.format("%s\nSESSION %s  JCore %s  game %s (%s)  black box: %s\n%s\n\n",
            string.rep("=", 78), started_stamp, tostring(rt.VERSION), version, exact,
            LEVEL_WORDS[level], string.rep("=", 78)))

        local lines = read_box()
        previous = judge_previous(lines, started)
        report_previous(previous)
        -- The sequence goes on from the old lines, so the two files sort.
        for i = 1, #lines do
            if lines[i].seq > seq then seq = lines[i].seq end
        end
        -- This session starts in the file the old one did not end in.
        local last_file = #lines > 0 and lines[#lines].file or 2
        box_i = 3 - last_file
        call(raw.create, BOX_FILES[box_i])
        box_lines = 0
        header_text = string.format("S %s start=%.3f jcore=%s game=%s", started_stamp, started, tostring(rt.VERSION), exact)
        box_write(header_text)
        if rt.faults then
            rt.faults.listen(listener)
            rt.faults.deep = (level >= 4)
        end
    end

    -- --- switches -------------------------------------------------------------------

    local function set_catch(on)
        catching = on and true or false
    end

    local function set_watch(on)
        local rec = rt.recorder
        if rec and rec.set_watch then pcall(rec.set_watch, on and true or false) end
    end

    M.set_level = set_level
    M.set_catch = set_catch
    M.set_watch = set_watch
    function M.level() return level, LEVEL_WORDS[level] end
    function M.previous() return previous end
    function M.rows() return rows end

    function M.stats()
        local rec = rt.recorder
        local w = rec and rec.watch_stats and select(2, pcall(rec.watch_stats, 3)) or nil
        return {
            catching = catching, level = LEVEL_WORDS[level], faults = totals.all, distinct = n_keys,
            overflow = overflow, by_kind = totals, frame = frame,
            box_writes = box.last_writes, box_ms = box.last_ms, box_stepped = box.stepped,
            box_company = box.company, box_chosen = LEVEL_WORDS[chosen],
            watching = type(w) == "table" and w.watching or false,
            native_raised = type(w) == "table" and w.raised or 0, native_nulls = type(w) == "table" and w.nulls or 0,
            previous = previous, file = "scripts_data/" .. FAULT_FILE,
        }
    end

    --- Empties the fault log (the black box is kept).
    function M.clear()
        replace(FAULT_FILE, string.format("cleared %s\n\n", date_stamp()))
        rows, n_keys, overflow, recent = {}, 0, 0, {}
        totals = { all = 0 }
        summary_dirty = true
        M.write_summary(true)
    end

    -- Logging out is the clean end; leaving the world is a loading screen.
    local opts = { owner = "jambix_debug.faults", priority = -1000000 }
    rt.events.on("jcore.game_event.PLAYER_LOGOUT", function()
        if level >= 2 then box_write("X logged out") end
        M.write_summary(true)
    end, opts)
    rt.events.on("jcore.game_event.PLAYER_LEAVING_WORLD", function()
        if level >= 2 then box_write("W left the world (a loading screen or a logout)") end
    end, opts)
    rt.events.on("jcore.game_event.PLAYER_ENTERING_WORLD", function()
        if level >= 2 then box_write("E entered the world") end
    end, opts)
    -- JCore's world gate (1.8.1): loaded at the character screen, no pass
    -- runs until a character is in the world, so a box that ends on
    -- "G waiting" died before any of our passes ran.
    rt.events.on("jcore.world.waiting", function()
        if level >= 2 then box_write("G waiting for the world (the character screen)") end
    end, opts)
    rt.events.on("jcore.world.open", function()
        if level >= 2 then box_write("G in the world: the passes start") end
    end, opts)
    if rt.in_world and not rt.in_world() and level >= 2 then
        box_write("G waiting for the world (the character screen)")
    end
    rt.scheduler.every(SUMMARY_EVERY, function() M.write_summary(false) end, "jambix_debug.faults")

    -- Which plugins are running: they register after JCore is up, so a
    -- while later.
    rt.scheduler.after(10, function()
        local ok, list = pcall(rt.registry.list)
        if not ok or type(list) ~= "table" then return end
        local names = {}
        for i = 1, #list do names[#names + 1] = string.format("%s %s", tostring(list[i].name), tostring(list[i].version)) end
        fault_line(string.format("[%s +%.1fs] plugins: %s\n\n", stamp(), now() - started,
            #names > 0 and table.concat(names, ", ") or "none"))
    end, "jambix_debug.faults")

    -- --- menu page --------------------------------------------------------------------

    local function build_page()
        local page = rt.menu_ns.for_plugin("jambix_debug", "Faults", { path = { "Jambix Debug", "Faults" }, icon = "activity" })
        if not page.available then return page end

        local section = page:section("Catch every error", "list", { column = "left" })
        section:label("Every error any plugin's job, timer or handler raises, every native that raised or went nil, and every warn and error line, written to scripts_data/" .. FAULT_FILE .. " the moment it happens: the first of each in full (traceback, locals, what was running, where you were), repeats counted. After a crash, the next start writes what was running when the game died.")
        section:toggle("catch", "Catch errors", true)
        section:toggle("watch", "Watch every native call: raised, or went nil (Forever)", true)
        section:dropdown("box", "Crash black box", LEVEL_NAMES, DEFAULT_LEVEL)
        section:button("summary", "Write the summary now", { on_click = function() M.write_summary(true) end })
        section:button("clear", "Clear the fault log", { on_click = function() M.clear() end })

        page:on_change("catch", function(v) set_catch(v ~= false) end)
        page:on_change("watch", function(v) set_watch(v ~= false) end)
        page:on_change("box", function(v) set_level(v) end)
        set_catch(page:get_or("catch", true) ~= false)
        set_watch(page:get_or("watch", true) ~= false)
        local saved = tonumber(page:get_or("box", DEFAULT_LEVEL)) or DEFAULT_LEVEL
        if saved ~= level then set_level(saved) end

        page:live_lines(LIVE_ROWS, function()
            local s = M.stats()
            local out = {}
            out[#out + 1] = string.format("%s   %d faults (%d distinct) this session, frame %d",
                s.catching and "Catching" or "Not catching", s.faults, s.distinct, s.frame)
            out[#out + 1] = "by kind: " .. by_word(s.by_kind)
            out[#out + 1] = string.format("native watch: %s, %d raised, %d nil after values",
                s.watching and "on" or "off", s.native_raised, s.native_nulls)
            out[#out + 1] = string.format("black box: %s, %d writes, %.1f ms in the last second%s%s",
                s.level, s.box_writes, s.box_ms,
                s.box_company and string.format(" (group or instance: %d ms allowed)", BOX_COMPANY_BUDGET_MS) or "",
                s.box_stepped and ("; " .. s.box_stepped) or "")
            local p = s.previous
            if p and p.died then
                out[#out + 1] = string.format("last session DIED at about %s, running: %s", p.died_at, running_at_end(p))
            elseif p and p.logged_out then
                out[#out + 1] = "last session: logged out cleanly"
            elseif p and p.reloaded then
                out[#out + 1] = "last session: scripts reloaded in the same game"
            else
                out[#out + 1] = "last session: nothing in the black box"
            end
            out[#out + 1] = "log: " .. s.file
            for i = #recent, 1, -1 do
                if #out >= LIVE_ROWS then break end
                local r = recent[i]
                out[#out + 1] = string.format("  x%d %s #%d %s: %s", r.count, r.word, r.n, one_line(r.who, 70),
                    one_line(r.message, 90))
            end
            return out
        end)
        return page
    end

    local function page_when_ready()
        local page = build_page()
        if not page.available then
            rt.scheduler.after(2.0, function() build_page() end, "jambix_debug.faults")
        end
    end
    if rt.ready then
        page_when_ready()
    else
        rt.events.once("jcore.ready", page_when_ready, { owner = "jambix_debug.faults" })
    end

    log.fmt("info", "catching every fault into scripts_data/%s; black box %s%s", FAULT_FILE, LEVEL_WORDS[level],
        (previous and previous.died) and string.format("; the last session died at about %s", previous.died_at) or "")

    return M
end

-- Jambix Debug / recorder -- what the Forever client actually answers, written down.
--
-- JAMBIX DEBUG (1.0.0): moved here from JCore's services/recorder.lua with JCore
-- 1.7.0, so users do not get it. Still a factory of JCore's runtime, built by
-- JCore's main.lua when this plugin is there (see jambix_debug/main.lua). Its
-- page sits under "Jambix Debug" in the sidebar; its files stay in
-- scripts_data/jcore/, so the tools in tools/jcheck read them as before.
--
-- Depends on: util, json, log, events, scheduler, menu_ns (all built before
-- it). Reads nothing else at factory time.
--
-- FOREVER ONLY. On every other client the factory returns an inert stub: no
-- wrapper, no event subscription, no timer, no menu page, no file. Era runs
-- exactly the path it ran before this file existed (jcore_era_client_test and
-- jcore_recorder_test check that).
--
-- WHY
-- The .api stubs say per call what each client does ("VERSIONS: always nil on
-- Forever", "Forever unverified"), and most Forever notes were written from
-- the core's source, not from a running Forever client. This records what the
-- client really answers, so the notes and JCore's capability flags
-- (world.client()) can be fixed from evidence.
--
-- WHAT IT RECORDS (format 2, JCore 1.5.12): a foundation, one entry per
-- function, that only grows when something NEW is learned.
--   * functions every function on `core` and its namespaces (one level of
--               sub-namespace too: core.addons.questie.*), wrapped IN PLACE;
--               `methods` holds the game_object methods. Each entry has:
--                 kind      read, action, loader (the loader's own settings),
--                           file, net, paint or clock
--                 args, returns   the value kinds seen at each position
--                 answers   how often each answer shape came back
--                 examples  a few DISTINCT calls: arguments, answer, what
--                           triggered it, and for an action the events that
--                           followed it
--                 triggers  WHAT TRIGGERED IT: the phase (update, render,
--                           event NAME, recorder) and the call site
--                           (file:line, and the plugin line behind a JCore
--                           service), counted over the inspected calls
--                 effects   WHAT IT DOES, for an action: of its calls, how
--                           many were followed within EFFECT_WINDOW seconds
--                           by each game event
--                 origin    "C" for the client's own function, "Lua" for one
--                           a script defined on top of it
--               Counts add up. Examples, triggers and effects gain a row only
--               for something not seen before, so a call made a million times
--               costs the same few lines as one made ten times.
--   * events    every game event JCore forwards, with one example per
--               argument layout, and the actions called just before it (or
--               "unprompted": nothing was watching, so the game or the player
--               did it). The combat log is keyed by its sub-event
--               ("COMBAT_LOG_EVENT_UNFILTERED:SPELL_DAMAGE"). The spell-cast
--               callbacks too.
--   * surface   every function name the client exposes on `core`, so a call
--               the .api documents but the client lacks shows up as missing;
--               `coverage` counts per namespace what was ever called.
--   * sessions  what each session added, so one that learned nothing new
--               shows as such.
--
-- Written to scripts_data/jcore/jcore.recorder.json, and loaded back at the
-- next start, so sessions add up (a format 1 file is converted, not lost).
-- `node tools/jcheck/recorder_report.js` compares it with scripts/.api and
-- prints what to fix; `--md` writes the per-namespace reference.
--
-- COST
-- It has to come BEFORE every service that captures a native at build time
-- (cache.wrap_namespace in bridge keeps the function it was handed), which
-- is why main.lua builds it straight after the cache. Each wrapped call costs
-- one Lua call and a counter; an action's call also opens its effect window
-- (a few table writes). The first INSPECT_FIRST calls of each function and
-- every INSPECT_EVERY-th after that are inspected in full (pcall, argument
-- kinds, shape, and the trigger: a short walk up the Lua stack, when the
-- client exposes `debug`). Clocks, logging and the graphics primitives are
-- counted only. The wrappers never call a native themselves.
--
-- WHAT IT NEVER WRAPS
-- Anything the loader may attribute to a plugin by walking the Lua stack: the
-- native menu (core.menu, whose element ids are salted with the owning
-- plugin), core.get_owning_plugin_name, the register_* callbacks, and the
-- console log calls. A wrapper defined in this file would sit on that stack.

-- --- constants and pure helpers --------------------------------------------
--
-- Outside the factory: they read nothing and run nothing at load, and the
-- factory is close to Lua's limit of 200 locals in one function. Up here
-- they are upvalues, which do not count against it.
local FILE = "jcore/jcore.recorder.json"
local FORMAT = 2

local INSPECT_FIRST = 40      -- per function, per session
local INSPECT_EVERY = 97      -- prime, so a fixed per-frame loop does not alias
local MAX_SHAPES = 10         -- distinct answer shapes counted per function
local MAX_EXAMPLES = 8        -- distinct (arguments, answer shape) calls kept
local MAX_EXAMPLES_SHAPE = 12 -- room past that, only for an answer shape not seen yet
local MAX_TRIGGERS = 12       -- distinct triggers per function
local MAX_EFFECTS = 16        -- distinct events counted after one action
local MAX_THEN = 4            -- events written on one example
local MAX_ERRORS = 3          -- distinct error messages per function
local MAX_POSITIONS = 8       -- argument / answer positions typed
local MAX_RECORDS = 3000
local MAX_EVENTS = 600        -- event keys (combat log sub-events count)
local EVENT_LAYOUTS = 4
local MAX_CAUSES = 8          -- distinct actions counted before one event
local EFFECT_WINDOW = 2.0     -- seconds an action's call watches for events
local STACK_DEPTH = 16        -- frames walked to find a trigger
local SESSION_LOG = 30        -- sessions kept in the log
local MAX_OBJECT_TYPES = 8    -- metatables proxied for game_object methods
local ARG_TEXT = 120
local RET_TEXT = 200

-- The watch (Jambix Debug 1.1.0; see THE WATCH in the factory).
local WATCH_DISCOVER = 20      -- first answers of each function searched for game objects
local WATCH_RAISE_SITES = 200  -- raises per function whose call site is read
local NULL_SITES_FIRST = 20    -- nils per function whose call site is read, then every 1000th
local MAX_NULL_SITES = 6       -- distinct call sites handed over per function

local SAVE_CHECK = 15         -- seconds between save checks
local SAVE_DIRTY = 20         -- something new: save at most this often
local SAVE_COUNTS = 120       -- only counts moved: save this often

-- --- what is wrapped, and how -----------------------------------------

local NEVER_NAMESPACE = { menu = true }
local NEVER_TOP = { get_owning_plugin_name = true }
local COUNT_ONLY_TOP = {
    time = true, game_time = true, delta_time = true, cpu_time = true,
    cpu_ticks = true, cpu_ticks_per_second = true,
}

local function never_top(name)
    return NEVER_TOP[name] or name:find("^register_") ~= nil
        or name == "log" or name:find("^log_") ~= nil
end

--- How a function is recorded: "skip", "count" or "full".
local function mode_for(path, name)
    if path == "" then
        if never_top(name) then return "skip" end
        if COUNT_ONLY_TOP[name] then return "count" end
        return "full"
    end
    if path == "graphics" then
        -- The paint calls run thousands of times a frame and answer
        -- nothing worth reading; the readers are kept, the projection
        -- among them: every overlay mark stands on what w2s answers.
        if name:find("^get_") or name:find("^is_") or name:find("^load_")
            or name:find("^trace_") or name:find("^translate_") or name:find("^native_")
            or name == "w2s" or name == "world_to_screen" then
            return "full"
        end
        return "count"
    end
    return "full"
end

-- --- what a function is -----------------------------------------------
--
-- The kind decides how an entry is read back: an action gets effect
-- windows, a read gets its answers judged (always empty, notes to fix).
-- Decided from the name alone, conservatively: a getter filed as an action
-- only costs a window, an action filed as a getter would lose its effects.

local READ_PREFIXES = { "get_", "is_", "has_", "can_", "read_", "does_", "num_", "query_",
    "calculate_", "translate_", "scale_", "normalize_", "trace_", "native_", "cursor_has_",
    "spell_has_", "world_pos_", "ui_pos_", "load_" }
local READ_NAMES = { w2s = true, world_to_screen = true, node_name = true }
-- Top-level calls that act on the game rather than on the loader.
local GAME_TOP = { execute = true, play_sound_by_id = true, stop_sound_by_handle = true,
    reload_game_ui = true, write_cvar = true }
-- game_object methods are reads unless named like a command.
local METHOD_ACTIONS = { "set_", "use_", "cast_", "interact", "loot_", "select_", "cancel_", "stop_" }

local function has_prefix(name, list)
    for i = 1, #list do
        local p = list[i]
        if name:sub(1, #p) == p then return true end
    end
    return false
end

local function is_read_name(name)
    return READ_NAMES[name] == true or has_prefix(name, READ_PREFIXES)
end

local function kind_for(path, name, mode, method)
    if mode == "count" then return path == "graphics" and "paint" or "clock" end
    if method then return has_prefix(name, METHOD_ACTIONS) and "action" or "read" end
    if path == "" then
        if name:find("^http_") then return "net" end
        if GAME_TOP[name] then return "action" end
        if name:find("^create_") or name:find("^delete_") or name:find("^write_") then return "file" end
        if is_read_name(name) then return "read" end
        return "loader"
    end
    -- The graphics calls recorded in full are its readers and loaders.
    if path == "graphics" then return "read" end
    return is_read_name(name) and "read" or "action"
end

local getinfo = type(debug) == "table" and type(debug.getinfo) == "function" and debug.getinfo or nil
local PLUMBING = { ["jcore/lib/cache"] = true, ["jcore/services/bridge"] = true }

--- A value kind added to one position's set; true when it is new there.
local function add_kind(sets, i, k)
    local set = sets[i]
    if not set then
        set = {}
        sets[i] = set
    end
    if set[k] then return false end
    set[k] = true
    return true
end

local PHASES = { on_update = "update", on_pre_tick = "pre_tick", on_render = "render",
    on_render_menu = "menu", on_render_control_panel = "panel" }

local AURA_LEADS = { added = true, updated = true, removed = true }

--- The line with every free-standing number blanked: "d= 12.3" and
--- "drawn@1720,891" compare equal to the same line a frame later, while
--- a guid's digits (inside a word) are kept, so two units stay apart.
local function trace_key(text)
    return ((" " .. text):gsub("([^%w])%-?%d+%.?%d*%f[^%w]", "%1#"))
end

-- Written at the top of the file (the encoder sorts keys, and "_" sorts
-- first), so the file explains itself to whoever opens it.
local ABOUT = {
    what = "The Forever client's API as it was seen answering: one entry per function, merged across sessions. A row is added only for something new.",
    functions = "core functions by path (\"input.cast_target_spell\"); methods holds the game_object methods",
    kind = "read, action, loader (the loader's own settings), file, net, paint, clock (paint and clock are counted only)",
    status = "answers, always empty, only false, returns nothing, raises, answers (sometimes raises), not inspected",
    args_returns = "value kinds seen at each position: num, 0, str, \"\", true, false, nil, tbl, {}, obj, fn",
    answers = "how often each answer shape came back, over the inspected calls",
    examples = "distinct calls: call -> answer; by = what triggered it; then = the events that followed (actions)",
    triggers = "WHAT TRIGGERED IT: phase (update, render, menu, event NAME, on TOPIC, recorder, outside JCore) and call site file:line, with the plugin line behind a JCore service after <",
    effects = "WHAT IT DOES (actions): windows = calls watched for 2 s (cut short by the next call); each event = how many of those calls it followed",
    origin = "C = the client's own function, Lua = defined by a script on top of it",
    events = "layouts = one example per argument layout; after = actions called in the 2 s before; unprompted = no action was watching",
    coverage = "per namespace: functions the client exposes, and how many were ever called",
}

--- { "num", "obj|nil" } from the per-position kind sets.
local function kinds_list(sets)
    local out = {}
    for i = 1, #sets do
        local names = {}
        for k in pairs(sets[i] or {}) do names[#names + 1] = k end
        table.sort(names)
        out[i] = table.concat(names, "|")
    end
    return out
end

local function split_kinds(list, into)
    if type(list) ~= "table" then return end
    for i = 1, #list do
        local set = {}
        for k in tostring(list[i]):gmatch("[^|]+") do set[k] = true end
        into[i] = set
    end
end

local LIVE_ROWS = 10

return function(rt)
    local json = rt.json
    local log = rt.log.for_tag("JambixDebug/recorder")

    local M = {}

    -- Captured before anything is wrapped, so the recorder's own clock reads
    -- and file writes are never recorded as the game's.
    local raw = {
        time = core.time,
        get_game_version = core.get_game_version,
        get_exact_game_version = core.get_exact_game_version,
        get_local_time = core.get_local_time,
        read_data_file = core.read_data_file,
        write_data_file = core.write_data_file,
        create_data_file = core.create_data_file,
        create_data_folder = core.create_data_folder,
    }

    local function call_raw(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, result = pcall(fn, ...)
        if ok then return result end
        return nil
    end

    local version = tostring(call_raw(raw.get_game_version) or "")

    -- The gate, decided once. Everything below this line runs on Forever only.
    if version ~= "Forever" then
        M.available = false
        function M.active() return false end
        function M.stats() return { available = false, active = false, calls = 0, functions = 0, events = 0 } end
        function M.report() return nil end
        function M.save() return false end
        function M.clear() end
        function M.start() return false end
        function M.stop() end
        function M.trace() end
        function M.trace_lines() return {} end
        function M.set_watch() return false end
        function M.watching() return false end
        function M.watch_stats() return { watching = false, installed = false, raised = 0, nulls = 0, top_nulls = {}, top_raised = {} } end
        return M
    end

    M.available = true

    local now = function() return tonumber(call_raw(raw.time)) or 0 end

    -- --- state ------------------------------------------------------------

    local records = {}            -- key -> record
    local record_count = 0
    local events = {}             -- key -> event record
    local event_count = 0
    local surface = { core = {}, namespaces = {}, unwritable = {}, skipped = {} }
    local object_surface = { index = "unseen", methods = {} }

    local installed = {}          -- { target, key, original, wrapper }
    local proxied = {}            -- { mt, kind, original, entries }
    local seen_mt = setmetatable({}, { __mode = "k" })
    local proxied_types = 0

    local active = false
    -- THE WATCH (Jambix Debug 1.1.0). While on, the wrappers stay in place
    -- with recording stopped, and every call goes through a pcall: a native
    -- that raises is handed to JCore's rt.faults (and so to the fault log)
    -- even when the caller's own pcall swallows it, and one that answers nil
    -- after answering values before is handed over once per call site.
    -- One table: this factory is close to Lua's limit of 200 locals.
    local watch = { on = rt.faultlog ~= nil, installed = false, raised = 0, nulls = 0 }
    local dirty = false
    local counts_moved = false
    local last_save = 0
    local session_started = now()
    local sessions = 1
    local subscriptions = {}
    local timer_id = nil
    local save_error = nil
    local saved_at = nil

    local phase = nil             -- what JCore is running now: "update", "render", "event NAME", ...
    local recorder_busy = false   -- the recorder's own reads (catalog, probes), told apart
    local open_windows = {}       -- action key -> its effect window
    local hooked = {}             -- { target, key, original, wrapper }: the phase hooks
    local session_log = {}        -- earlier sessions' entries, from the file
    local session_begun = nil     -- local time this session started, rendered
    local learned = { functions = 0, examples = 0, triggers = 0, effects = 0, events = 0, layouts = 0 }

    -- --- rendering --------------------------------------------------------

    local function clean(s, limit)
        s = tostring(s)
        if #s > limit then s = s:sub(1, limit) .. "..." end
        -- Printable ASCII only: the file must stay valid JSON for node, and a
        -- binary read (a texture, an archive block) must not break it.
        return (s:gsub("[^\32-\126]", "?"))
    end

    --- True when v carries game_object methods (by its metatable, so a
    --- game object is recognised without calling anything on it).
    local function looks_like_object(v)
        local tv = type(v)
        if tv ~= "userdata" and tv ~= "table" then return false end
        local ok, mt = pcall(getmetatable, v)
        if not ok or type(mt) ~= "table" then return false end
        local idx = rawget(mt, "__index")
        local function has(name)
            if type(idx) == "table" then
                local okk, f = pcall(function() return idx[name] end)
                return okk and type(f) == "function"
            elseif type(idx) == "function" then
                local okk, f = pcall(idx, v, name)
                return okk and type(f) == "function"
            end
            return false
        end
        return has("get_health") and has("get_position")
    end

    --- One answer value, coarse: what the histogram counts.
    local function kind(v)
        local t = type(v)
        if t == "nil" then return "nil" end
        if t == "boolean" then return v and "true" or "false" end
        if t == "number" then return v == 0 and "0" or "num" end
        if t == "string" then return v == "" and "\"\"" or "str" end
        if t == "function" then return "fn" end
        if t == "table" then
            if looks_like_object(v) then return "obj" end
            if next(v) == nil then return "{}" end
            return "tbl"
        end
        if t == "userdata" then return looks_like_object(v) and "obj" or "ud" end
        return t
    end

    local function is_empty(v)
        if v == nil or v == false or v == 0 or v == "" then return true end
        return type(v) == "table" and next(v) == nil and getmetatable(v) == nil
    end

    local show

    local function show_table(t, depth)
        if depth >= 2 then return "{...}" end
        local first = rawget(t, 1)
        local n = 0
        for _ in pairs(t) do
            n = n + 1
            if n > 256 then break end
        end
        if n == 0 then return "{}" end
        if first ~= nil then
            local len = #t
            return "[" .. tostring(len) .. " x " .. show(first, depth + 1) .. "]"
        end
        local keys = {}
        for k in pairs(t) do
            keys[#keys + 1] = k
            if #keys >= 64 then break end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for i = 1, math.min(#keys, 10) do
            local k = keys[i]
            parts[#parts + 1] = tostring(k) .. "=" .. show(t[k], depth + 1)
        end
        if n > 10 then parts[#parts + 1] = "+" .. tostring(n - 10) end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    show = function(v, depth)
        depth = depth or 0
        local t = type(v)
        if t == "nil" then return "nil" end
        if t == "boolean" then return tostring(v) end
        if t == "number" then
            if v == math.floor(v) and v > -1e15 and v < 1e15 then
                return string.format("%.0f", v)
            end
            return string.format("%.4g", v)
        end
        if t == "string" then return "\"" .. clean(v, 48) .. "\"" end
        if t == "function" then return "fn" end
        if looks_like_object(v) then return "obj" end
        if t == "table" then
            local ok, text = pcall(show_table, v, depth)
            return ok and text or "{?}"
        end
        return t
    end

    local function pack(...)
        return { n = select("#", ...), ... }
    end

    --- `trim` drops trailing nils: the bridge pads every call to three
    --- arguments, and "(1, nil, nil)" says nothing "(1)" does not.
    local function show_list(list, from, limit, trim)
        local last = list.n
        if trim then
            while last >= from and list[last] == nil do last = last - 1 end
        end
        local parts = {}
        for i = from, last do
            parts[#parts + 1] = show(list[i])
        end
        return clean(table.concat(parts, ", "), limit)
    end

    local function shape_of(n, a, b, c)
        if n == 0 then return "none" end
        local s = kind(a)
        if n >= 2 then s = s .. "," .. kind(b) end
        if n >= 3 then s = s .. "," .. kind(c) end
        if n > 3 then s = s .. ",+" .. tostring(n - 3) end
        return s
    end

    -- --- what triggered a call -------------------------------------------
    --
    -- The phase comes from JCore's own dispatch: the scheduler's entry points
    -- and the event bus are hooked while recording (hook_phases, below). The
    -- call site needs the Lua stack, so it comes from debug.getinfo when the
    -- client exposes it, and is left out when it does not. The recorder's own
    -- frames and JCore's plumbing (the cache, the bridge) are stepped over:
    -- the site is the code that wanted the answer, and when that is a JCore
    -- service, the plugin line behind it is added.

    local skip_fn = setmetatable({}, { __mode = "k" })   -- the recorder's own frames
    local short_cache = {}
    local short_count = 0

    --- "@C:\...\scripts\jcore\services\units.lua" -> "jcore/services/units".
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
        return clean((src:gsub("%.lua$", "")), 80)
    end

    local function site_of(info)
        local src = info.source or info.short_src or "?"
        local s = short_cache[src]
        if not s then
            s = short_source(src)
            if short_count < 512 then
                short_cache[src] = s
                short_count = short_count + 1
            end
        end
        return s
    end

    --- "update jambix_aio/modules/rotation:412", or behind a JCore service
    --- "update jcore/services/spells:88 < jambix_aio/modules/rotation:412".
    local function trigger_text()
        if recorder_busy then return "recorder" end
        local when = phase or "outside JCore"
        if not getinfo then return when end
        local site, plugin
        for level = 2, STACK_DEPTH do
            local ok, info = pcall(getinfo, level, "Slf")
            if not ok or type(info) ~= "table" then break end
            -- A frame with no current line is native (pcall, the host): no site.
            if info.what ~= "C" and info.what ~= "tail" and (tonumber(info.currentline) or -1) >= 0
                and not (info.func and skip_fn[info.func]) then
                local s = site_of(info)
                if not PLUMBING[s] then
                    local here = s .. ":" .. tostring(info.currentline or "?")
                    local in_jcore = s:sub(1, 6) == "jcore/"
                    if not site then
                        site = here
                        if not in_jcore then break end
                    elseif not in_jcore then
                        plugin = here
                        break
                    end
                end
            end
        end
        if not site then return when end
        return when .. " " .. site .. (plugin and (" < " .. plugin) or "")
    end
    skip_fn[trigger_text] = true

    -- --- records ----------------------------------------------------------

    local function new_record(key, mode, method, kind_name)
        local rec = records[key]
        if rec then
            rec.mode = mode
            if kind_name then rec.kind = kind_name end
            return rec
        end
        if record_count >= MAX_RECORDS then return nil end
        rec = {
            key = key,
            mode = mode,
            kind = kind_name or "read",
            method = method or nil,
            calls = 0, session = 0, tallied = 0, empty = 0,
            inspected = 0, errors = 0,
            first_session = sessions, last_session = nil,
            args = {}, rets = {},
            shapes = {}, examples = {}, example_keys = {},
            triggers = {}, n_triggers = 0,
            effects = nil, n_effects = 0,
            error_samples = {},
            -- The watch (1.1.0): has it ever answered a value, nils after
            -- that, the sites they came from, raises.
            answered = false, watch_seen = 0, nulls = 0, raised = 0,
            null_sites = nil, n_null_sites = 0,
        }
        records[key] = rec
        record_count = record_count + 1
        return rec
    end

    local function count_shapes(rec)
        local n = 0
        for _ in pairs(rec.shapes) do n = n + 1 end
        return n
    end

    local function note_trigger(rec, trig)
        local n = rec.triggers[trig]
        if n then
            rec.triggers[trig] = n + 1
        elseif rec.n_triggers < MAX_TRIGGERS then
            rec.triggers[trig] = 1
            rec.n_triggers = rec.n_triggers + 1
            learned.triggers = learned.triggers + 1
            dirty = true
        else
            rec.triggers["(other)"] = (rec.triggers["(other)"] or 0) + 1
        end
    end

    -- --- what an action does ------------------------------------------------
    --
    -- An action's call opens a window; each game event that arrives in it is
    -- counted once against that call (effects) and the call against the event
    -- (events[...].after). The next call of the same action closes the
    -- window, so a call made every frame watches for a frame, not for
    -- EFFECT_WINDOW, and the counts read as "of N calls, M were followed by
    -- this event". The report weighs that against how often the event comes
    -- anyway.

    local function open_window(key, rec)
        local w = open_windows[key]
        if not w then
            w = { rec = rec, gen = 0, seen = {} }
            open_windows[key] = w
        end
        w.rec = rec
        w.gen = w.gen + 1
        w.t = now()
        w.ex = nil
        local eff = rec.effects
        if not eff then
            eff = { windows = 0 }
            rec.effects = eff
        end
        eff.windows = eff.windows + 1
    end

    --- One event against every open window. `e` is the event's record.
    local function note_effects(effect, e)
        local t = now()
        local any = false
        for key, w in pairs(open_windows) do
            if t - (w.t or -1e9) <= EFFECT_WINDOW then
                any = true
                if w.seen[effect] ~= w.gen then
                    w.seen[effect] = w.gen
                    local rec = w.rec
                    local eff = rec.effects
                    if eff[effect] then
                        eff[effect] = eff[effect] + 1
                    elseif rec.n_effects < MAX_EFFECTS then
                        eff[effect] = 1
                        rec.n_effects = rec.n_effects + 1
                        learned.effects = learned.effects + 1
                        dirty = true
                    end
                    local ex = w.ex
                    if ex then
                        local list = ex["then"]
                        if not list then
                            list = {}
                            ex["then"] = list
                        end
                        if #list < MAX_THEN then
                            list[#list + 1] = effect
                            dirty = true
                        end
                    end
                    if e then
                        if e.after[key] then
                            e.after[key] = e.after[key] + 1
                        elseif e.n_after < MAX_CAUSES then
                            e.after[key] = 1
                            e.n_after = e.n_after + 1
                            dirty = true
                        end
                    end
                end
            else
                w.ex = nil
            end
        end
        if e and not any then e.unprompted = e.unprompted + 1 end
    end

    local maybe_proxy -- forward: game_object metatables, below

    local function note_values(n, a, b, c)
        if n == 0 then return end
        -- Only the answer positions a list or an object can appear in.
        for i = 1, math.min(n, 3) do
            local v = (i == 1 and a) or (i == 2 and b) or c
            local tv = type(v)
            if tv == "userdata" then
                maybe_proxy(v)
            elseif tv == "table" then
                if looks_like_object(v) then
                    maybe_proxy(v)
                else
                    local first = rawget(v, 1)
                    if first ~= nil and (type(first) == "userdata" or type(first) == "table") then
                        if looks_like_object(first) then maybe_proxy(first) end
                        local obj = type(first) == "table" and rawget(first, "object")
                        if obj ~= nil and looks_like_object(obj) then maybe_proxy(obj) end
                    end
                end
            end
        end
    end

    -- --- the watch (1.1.0) ------------------------------------------------

    --- A native raised: to rt.faults with the call site, every time (the
    --- fault log counts the repeats).
    local function watch_raise(rec, err)
        rec.raised = (rec.raised or 0) + 1
        watch.raised = watch.raised + 1
        local faults = rt.faults
        if not (faults and faults.listening()) then return end
        local site = rec.raised <= WATCH_RAISE_SITES and trigger_text() or "(call sites past the first 200 not read)"
        faults.native(rec.key, err, site)
    end

    --- A native answered nil after answering values before. The call site
    --- is read for the first nils of each function and then every 1000th:
    --- nil is an ordinary answer for many calls, and a stack walk on each
    --- would cost more than the call. A new site is handed over once.
    local function watch_null(rec)
        local n = (rec.nulls or 0) + 1
        rec.nulls = n
        watch.nulls = watch.nulls + 1
        if n > NULL_SITES_FIRST and n % 1000 ~= 0 then return end
        local site = trigger_text()
        local sites = rec.null_sites
        if not sites then
            sites = {}
            rec.null_sites = sites
        end
        if sites[site] then
            sites[site] = sites[site] + 1
            return
        end
        if (rec.n_null_sites or 0) >= MAX_NULL_SITES then return end
        sites[site] = 1
        rec.n_null_sites = (rec.n_null_sites or 0) + 1
        local faults = rt.faults
        if faults and faults.listening() then faults.null(rec.key, site, n) end
    end

    --- The answer of a watched call: a raise is handed over and raised
    --- again untouched; a nil after values is noted; the first answers are
    --- searched for game objects, so their methods get watched too.
    local function watched(rec, ok, ...)
        if not ok then
            local err = ...
            watch_raise(rec, err)
            error(err, 0)
        end
        local a = ...
        if a == nil then
            if rec.answered then watch_null(rec) end
        else
            if not rec.answered then rec.answered = true end
            local seen = rec.watch_seen or 0
            if seen < WATCH_DISCOVER then
                rec.watch_seen = seen + 1
                note_values(select("#", ...), ...)
            end
        end
        return ...
    end

    skip_fn[watch_raise] = true
    skip_fn[watch_null] = true
    skip_fn[watched] = true

    local function tally(rec, ...)
        local a = ...
        rec.tallied = rec.tallied + 1
        if is_empty(a) then rec.empty = rec.empty + 1 end
        return ...
    end

    local function finish(rec, args, ok, ...)
        rec.inspected = rec.inspected + 1
        if rec.last_session ~= sessions then
            if rec.last_session == nil then
                learned.functions = learned.functions + 1
                dirty = true
            end
            rec.last_session = sessions
        end
        local trig = trigger_text()
        note_trigger(rec, trig)
        local from = rec.method and 2 or 1

        if not ok then
            local err = ...
            rec.errors = rec.errors + 1
            if watch.on then watch_raise(rec, err) end
            local text = clean(err, 240)
            local list = rec.error_samples
            local known = false
            for i = 1, #list do
                if list[i].error == text then known = true break end
            end
            if not known and #list < MAX_ERRORS then
                list[#list + 1] = {
                    error = text,
                    call = "(" .. show_list(args, from, ARG_TEXT, true) .. ")",
                    by = trig,
                }
                dirty = true
            end
            -- Re-raised untouched: a caller's pcall sees what it always saw.
            error(err, 0)
        end

        local n = select("#", ...)
        local a, b, c = ...
        rec.tallied = rec.tallied + 1
        if is_empty(a) then rec.empty = rec.empty + 1 end
        if watch.on then
            if a == nil then
                if rec.answered then watch_null(rec) end
            elseif not rec.answered then
                rec.answered = true
            end
        end

        -- What goes in and what comes out, by kind and position.
        local last = args.n
        while last >= from and args[last] == nil do last = last - 1 end
        for i = from, math.min(last, from + MAX_POSITIONS - 1) do
            if add_kind(rec.args, i - from + 1, kind(args[i])) then dirty = true end
        end
        for i = 1, math.min(n, MAX_POSITIONS) do
            if add_kind(rec.rets, i, kind((select(i, ...)))) then dirty = true end
        end

        local shape = shape_of(n, a, b, c)
        local seen = rec.shapes[shape]
        if not seen and count_shapes(rec) >= MAX_SHAPES then
            shape = "other"
            seen = rec.shapes.other
        end
        rec.shapes[shape] = (seen or 0) + 1
        if not seen then dirty = true end

        -- An example only for a call not seen before: other arguments, or
        -- another kind of answer. Past MAX_EXAMPLES only a new answer shape
        -- earns one.
        local call_text = show_list(args, from, ARG_TEXT, true)
        local ex_key = shape .. "|" .. call_text
        if not rec.example_keys[ex_key] then
            local count = #rec.examples
            if count < MAX_EXAMPLES or (not seen and count < MAX_EXAMPLES_SHAPE) then
                rec.example_keys[ex_key] = true
                local ex = {
                    call = "(" .. call_text .. ")",
                    answer = show_list(pack(...), 1, RET_TEXT),
                    shape = shape,
                    by = trig,
                }
                rec.examples[count + 1] = ex
                learned.examples = learned.examples + 1
                dirty = true
                if rec.kind == "action" then
                    local w = open_windows[rec.key]
                    if w then w.ex = ex end
                end
            end
        end

        note_values(n, a, b, c)
        return ...
    end

    local function inspect(rec, fn, ...)
        return finish(rec, pack(...), pcall(fn, ...))
    end

    skip_fn[finish] = true
    skip_fn[inspect] = true
    skip_fn[tally] = true

    --- What the function itself is: the client's ("C") or a script's ("Lua").
    local function origin_of(fn)
        if not getinfo then return nil end
        local ok, info = pcall(getinfo, fn, "S")
        if not ok or type(info) ~= "table" then return nil end
        return info.what == "C" and "C" or "Lua"
    end

    local function make_wrapper(key, fn, mode, method, kind_name)
        local rec = new_record(key, mode, method, kind_name)
        if not rec then return nil end
        rec.origin = origin_of(fn) or rec.origin
        local w
        if mode == "count" then
            w = function(...)
                rec.calls = rec.calls + 1
                return fn(...)
            end
        else
            local action = rec.kind == "action"
            w = function(...)
                rec.calls = rec.calls + 1
                if not active then
                    if watch.on then return watched(rec, pcall(fn, ...)) end
                    return fn(...)
                end
                local n = rec.session + 1
                rec.session = n
                counts_moved = true
                -- Opened before the native runs: an event it raises on the
                -- spot is still its effect.
                if action then open_window(key, rec) end
                if n <= INSPECT_FIRST or n % INSPECT_EVERY == 0 then
                    return inspect(rec, fn, ...)
                end
                if watch.on then return tally(rec, watched(rec, pcall(fn, ...))) end
                return tally(rec, fn(...))
            end
        end
        skip_fn[w] = true
        return w
    end

    -- --- game_object methods ----------------------------------------------
    --
    -- Game objects are native userdata sharing one metatable per pushed type.
    -- Its __index is either a table of methods (wrapped in place, like a
    -- namespace) or a lookup function (replaced by a proxy that hands back a
    -- recording wrapper for each method and passes everything else through).
    -- Found on the first object any inspected call returns.

    local method_wrappers = {}    -- name -> { fn = original, w = wrapper }

    local function method_wrapper(name, fn)
        local m = method_wrappers[name]
        if m and m.fn == fn then return m.w end
        local w = make_wrapper("game_object:" .. name, fn, "full", true, kind_for("", name, "full", true))
        if not w then return fn end
        method_wrappers[name] = { fn = fn, w = w }
        if not object_surface.methods[name] then
            object_surface.methods[name] = true
            dirty = true
        end
        return w
    end

    maybe_proxy = function(v)
        local ok, mt = pcall(getmetatable, v)
        if not ok or type(mt) ~= "table" or seen_mt[mt] then return end
        seen_mt[mt] = true
        if not looks_like_object(v) then return end
        if proxied_types >= MAX_OBJECT_TYPES then return end

        local idx = rawget(mt, "__index")
        if type(idx) == "table" then
            local entries = {}
            for name, fn in pairs(idx) do
                if type(name) == "string" and type(fn) == "function" and not name:find("^__") then
                    entries[#entries + 1] = { name = name, fn = fn }
                end
            end
            local done = {}
            for i = 1, #entries do
                local e = entries[i]
                local w = method_wrapper(e.name, e.fn)
                local set = pcall(function() idx[e.name] = w end)
                if set and idx[e.name] == w then
                    done[#done + 1] = e
                end
            end
            proxied[#proxied + 1] = { kind = "table", target = idx, entries = done }
            proxied_types = proxied_types + 1
            object_surface.index = "table"
            dirty = true
            return
        end

        if type(idx) ~= "function" then
            object_surface.index = type(idx)
            dirty = true
            return
        end

        local original = idx
        local proxy = function(self, key)
            local value = original(self, key)
            if (active or watch.on) and type(value) == "function" and type(key) == "string" then
                return method_wrapper(key, value)
            end
            return value
        end
        local set = pcall(rawset, mt, "__index", proxy)
        if not set or rawget(mt, "__index") ~= proxy then
            object_surface.index = "function (not replaceable)"
            dirty = true
            return
        end
        -- Proven on the object in hand before it is trusted: if a method no
        -- longer comes back as a function, the original goes straight back.
        local okc, got = pcall(function() return v.get_health end)
        if not okc or type(got) ~= "function" then
            rawset(mt, "__index", original)
            object_surface.index = "function (proxy failed: " .. clean(got, 80) .. ")"
            dirty = true
            return
        end
        proxied[#proxied + 1] = { kind = "function", mt = mt, original = original, proxy = proxy }
        proxied_types = proxied_types + 1
        object_surface.index = "function"
        dirty = true
    end

    -- --- installing -------------------------------------------------------

    local function sorted_names(t)
        local out = {}
        for k in pairs(t) do out[#out + 1] = k end
        table.sort(out)
        return out
    end

    local function wrap_table(target, path, depth, visited)
        if visited[target] then return end
        visited[target] = true

        local fns, subs = {}, {}
        local ok = pcall(function()
            for k, v in pairs(target) do
                if type(k) == "string" then
                    if type(v) == "function" then
                        fns[#fns + 1] = k
                    elseif type(v) == "table" and depth < 2 then
                        subs[#subs + 1] = k
                    end
                end
            end
        end)
        if not ok then
            surface.unwritable[#surface.unwritable + 1] = (path == "" and "core" or path) .. " (not enumerable)"
            return
        end
        table.sort(fns)
        table.sort(subs)

        if path == "" then
            surface.core = fns
        elseif #fns > 0 then
            surface.namespaces[path] = fns
        end

        for i = 1, #fns do
            local name = fns[i]
            local mode = mode_for(path, name)
            local key = path == "" and name or (path .. "." .. name)
            if mode == "skip" then
                surface.skipped[#surface.skipped + 1] = key
            else
                local original = target[name]
                local w = make_wrapper(key, original, mode, nil, kind_for(path, name, mode, false))
                if w then
                    local set = pcall(function() target[name] = w end)
                    if set and target[name] == w then
                        installed[#installed + 1] = { target = target, key = name, original = original, wrapper = w }
                    else
                        surface.unwritable[#surface.unwritable + 1] = key
                    end
                end
            end
        end

        for i = 1, #subs do
            local name = subs[i]
            if not (path == "" and NEVER_NAMESPACE[name]) then
                local sub = target[name]
                -- A table of plain values (an enum, a constants block) has no
                -- functions and is skipped by the walk itself.
                wrap_table(sub, path == "" and name or (path .. "." .. name), depth + 1, visited)
            elseif path == "" then
                surface.skipped[#surface.skipped + 1] = name .. ".*"
            end
        end
    end

    -- The phase: JCore's scheduler entry points (main.lua looks them up on
    -- rt.scheduler every call) and its event bus, hooked while recording so
    -- every call knows whether an update, a render or which event led to it.
    local topic_label = {}
    local topic_labels = 0

    local function leave(prev, ...)
        phase = prev
        return ...
    end

    local function label_of(topic, first)
        local key = topic == "jcore.game_event" and first or topic
        local label = topic_label[key]
        if label then return label end
        if topic == "jcore.game_event" then
            label = "event " .. tostring(first)
        elseif type(topic) == "string" and topic:sub(1, 17) == "jcore.game_event." then
            label = "event " .. topic:sub(18)
        else
            label = "on " .. tostring(topic)
        end
        if topic_labels < 1024 and key ~= nil then
            topic_label[key] = label
            topic_labels = topic_labels + 1
        end
        return label
    end

    local function hook(target, key, wrapper, original)
        skip_fn[wrapper] = true
        target[key] = wrapper
        hooked[#hooked + 1] = { target = target, key = key, original = original, wrapper = wrapper }
    end

    local function hook_phases()
        hooked = {}
        local s = rt.scheduler
        if type(s) == "table" then
            for key, label in pairs(PHASES) do
                local original = s[key]
                if type(original) == "function" then
                    hook(s, key, function(...)
                        local prev = phase
                        phase = label
                        return leave(prev, original(...))
                    end, original)
                end
            end
        end
        local bus = rt.events
        local emit = type(bus) == "table" and bus.emit or nil
        if type(emit) == "function" then
            hook(bus, "emit", function(topic, ...)
                local prev = phase
                phase = label_of(topic, (...))
                return leave(prev, emit(topic, ...))
            end, emit)
        end
    end

    local function unhook_phases()
        for i = #hooked, 1, -1 do
            local h = hooked[i]
            if h.target[h.key] == h.wrapper then h.target[h.key] = h.original end
        end
        hooked = {}
        phase = nil
    end

    local function install()
        watch.installed = true
        installed = {}
        surface = { core = {}, namespaces = {}, unwritable = {}, skipped = {} }
        hook_phases()
        if type(core) ~= "table" then
            surface.unwritable[1] = "core is a " .. type(core)
            return
        end
        wrap_table(core, "", 0, {})
    end

    local function uninstall()
        watch.installed = false
        unhook_phases()
        open_windows = {}
        for i = #installed, 1, -1 do
            local e = installed[i]
            if e.target[e.key] == e.wrapper then
                pcall(function() e.target[e.key] = e.original end)
            end
        end
        installed = {}
        for i = #proxied, 1, -1 do
            local p = proxied[i]
            if p.kind == "function" then
                if rawget(p.mt, "__index") == p.proxy then
                    pcall(rawset, p.mt, "__index", p.original)
                end
            else
                for j = 1, #p.entries do
                    local e = p.entries[j]
                    pcall(function() p.target[e.name] = e.fn end)
                end
            end
        end
        proxied = {}
        proxied_types = 0
        method_wrappers = {}
        seen_mt = setmetatable({}, { __mode = "k" })
    end

    -- --- events -----------------------------------------------------------

    local function args_signature(args)
        if type(args) ~= "table" then return type(args), 0 end
        local max = 0
        for k in pairs(args) do
            if type(k) == "number" and k > max and k == math.floor(k) then max = k end
            if max > 64 then break end
        end
        max = math.min(max, 40)
        local parts = {}
        for i = 1, max do parts[i] = kind(args[i]) end
        return table.concat(parts, ","), max
    end

    local function new_event(first_session)
        return { count = 0, signatures = {}, layouts = {}, after = {}, n_after = 0, unprompted = 0,
            first_session = first_session }
    end

    --- Counts one event and keeps an example of a layout not seen before.
    --- Answers the event's record, for note_effects.
    local function record_event(key, args)
        local e = events[key]
        if not e then
            if event_count >= MAX_EVENTS then return nil end
            e = new_event(sessions)
            events[key] = e
            event_count = event_count + 1
            learned.events = learned.events + 1
            dirty = true
        end
        e.count = e.count + 1
        counts_moved = true
        if e.count > 3 and e.count % 50 ~= 0 then return e end
        if #e.layouts >= EVENT_LAYOUTS then return e end

        local sig, max = args_signature(args)
        if e.signatures[sig] then return e end
        e.signatures[sig] = true
        local list = { n = max }
        if type(args) == "table" then
            for i = 1, max do list[i] = args[i] end
        else
            list = pack(args)
        end
        e.layouts[#e.layouts + 1] = { kinds = sig, size = max, example = show_list(list, 1, 400) }
        learned.layouts = learned.layouts + 1
        dirty = true
        return e
    end

    --- The name an event is counted under as an action's effect: the error
    --- or info tag for UI messages ("UI_ERROR_MESSAGE:ERR_ABILITY_COOLDOWN"),
    --- the kind of unit for UNIT_* ("UNIT_SPELLCAST_SENT(player)",
    --- "UNIT_AURA(nameplate)").
    local function effect_key(name, args)
        if type(args) ~= "table" then return name end
        if name == "UI_ERROR_MESSAGE" or name == "UI_INFO_MESSAGE" then
            local tag = args[3]
            return type(tag) == "string" and (name .. ":" .. clean(tag, 60)) or name
        end
        if name:sub(1, 5) == "UNIT_" then
            local unit = args[1]
            if AURA_LEADS[unit] then unit = args[2] end
            if type(unit) == "string" then
                return name .. "(" .. clean((unit:gsub("%d+$", "")), 24) .. ")"
            end
        end
        return name
    end

    -- --- the catalog ------------------------------------------------------
    --
    -- The per-call totals say what a call answers in general; the catalog
    -- keeps every THING the client names: each spell id seen (yours, the
    -- mobs', on an aura) with what the client says about it, the talents
    -- (classic tabs and trait trees), every npc id with its creature type,
    -- levels and the names cast at it, the items in the bags, the maps, and
    -- the quests -- their ids from the quest events, objective progress from
    -- UI_INFO_MESSAGE, and what every quest-log and gossip GETTER answers
    -- about them. Merged across sessions into
    -- scripts_data/jcore/jcore.catalog.json.
    --
    -- Only getters are called. Nothing here accepts, abandons, completes,
    -- selects, pushes or buys: core.quests.get_quest_reward is NOT a getter
    -- (it takes the reward and finishes the quest) and is never called.
    --
    -- The work is sliced: a few spells' facts, one bag, a handful of trait
    -- nodes per tick every two seconds, so nothing here is a frame's cost.

    local CATALOG_FILE = "jcore/jcore.catalog.json"
    local CATALOG_TICK = 2.0
    local SPELLS_PER_TICK = 8
    local NODES_PER_TICK = 40
    local QUEST_LOG_MAX = 25
    local DESC_TEXT = 400

    local catalog = {
        spells = {}, talents = { classic = {}, nodes = {}, trees = {}, active = {} },
        npcs = {}, items = {}, maps = {}, quests = {}, objectives = {}, gossip = {},
        probes = {}, features = {},
    }
    local catalog_dirty = false
    local catalog_saved_at = -1e9
    local catalog_timer = nil
    local spell_queue, spell_queued = {}, {}
    local node_queue = {}
    local npc_seen_guid = {}
    local catalog_clock = { spellbook = -1e9, map = -1e9, bags = -1e9, talents = -1e9, quests = -1e9,
        completed = -1e9, bag = 0 }
    local talents_wanted = true

    --- A value as plain JSON-able data: numbers, strings and booleans kept,
    --- tables copied a few levels deep, game objects and functions named.
    local function plain(v, depth)
        depth = depth or 0
        local t = type(v)
        if t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
            return v
        end
        if t == "string" then return clean(v, DESC_TEXT) end
        if t == "boolean" or t == "nil" then return v end
        if t == "function" then return "fn" end
        if looks_like_object(v) then return "obj" end
        if t ~= "table" then return t end
        if depth >= 3 then return "{...}" end
        local out, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 64 then break end
            local key = type(k) == "number" and k or tostring(k)
            out[key] = plain(val, depth + 1)
        end
        return out
    end

    local function call(fn, ...)
        if type(fn) ~= "function" then return nil, "absent" end
        local ok, a = pcall(fn, ...)
        if not ok then return nil, clean(a, 160) end
        return a
    end

    local function ns(name) return type(core) == "table" and core[name] or nil end

    local function want_spell(id)
        id = tonumber(id)
        if not id or id <= 0 or id > 5000000 or id ~= math.floor(id) then return nil end
        local key = tostring(id)
        local s = catalog.spells[key]
        if not s then
            s = { seen = 0, from = {} }
            catalog.spells[key] = s
            catalog_dirty = true
        end
        if not s.facts_at and not spell_queued[key] then
            spell_queued[key] = true
            spell_queue[#spell_queue + 1] = id
        end
        return s
    end

    local function note_spell(id, source, name, npc_id)
        local s = want_spell(id)
        if not s then return end
        s.seen = s.seen + 1
        if source and not s.from[source] then
            s.from[source] = true
            catalog_dirty = true
        end
        if type(name) == "string" and name ~= "" and s.name ~= name then
            s.name = clean(name, 120)
            catalog_dirty = true
        end
        if npc_id and npc_id > 0 then
            s.npcs = s.npcs or {}
            local k = tostring(npc_id)
            if not s.npcs[k] then catalog_dirty = true end
            s.npcs[k] = (s.npcs[k] or 0) + 1
            local n = catalog.npcs[k]
            if n then
                n.spells = n.spells or {}
                n.spells[tostring(id)] = (n.spells[tostring(id)] or 0) + 1
            end
        end
    end

    --- What the client says about one spell, asked once per build.
    local function spell_facts(id)
        local book = ns("spell_book")
        if not book then return end
        local s = catalog.spells[tostring(id)]
        if not s then return end
        local name = call(book.get_spell_name, id)
        if type(name) == "string" and name ~= "" then s.name = clean(name, 120) end
        s.school = plain(call(book.get_spell_school, id))
        s.cast_time = plain(call(book.get_spell_cast_time, id))
        s.min_range = plain(call(book.get_spell_min_range, id))
        s.max_range = plain(call(book.get_spell_max_range, id))
        s.base_cooldown = plain(call(book.get_spell_base_cooldown, id))
        s.costs = plain(call(book.get_spell_costs, id))
        s.melee = plain(call(book.is_melee_spell, id))
        s.position_cast = plain(call(book.is_spell_position_cast, id))
        s.base_id = plain(call(book.get_base_spell_id, id))
        s.override_id = plain(call(book.get_override_spell_id, id))
        local desc = call(book.get_spell_description, id)
        if type(desc) == "string" and desc ~= "" then s.description = clean(desc, DESC_TEXT) end
        s.known = plain(call(book.is_spell_known, id))
        s.facts_at = math.floor(now())
        catalog_dirty = true
    end

    local function npc_of(guid, obj, row)
        if not obj then return nil end
        local key = npc_seen_guid[guid]
        if key == nil then
            local okn, id = pcall(function() return obj:get_npc_id() end)
            id = okn and tonumber(id) or 0
            key = id > 0 and tostring(id) or false
            npc_seen_guid[guid] = key
        end
        if not key then return nil end
        local n = catalog.npcs[key]
        if not n then
            n = { seen = 0, names = {} }
            catalog.npcs[key] = n
            catalog_dirty = true
            local okt, ct = pcall(function() return obj:get_creature_type() end)
            n.creature_type = okt and plain(ct) or nil
            local okm, mh = pcall(function() return obj:get_max_health() end)
            n.max_health = okm and plain(mh) or nil
        end
        local okl, level = pcall(function() return obj:get_level() end)
        level = okl and tonumber(level) or nil
        if level then
            if not n.level_min or level < n.level_min then n.level_min = level; catalog_dirty = true end
            if not n.level_max or level > n.level_max then n.level_max = level; catalog_dirty = true end
        end
        if row and row.is_enemy ~= nil then n.attackable = row.is_enemy == true end
        return n, key
    end

    local function quest(id)
        id = tonumber(id)
        if not id or id <= 0 then return nil end
        local key = tostring(math.floor(id))
        local q = catalog.quests[key]
        if not q then
            q = { first_seen = math.floor(now()) }
            catalog.quests[key] = q
            catalog_dirty = true
        end
        return q, key
    end

    --- What the quest getters answer about every quest we know of, and
    --- about the classic quest log (documented as empty on Forever --
    --- recorded rather than believed).
    local function probe_quests()
        local qs = ns("quests")
        if not qs then return end
        for key, q in pairs(catalog.quests) do
            local id = tonumber(key)
            q.on_quest = plain(call(qs.is_on_quest, id))
            q.flagged_completed = plain(call(qs.is_quest_flagged_completed, id))
        end
        local n = tonumber((call(qs.get_num_quest_log_entries))) or 0
        local log_rows = { count = n, entries = {} }
        for i = 1, math.min(n, QUEST_LOG_MAX) do
            local entry = { title = plain(call(qs.get_quest_log_title, i)) }
            local boards = tonumber((call(qs.get_num_quest_leader_boards, i))) or 0
            entry.boards = boards
            if boards > 0 then
                entry.objectives = {}
                for j = 1, math.min(boards, 10) do
                    entry.objectives[j] = plain(call(qs.get_quest_log_leader_board, j, i))
                end
            end
            log_rows.entries[i] = entry
        end
        catalog.probes.quest_log = log_rows
        catalog_dirty = true
    end

    --- The quest giver's window, while it is open.
    local function probe_gossip(event_name)
        local qs = ns("quests")
        if not qs then return end
        local g = {
            event = event_name, at = math.floor(now()),
            shown = plain(call(qs.is_gossip_frame_shown)),
            available = plain(call(qs.get_gossip_available_quests)),
            active = plain(call(qs.get_gossip_active_quests)),
            options = plain(call(qs.get_gossip_options)),
            reward_money = plain(call(qs.get_reward_money)),
            active_titles = {}, available_titles = {},
        }
        for i = 1, 4 do
            g.active_titles[i] = plain(call(qs.get_active_title, i))
            g.available_titles[i] = plain(call(qs.get_available_title, i))
        end
        -- Who is giving it: the target, when there is one.
        local combat = rt.combat
        local target = combat and combat.target and combat.target() or nil
        if target then
            local units = rt.units
            local guid = units and units.guid and units.guid(target) or nil
            local _, npc_key = npc_of(guid or "?", target, nil)
            g.npc = npc_key
        end
        -- The same window again (same event, giver and lists) is counted on
        -- the row already kept: talking to one quest giver ten times is one
        -- row, not ten.
        local function same_window(x)
            local ok, text = pcall(json.encode, { x.event, x.npc, x.available, x.active, x.options })
            return ok and text or nil
        end
        local sig = same_window(g)
        for i = #catalog.gossip, 1, -1 do
            local old = catalog.gossip[i]
            if sig and type(old) == "table" and same_window(old) == sig then
                old.seen = (tonumber(old.seen) or 1) + 1
                old.at = g.at
                catalog_dirty = true
                return
            end
        end
        g.seen = 1
        catalog.gossip[#catalog.gossip + 1] = g
        while #catalog.gossip > 40 do table.remove(catalog.gossip, 1) end
        catalog_dirty = true
    end

    local function scan_talents_start()
        local ui = ns("game_ui")
        if not ui then return end
        local t = catalog.talents
        t.unspent = plain(call(ui.get_unspent_talent_points))
        t.specialization = plain(call(ui.get_specialization))
        t.active = plain(call(ui.get_active_talents))
        -- The classic tabs.
        local tabs = tonumber((call(ui.get_num_talent_tabs))) or 0
        t.classic = { tabs = tabs }
        local book = ns("spell_book")
        for tab = 1, math.min(tabs, 5) do
            local entry = { info = plain(call(ui.get_talent_tab_info, tab)), talents = {} }
            local count = tonumber((call(ui.get_num_talents, tab))) or 0
            for i = 1, math.min(count, 40) do
                local info = call(ui.get_talent_info, tab, i)
                local row = plain(info)
                if type(row) ~= "table" then row = { value = row } end
                local talent_id = type(info) == "table" and tonumber(info.talent_id) or nil
                if talent_id and book then
                    row.spell_id = plain(call(book.get_talent_spell_id, talent_id))
                    row.talent_name = plain(call(book.get_talent_name, talent_id))
                    if type(row.spell_id) == "number" then note_spell(row.spell_id, "talent") end
                end
                entry.talents[i] = row
            end
            t.classic[tab] = entry
        end
        -- The trait trees: ids now, nodes a few per tick.
        local trees = call(ui.get_talent_tree_ids)
        t.tree_ids = plain(trees)
        if type(trees) == "table" then
            for i = 1, math.min(#trees, 6) do
                local tree = trees[i]
                local nodes = call(ui.get_talent_tree_nodes, tree)
                t.trees[tostring(tree)] = plain(nodes)
                if type(nodes) == "table" then
                    for j = 1, math.min(#nodes, 400) do node_queue[#node_queue + 1] = nodes[j] end
                end
            end
        end
        if type(t.active) == "table" then
            for _, a in pairs(t.active) do
                if type(a) == "table" and a.spell_id then note_spell(a.spell_id, "talent", a.name) end
            end
        end
        catalog_dirty = true
    end

    local function scan_bag(bag)
        local inv = ns("inventory")
        local rows = inv and call(inv.get_items_in_bag, bag) or nil
        if type(rows) ~= "table" then return end
        for i = 1, #rows do
            local obj = type(rows[i]) == "table" and rows[i].object or nil
            if obj then
                local oki, id = pcall(function() return obj:get_item_id() end)
                id = oki and tonumber(id) or nil
                if id and id > 0 then
                    local key = tostring(id)
                    local item = catalog.items[key]
                    if not item then
                        item = {}
                        catalog.items[key] = item
                        catalog_dirty = true
                    end
                    if not item.name then
                        local okn, name = pcall(function() return obj:get_name() end)
                        if okn and type(name) == "string" and name ~= "" then item.name = clean(name, 120) end
                    end
                    item.last_bag = bag
                end
            end
        end
    end

    -- --- what the missing Forever features need ---------------------------------
    --
    -- Seven things the Forever ESP cannot do yet, because the read each one
    -- stands on answers nothing there (2026-10-02): lootable corpses
    -- (has_loot / can_be_looted always false), quest tags, gathering nodes,
    -- raid markers (get_target_marker_index always 16), tapped grey
    -- (is_tap_denied always false), rare / elite (get_classification always 0),
    -- and the in-combat icon (art; the offline extractor's job). For each,
    -- every CANDIDATE read is recorded as a histogram of its answers, and
    -- wherever the game hands over a ground truth it is recorded beside them:
    --
    --   loot     the corpse you just looted (the dead unit within reach when
    --            LOOT_OPENED fires), its reads from before, and what the loot
    --            window held
    --   nodes    the game object within reach when a gathering cast succeeds
    --   markers  every change of a unit's marker index (mark one to see)
    --   tapped   mobs fighting someone outside your group
    --   rank     classification, is_boss and health per level, by npc id
    --   quest    is_quest_unit and the npc flags, by npc id
    --
    -- A handful of units a tick, getters only, all into catalog.features.

    local FEATURE_UNITS = 8
    local REACH = 6.0
    local LOOT_READS = { "has_loot", "can_be_looted", "can_be_skinned", "has_skin", "get_npc_flags",
        "get_npc_flags2", "get_state_flags", "is_tap_denied" }
    local UNIT_READS = { "is_quest_unit", "get_npc_flags", "get_npc_flags2", "get_state_flags",
        "is_tap_denied", "get_classification", "is_boss", "get_target_marker_index" }
    local OBJECT_READS = { "get_name", "get_type", "get_npc_id", "get_item_id", "is_basic_object",
        "is_item", "can_be_used", "has_loot", "can_be_looted", "get_npc_flags", "get_state_flags" }
    local GATHER_WORDS = { "gather", "mining", "herb", "skinning", "opening", "fishing", "disarm" }

    local function feature(name)
        catalog.features = catalog.features or {}
        local f = catalog.features[name]
        if not f then
            f = { reads = {} }
            catalog.features[name] = f
        end
        return f
    end

    --- One answer counted under feature.reads[method][rendered value].
    local function count_read(f, method, value)
        local key = type(value) == "table" and show(value) or tostring(value)
        key = clean(key, 80)
        local h = f.reads[method]
        if not h then
            h = {}
            f.reads[method] = h
        end
        local n = 0
        for _ in pairs(h) do n = n + 1 end
        if h[key] == nil and n >= 24 then key = "(other)" end
        h[key] = (h[key] or 0) + 1
        catalog_dirty = true
    end

    local function read_all(obj, methods)
        local out = {}
        for i = 1, #methods do
            local m = methods[i]
            local okf, fn = pcall(function() return obj[m] end)
            if okf and type(fn) == "function" then
                local ok, v = pcall(fn, obj)
                -- Not "ok and plain(v) or ...": an answer of false would
                -- read as an error.
                if ok then out[m] = plain(v) else out[m] = "err: " .. clean(v, 60) end
            end
        end
        return out
    end

    local function keep(list, entry, cap)
        list[#list + 1] = entry
        while #list > cap do table.remove(list, 1) end
        catalog_dirty = true
    end

    local corpse_reads = {}   -- guid -> { reads, npc, at } for corpses near you
    local marker_last = {}    -- guid -> last marker index
    local tapped_seen = {}    -- guid -> true once its fight with someone else is written
    local feature_cursor = 0

    local function probe_features(t)
        local units = rt.units
        if not units or not units.units then return end
        local list = units.units()
        local enemies = rt.enemies
        local loot, quest_f, markers, tapped, rank =
            feature("loot"), feature("quest"), feature("markers"), feature("tapped"), feature("rank")

        -- A rotating window over the sweep, so every unit is read in turn.
        local n = #list
        for step = 1, math.min(FEATURE_UNITS, n) do
            feature_cursor = feature_cursor % n + 1
            local obj = list[feature_cursor]
            local row = units.snapshot and units.snapshot(obj) or nil
            if row and not row.is_self and row.guid then
                local guid = row.guid
                if row.dead then
                    if not row.is_player and (row.dist or 99) <= 40 then
                        local reads = read_all(obj, LOOT_READS)
                        for m, v in pairs(reads) do count_read(loot, m, v) end
                        local _, npc = npc_of(guid, obj, row)
                        corpse_reads[guid] = { reads = reads, npc = npc, at = math.floor(t), dist = row.dist }
                    end
                elseif not row.is_player then
                    local reads = read_all(obj, UNIT_READS)
                    local entry, npc = npc_of(guid, obj, row)
                    count_read(quest_f, "is_quest_unit", reads.is_quest_unit)
                    count_read(quest_f, "get_npc_flags", reads.get_npc_flags)
                    count_read(quest_f, "get_npc_flags2", reads.get_npc_flags2)
                    count_read(rank, "get_classification", reads.get_classification)
                    count_read(rank, "is_boss", reads.is_boss)
                    count_read(markers, "get_target_marker_index", reads.get_target_marker_index)
                    if entry then
                        entry.quest_unit = reads.is_quest_unit
                        entry.npc_flags = reads.get_npc_flags
                        entry.classification = reads.get_classification
                        entry.is_boss = reads.is_boss
                        if type(entry.max_health) == "number" and (entry.level_max or 0) > 0 then
                            entry.health_per_level = math.floor(entry.max_health / entry.level_max + 0.5)
                        end
                    end
                    -- A marker that changes is the ground truth for what the
                    -- index means: mark a mob and its change is written here.
                    local mark = reads.get_target_marker_index
                    if marker_last[guid] ~= nil and marker_last[guid] ~= mark then
                        markers.changes = markers.changes or {}
                        keep(markers.changes, { guid = guid:sub(-10), npc = npc, from = marker_last[guid],
                            to = mark, at = math.floor(t) }, 40)
                    end
                    marker_last[guid] = mark
                    -- Tapped by someone else: fighting, and not you, your pet
                    -- or your group.
                    if row.is_enemy then
                        count_read(tapped, "is_tap_denied", reads.is_tap_denied)
                        local e = enemies and enemies.get and enemies.get(guid) or nil
                        if e and e.in_combat and e.target_guid and not e.targeting_me and not e.targeting_pet
                            and not tapped_seen[guid] then
                            tapped_seen[guid] = true
                            tapped.fighting_others = tapped.fighting_others or {}
                            keep(tapped.fighting_others, { npc = npc, is_tap_denied = reads.is_tap_denied,
                                state_flags = reads.get_state_flags, npc_flags = reads.get_npc_flags,
                                at = math.floor(t) }, 40)
                        end
                    end
                end
            end
        end

        -- Game objects: what a herb, a vein or a chest answers.
        local objects = units.objects and units.objects() or {}
        local nodes = feature("nodes")
        nodes.objects = nodes.objects or {}
        local seen = 0
        for i = 1, #objects do
            if seen >= FEATURE_UNITS then break end
            local obj = objects[i]
            local row = units.snapshot and units.snapshot(obj) or nil
            if row and (row.dist or 99) <= 60 then
                seen = seen + 1
                local reads = read_all(obj, OBJECT_READS)
                local name = type(reads.get_name) == "string" and reads.get_name ~= ""
                    and not reads.get_name:find("^err: ") and reads.get_name or nil
                if type(reads.get_name) == "string" and reads.get_name:find("^err: ") then reads = nil end
                local key = name or ("type " .. tostring(reads.get_type) .. " id " .. tostring(reads.get_npc_id))
                local o = reads and nodes.objects[key] or nil
                if reads and not o then
                    local count = 0
                    for _ in pairs(nodes.objects) do count = count + 1 end
                    if count < 300 then
                        o = { seen = 0, reads = reads }
                        nodes.objects[key] = o
                        catalog_dirty = true
                    end
                end
                if o then o.seen = o.seen + 1 end
            end
        end

        for guid, c in pairs(corpse_reads) do
            if t - (c.at or 0) > 60 then corpse_reads[guid] = nil end
        end
    end

    --- The dead unit within reach: the one a loot window just opened on.
    local function corpse_in_reach()
        local units = rt.units
        if not units or not units.units then return nil end
        local best, best_d = nil, REACH
        local list = units.units()
        for i = 1, #list do
            local row = units.snapshot and units.snapshot(list[i]) or nil
            if row and row.dead and not row.is_player and (row.dist or 99) <= best_d then
                best, best_d = row, row.dist
            end
        end
        return best
    end

    local function object_in_reach()
        local units = rt.units
        if not units or not units.objects then return nil end
        local best, best_d, best_obj = nil, REACH, nil
        local list = units.objects()
        for i = 1, #list do
            local row = units.snapshot and units.snapshot(list[i]) or nil
            if row and (row.dist or 99) <= best_d then
                best, best_d, best_obj = row, row.dist, list[i]
            end
        end
        return best, best_obj
    end

    local loot_open = nil

    local function features_event(name, args)
        if name == "LOOT_OPENED" then
            local ui = ns("game_ui")
            local items = {}
            local count = tonumber((ui and call(ui.get_loot_item_count))) or 0
            for i = 1, math.min(count, 12) do
                items[i] = {
                    id = plain(call(ui.get_loot_item_id, i)),
                    name = plain(call(ui.get_loot_item_name, i)),
                    gold = plain(call(ui.get_loot_is_gold, i)),
                }
            end
            local row = corpse_in_reach()
            local before = row and corpse_reads[row.guid] or nil
            local entry = {
                at = math.floor(now()), items = count, contents = items,
                corpse = row and row.guid and row.guid:sub(-10) or nil,
                npc = before and before.npc or nil,
                reads_before = before and before.reads or nil,
                autoloot = plain(args[1]), from_item = plain(args[2]),
            }
            if row and row.obj then entry.reads_now = read_all(row.obj, LOOT_READS) end
            local loot = feature("loot")
            loot.opened = loot.opened or {}
            keep(loot.opened, entry, 40)
            loot_open = row and row.obj or nil
        elseif name == "LOOT_CLOSED" then
            if loot_open then
                local loot = feature("loot")
                local last = loot.opened and loot.opened[#loot.opened]
                if last then last.reads_after = read_all(loot_open, LOOT_READS) end
                loot_open = nil
                catalog_dirty = true
            end
        elseif name == "UNIT_SPELLCAST_SUCCEEDED" and args[1] == "player" then
            local id = tonumber(args[3])
            local book = ns("spell_book")
            local spell = id and book and call(book.get_spell_name, id) or nil
            local lower = type(spell) == "string" and spell:lower() or ""
            local gather = false
            for i = 1, #GATHER_WORDS do
                if lower:find(GATHER_WORDS[i], 1, true) then gather = true break end
            end
            if gather then
                local row, obj = object_in_reach()
                local nodes = feature("nodes")
                nodes.gathered = nodes.gathered or {}
                keep(nodes.gathered, {
                    at = math.floor(now()), spell = id, spell_name = spell,
                    object = row and row.guid and row.guid:sub(-10) or nil,
                    reads = obj and read_all(obj, OBJECT_READS) or nil,
                }, 40)
            end
        end
    end

    local function catalog_tick()
        if not active then return end
        local t = now()

        local okf, errf = pcall(probe_features, t)
        if not okf then log.fmt("debug", "feature probes: %s", tostring(errf)) end

        -- A few spells' facts.
        local n = 0
        while n < SPELLS_PER_TICK and #spell_queue > 0 do
            local id = table.remove(spell_queue, 1)
            spell_queued[tostring(id)] = nil
            spell_facts(id)
            n = n + 1
        end

        -- A few trait nodes.
        local ui = ns("game_ui")
        local k = 0
        while k < NODES_PER_TICK and #node_queue > 0 do
            local node = table.remove(node_queue, 1)
            catalog.talents.nodes[tostring(node)] = plain(ui and call(ui.get_talent_node_info, node))
            k = k + 1
            catalog_dirty = true
        end

        -- What stands around: npc ids, types, levels.
        local units = rt.units
        local list = units and units.units and units.units() or {}
        for i = 1, #list do
            local obj = list[i]
            local row = units.snapshot and units.snapshot(obj) or nil
            if row and not row.is_player and not row.is_self and row.guid then
                local entry = npc_of(row.guid, obj, row)
                if entry then entry.seen = entry.seen + 1 end
            end
        end

        if t - catalog_clock.spellbook >= 10 then
            catalog_clock.spellbook = t
            local book = ns("spell_book")
            local ids = book and call(book.get_spells) or nil
            if type(ids) == "table" then
                for i = 1, #ids do note_spell(ids[i], "spellbook") end
            end
        end
        if t - catalog_clock.map >= 10 then
            catalog_clock.map = t
            local id = tonumber((call(core.get_map_id)))
            if id then
                local key = tostring(id)
                if not catalog.maps[key] then
                    catalog.maps[key] = { name = plain(call(core.get_map_name)) }
                    catalog_dirty = true
                end
            end
        end
        if t - catalog_clock.bags >= 6 then
            catalog_clock.bags = t
            scan_bag(catalog_clock.bag)
            catalog_clock.bag = (catalog_clock.bag + 1) % 5
        end
        if talents_wanted or t - catalog_clock.talents >= 120 then
            talents_wanted = false
            catalog_clock.talents = t
            scan_talents_start()
        end
        if t - catalog_clock.quests >= 10 then
            catalog_clock.quests = t
            probe_quests()
        end
        if t - catalog_clock.completed >= 60 then
            catalog_clock.completed = t
            local ui2 = ns("game_ui")
            local done = ui2 and call(ui2.get_all_completed_quest_ids) or nil
            if type(done) == "table" then
                local first = {}
                for i = 1, math.min(#done, 50) do first[i] = done[i] end
                catalog.probes.completed_quests = { count = #done, first = first }
                catalog_dirty = true
            end
        end
    end

    --- The game events the catalog reads, from the recorder's own handler.
    local function catalog_event(name, args)
        if type(args) ~= "table" then args = {} end
        local okf, errf = pcall(features_event, name, args)
        if not okf then log.fmt("debug", "feature event %s: %s", name, tostring(errf)) end
        if name == "UNIT_SPELLCAST_SENT" then
            -- (unit, target name, cast guid, spell id): the name of what you
            -- cast at, which is your target -- the one source of npc names.
            note_spell(args[4], args[1] == "player" and "cast_player" or "cast_other")
            local target_name = args[2]
            if args[1] == "player" and type(target_name) == "string" and target_name ~= "" then
                local combat, units = rt.combat, rt.units
                local target = combat and combat.target and combat.target() or nil
                local guid = target and units and units.guid and units.guid(target) or nil
                if target and guid then
                    local entry = npc_of(guid, target, nil)
                    if entry and not entry.names[target_name] then
                        entry.names[target_name] = true
                        catalog_dirty = true
                    end
                end
            end
        elseif name:find("^UNIT_SPELLCAST_") then
            local unit = args[1]
            note_spell(args[3], unit == "player" and "cast_player" or "cast_other")
        elseif name == "UNIT_AURA" and args[1] == "added" then
            note_spell(args[4], "aura", args[5])
        elseif name == "QUEST_ACCEPTED" then
            local q = quest(args[1])
            if q then q.accepted_at = math.floor(now()); catalog_clock.quests = -1e9 end
        elseif name == "QUEST_TURNED_IN" then
            local q = quest(args[1])
            if q then
                q.turned_in_at = math.floor(now())
                q.xp = plain(args[2])
                q.money = plain(args[3])
                catalog_dirty = true
            end
        elseif name == "QUEST_REMOVED" then
            local q = quest(args[1])
            if q then q.removed_at = math.floor(now()); catalog_dirty = true end
        elseif name == "UI_INFO_MESSAGE" or name == "UI_ERROR_MESSAGE" then
            local text, tag = args[2], args[3]
            if type(text) == "string" and type(tag) == "string" and tag:find("^ERR_QUEST") then
                -- "Roiling Winds destroyed: 4/6": the objective, and how far.
                -- Anything else ("You must choose a reward.") is a quest
                -- message, kept apart: it is not an objective.
                local what, have, need = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)")
                if what then
                    local o = catalog.objectives[what]
                    if not o then
                        o = { first_seen = math.floor(now()) }
                        catalog.objectives[what] = o
                    end
                    o.text, o.tag = clean(text, 160), tag
                    o.have, o.need = tonumber(have), tonumber(need)
                    o.at = math.floor(now())
                else
                    catalog.quest_messages = catalog.quest_messages or {}
                    local key = clean(text, 120)
                    local m = catalog.quest_messages[key] or { tag = tag, count = 0 }
                    m.count = m.count + 1
                    m.at = math.floor(now())
                    catalog.quest_messages[key] = m
                    -- A message filed as an objective before this was told apart.
                    if catalog.objectives[text] and not catalog.objectives[text].need then
                        catalog.objectives[text] = nil
                    end
                end
                catalog_dirty = true
            end
        elseif name == "GOSSIP_SHOW" or name == "QUEST_DETAIL" or name == "QUEST_PROGRESS"
            or name == "QUEST_COMPLETE" or name == "QUEST_GREETING" then
            probe_gossip(name)
        elseif name == "PLAYER_TALENT_UPDATE" or name == "TRAIT_CONFIG_UPDATED"
            or name == "PLAYER_LEVEL_UP" or name == "SPELLS_CHANGED" or name == "CHARACTER_POINTS_CHANGED" then
            talents_wanted = true
            catalog_clock.spellbook = -1e9
        end
    end

    local function on_enemy_casting(row, cast)
        if type(row) ~= "table" or type(cast) ~= "table" then return end
        local entry, key = npc_of(row.guid or "?", row.obj, row)
        note_spell(cast.spell_id, "cast_npc", nil, key and tonumber(key) or nil)
        if entry then entry.casts = (entry.casts or 0) + 1 end
    end

    function M.catalog() return catalog end

    local function save_catalog(force)
        if not catalog_dirty and not force then return end
        local t = now()
        if not force and t - catalog_saved_at < 30 then return end
        local out = {
            format = 1,
            client = { version = version, exact = tostring(call_raw(raw.get_exact_game_version) or "") },
            spells = catalog.spells, talents = catalog.talents, npcs = catalog.npcs, items = catalog.items,
            maps = catalog.maps, quests = catalog.quests, objectives = catalog.objectives,
            gossip = catalog.gossip, probes = catalog.probes, features = catalog.features,
            quest_messages = catalog.quest_messages,
        }
        local ok, text = pcall(json.encode, out, { pretty = true })
        if not ok or type(text) ~= "string" then
            log.fmt("warn", "could not encode the catalog: %s", tostring(text))
            return
        end
        call_raw(raw.create_data_file, CATALOG_FILE)
        if pcall(raw.write_data_file, CATALOG_FILE, text) then
            catalog_dirty = false
            catalog_saved_at = t
        end
    end

    local function load_catalog()
        local text = call_raw(raw.read_data_file, CATALOG_FILE)
        if type(text) ~= "string" or text == "" then return end
        local ok, data = pcall(json.decode, text)
        if not ok or type(data) ~= "table" or data.format ~= 1 then return end
        if type(data.client) ~= "table" or data.client.version ~= version then return end
        for _, part in ipairs({ "spells", "npcs", "items", "maps", "quests", "objectives", "probes", "features",
            "quest_messages" }) do
            if type(data[part]) == "table" then catalog[part] = data[part] end
        end
        if type(data.talents) == "table" then catalog.talents = data.talents end
        if type(data.gossip) == "table" then catalog.gossip = data.gossip end
        for _, s in pairs(catalog.spells) do
            if type(s) == "table" then
                s.from = type(s.from) == "table" and s.from or {}
                s.seen = tonumber(s.seen) or 0
            end
        end
        for _, n in pairs(catalog.npcs) do
            if type(n) == "table" then
                n.names = type(n.names) == "table" and n.names or {}
                n.seen = tonumber(n.seen) or 0
            end
        end
        for _, part in ipairs({ "nodes", "trees", "classic", "active" }) do
            if type(catalog.talents[part]) ~= "table" then catalog.talents[part] = {} end
        end
    end
    load_catalog()

    local function on_game_event(name, args)
        if type(name) ~= "string" then return end
        local key = name
        if name == "COMBAT_LOG_EVENT_UNFILTERED" and type(args) == "table" and type(args[2]) == "string" then
            key = name .. ":" .. args[2]
        end
        -- Counted against the open windows first: what the catalog reads
        -- below is the recorder's doing, not the game's.
        note_effects(effect_key(key, args), record_event(key, args))
        recorder_busy = true
        local okc, errc = pcall(catalog_event, name, args)
        recorder_busy = false
        if not okc then log.fmt("debug", "catalog event %s: %s", name, tostring(errc)) end
    end

    -- --- the trace --------------------------------------------------------
    --
    -- A timeline beside the per-call totals, for the question totals cannot
    -- answer: what happened to ONE unit, in order. A plugin adds a line with
    -- ctx.emit("jcore.recorder.trace", text). The sweep's arrivals and
    -- departures of units are added here, a departure with what the client
    -- still says about the unit. The newest TRACE_CAP lines are written as
    -- plain text to scripts_data/jcore/jcore.trace.txt with each save: plain
    -- lines, so a save costs a concat rather than a JSON encode.
    --
    -- NO REPEATS. A line that says what an earlier line said, numbers aside
    -- (the same unit in the same state, a few yards further), is skipped for
    -- TRACE_REPEAT seconds and counted; when it is written again it carries
    -- "(xN since)". Before this the Forever ESP's per-frame lines were four
    -- fifths of the file, the same mark in the same state hundreds of times.

    local TRACE_FILE = "jcore/jcore.trace.txt"
    local TRACE_PREV_FILE = "jcore/jcore.trace.prev.txt"
    local trace_prev_kept = false
    local TRACE_CAP = 6000
    local TRACE_REPEAT = 60
    local TRACE_KEYS = 4000
    local PROBES_PER_SECOND = 30
    local trace_lines = {}
    local trace_head = 0      -- index of the newest line
    local trace_count = 0
    local trace_dirty = false
    local trace_seen = {}     -- the line with its numbers blanked -> { t, n }
    local trace_keys = 0
    local trace_skipped = 0
    local probe_window, probe_n = 0, 0
    local traced_units = {}   -- guid -> true for units the sweep announced

    local function trace(text)
        text = clean(text, 400)
        local t = now()
        local key = trace_key(text)
        local seen = trace_seen[key]
        if seen and t - seen.t < TRACE_REPEAT then
            seen.n = seen.n + 1
            trace_skipped = trace_skipped + 1
            return
        end
        if seen and seen.n > 0 then
            text = string.format("%s  (x%d since)", text, seen.n)
        end
        if not seen then
            if trace_keys >= TRACE_KEYS then
                trace_seen, trace_keys = {}, 0
            end
            seen = {}
            trace_seen[key] = seen
            trace_keys = trace_keys + 1
        end
        seen.t, seen.n = t, 0
        trace_head = trace_head % TRACE_CAP + 1
        trace_lines[trace_head] = string.format("%8.2f %s", t - session_started, text)
        if trace_count < TRACE_CAP then trace_count = trace_count + 1 end
        trace_dirty = true
    end
    M.trace = trace

    --- The kept lines, oldest first.
    function M.trace_lines()
        local out = {}
        local first = trace_count < TRACE_CAP and 1 or (trace_head % TRACE_CAP + 1)
        for i = 0, trace_count - 1 do
            out[#out + 1] = trace_lines[(first - 1 + i) % TRACE_CAP + 1]
        end
        return out
    end

    -- Ten characters: six were seen shared by two different mobs on Forever.
    local function short(guid)
        return tostring(guid or "?"):sub(-10)
    end

    --- What the client still says about a unit the sweep just lost.
    local function probe(guid)
        local t = now()
        if t - probe_window >= 1 then probe_window, probe_n = t, 0 end
        if probe_n >= PROBES_PER_SECOND then return "not probed (rate)" end
        probe_n = probe_n + 1
        local om = type(core) == "table" and core.object_manager or nil
        local find = om and om.get_object_from_guid
        if type(find) ~= "function" then return "no get_object_from_guid" end
        local ok, obj = pcall(find, guid)
        if not ok or not obj then return "the client no longer has it" end
        local function ask(name)
            local okf, f = pcall(function() return obj[name] end)
            if not okf or type(f) ~= "function" then return "?" end
            local okc, v = pcall(f, obj)
            if not okc then return "err" end
            return show(v)
        end
        local dist = "?"
        local okp, pos = pcall(function() return obj:get_position() end)
        local me = rt.units and rt.units.player_position and rt.units.player_position()
        if okp and type(pos) == "table" and type(me) == "table" and pos.x and me.x then
            local dx, dy, dz = pos.x - me.x, pos.y - me.y, pos.z - me.z
            dist = string.format("%.1f", math.sqrt(dx * dx + dy * dy + dz * dz))
        end
        return string.format("client still has it: valid=%s visible=%s dead=%s d=%s name=%s",
            ask("is_valid"), ask("is_visible"), ask("is_dead"), dist, ask("get_name"))
    end

    -- Only units that arrive within SWEEP_REACH (1.6.7). In a town the
    -- players coming and going at the edge of sight, about 200 yd off, made
    -- 5692 of a session's 6000 kept lines (AIO 1.58.0, 2026-10-03), and the
    -- auto-loot lines from before them were pushed out of the file.
    local SWEEP_REACH = 100

    local function on_unit_added(guid, obj)
        local snapshot = rt.units and rt.units.snapshot
        local row = obj and snapshot and snapshot(obj) or nil
        if not row or not row.is_unit or row.is_self then return end
        if (tonumber(row.dist) or 0) > SWEEP_REACH then return end
        traced_units[guid] = true
        trace(string.format("sweep + %s d=%.1f dead=%s enemy=%s", short(guid),
            tonumber(row.dist) or -1, tostring(row.dead), tostring(row.is_enemy == true)))
    end

    local function on_unit_removed(guid)
        if not traced_units[guid] then return end
        traced_units[guid] = nil
        recorder_busy = true
        local ok, said = pcall(probe, guid)
        recorder_busy = false
        trace(string.format("sweep - %s %s", short(guid), ok and said or ("probe failed: " .. tostring(said))))
    end

    local function subscribe()
        local opts = { owner = "jcore.recorder", priority = -1000000 }
        subscriptions[#subscriptions + 1] = rt.events.on("jcore.recorder.trace", function(text)
            if type(text) == "string" then trace(text) end
        end, opts)
        subscriptions[#subscriptions + 1] = rt.events.on("jcore.unit.added", on_unit_added, opts)
        subscriptions[#subscriptions + 1] = rt.events.on("jcore.unit.removed", on_unit_removed, opts)
        subscriptions[#subscriptions + 1] = rt.events.on("jcore.game_event", on_game_event, opts)
        subscriptions[#subscriptions + 1] = rt.events.on("jcore.enemy.casting", function(row, cast)
            recorder_busy = true
            pcall(on_enemy_casting, row, cast)
            recorder_busy = false
        end, opts)
        subscriptions[#subscriptions + 1] = rt.events.on("jcore.spell.cast", function(data)
            note_effects("callback:spell_cast", record_event("callback:spell_cast", { data }))
        end, opts)
        subscriptions[#subscriptions + 1] = rt.events.on("jcore.spell.cast.legit", function(...)
            note_effects("callback:legit_spell_cast", record_event("callback:legit_spell_cast", pack(...)))
        end, opts)
    end

    local function unsubscribe()
        for i = 1, #subscriptions do rt.events.off(subscriptions[i]) end
        subscriptions = {}
    end

    -- --- the file ---------------------------------------------------------

    --- Every answer empty, and at least one of them nil, 0, "" or {}. A call
    --- that only ever returned nothing at all is an action, and a predicate
    --- that only ever said false may just never have seen its state; neither
    --- is evidence on its own.
    local function always_empty(rec)
        if rec.mode ~= "full" or rec.tallied == 0 or rec.empty ~= rec.tallied then return false end
        for shape in pairs(rec.shapes) do
            local first = shape:match("^[^,]+")
            if first ~= "none" and first ~= "false" then return true end
        end
        return false
    end

    local function status_of(rec)
        if rec.mode == "count" then return "counted" end
        if rec.tallied == 0 then return rec.errors > 0 and "raises" or "not inspected" end
        if rec.empty == rec.tallied then
            if always_empty(rec) then return "always empty" end
            for shape in pairs(rec.shapes) do
                if shape:match("^[^,]+") == "false" then return "only false" end
            end
            return "returns nothing"
        end
        return rec.errors > 0 and "answers (sometimes raises)" or "answers"
    end

    local function entry_out(rec)
        local out = {
            kind = rec.kind,
            calls = rec.calls,
            first_session = rec.first_session,
            last_session = rec.last_session,
            origin = rec.origin,
            status = status_of(rec),
        }
        if rec.mode == "count" then return out end
        out.tallied = rec.tallied
        out.empty = rec.empty
        out.inspected = rec.inspected
        out.errors = rec.errors
        out.args = kinds_list(rec.args)
        out.returns = kinds_list(rec.rets)
        out.answers = rec.shapes
        out.examples = rec.examples
        out.triggers = rec.triggers
        out.effects = rec.effects
        if #rec.error_samples > 0 then out.raised = rec.error_samples end
        return out
    end

    --- The local time as "2026-10-02 22:26" (Forever answers a table).
    local function local_stamp()
        local t = call_raw(raw.get_local_time)
        if type(t) == "table" and tonumber(t.year) and tonumber(t.month) and tonumber(t.day) then
            return string.format("%04d-%02d-%02d %02d:%02d", tonumber(t.year), tonumber(t.month), tonumber(t.day),
                tonumber(t.hour) or 0, tonumber(t.minute or t.min) or 0)
        end
        return show(t)
    end
    session_begun = local_stamp()

    local function this_session()
        local got = {}
        for k, v in pairs(learned) do got[k] = v end
        return {
            n = sessions,
            started = session_begun,
            seconds = math.floor(now() - session_started + 0.5),
            jcore = tostring(rt.VERSION or ""),
            learned = got,
        }
    end

    local function session_out()
        local log_out = {}
        local from = math.max(1, #session_log - SESSION_LOG + 2)
        for i = from, #session_log do
            if session_log[i].n ~= sessions then log_out[#log_out + 1] = session_log[i] end
        end
        log_out[#log_out + 1] = this_session()
        return { count = sessions, log = log_out }
    end

    --- The whole recording as one table, the shape the file holds.
    function M.report()
        local functions, methods = {}, {}
        for key, rec in pairs(records) do
            if rec.calls > 0 or rec.errors > 0 then
                if rec.method then
                    methods[key:sub(13)] = entry_out(rec)
                else
                    functions[key] = entry_out(rec)
                end
            end
        end

        local evs = {}
        for key, e in pairs(events) do
            evs[key] = {
                count = e.count,
                first_session = e.first_session,
                layouts = e.layouts,
                after = e.after,
                unprompted = e.unprompted,
            }
        end

        local skipped = {}
        for i = 1, #surface.skipped do skipped[surface.skipped[i]] = true end
        local coverage = {}
        local function cover(label, prefix, names)
            local exposed, called = 0, 0
            for i = 1, #names do
                local key = prefix .. names[i]
                if not skipped[key] then
                    exposed = exposed + 1
                    local r = records[key]
                    if r and r.calls > 0 then called = called + 1 end
                end
            end
            if exposed > 0 then coverage[label] = { exposed = exposed, called = called } end
        end
        cover("core", "", surface.core)
        local namespaces = {}
        for path, names in pairs(surface.namespaces) do
            namespaces[path] = names
            cover(path, path .. ".", names)
        end
        local method_names = sorted_names(object_surface.methods)
        cover("game_object", "game_object:", method_names)

        return {
            _about = ABOUT,
            format = FORMAT,
            client = {
                version = version,
                exact = tostring(call_raw(raw.get_exact_game_version) or ""),
                jcore = tostring(rt.VERSION or ""),
            },
            triggers_from = getinfo and "the call stack (debug.getinfo)" or "the phase only (the client has no debug library)",
            sessions = session_out(),
            recorded_seconds = math.floor(now() - session_started + 0.5),
            local_time = local_stamp(),
            coverage = coverage,
            functions = functions,
            methods = methods,
            events = evs,
            surface = {
                core = surface.core,
                namespaces = namespaces,
                unwritable = surface.unwritable,
                skipped = surface.skipped,
                object_index = object_surface.index,
                object_methods = method_names,
            },
        }
    end

    --- Writes the recording now. True when the file was written.
    function M.save()
        local ok, text = pcall(json.encode, M.report(), { pretty = true })
        if not ok or type(text) ~= "string" then
            save_error = "encode: " .. tostring(text)
            log.fmt("warn", "could not encode the recording: %s", tostring(text))
            return false
        end
        call_raw(raw.create_data_folder, "jcore")
        call_raw(raw.create_data_file, FILE)
        local wrote = type(raw.write_data_file) == "function" and pcall(raw.write_data_file, FILE, text)
        if not wrote then
            save_error = "write failed"
            log.fmt("warn", "could not write %s", FILE)
            return false
        end
        save_catalog(false)
        if trace_dirty and trace_count > 0 then
            -- The first write of a session moves the last session's trace
            -- aside: a reload to try a fix must not wipe the evidence of the
            -- problem it was meant to fix.
            if not trace_prev_kept then
                trace_prev_kept = true
                local old = call_raw(raw.read_data_file, TRACE_FILE)
                if type(old) == "string" and old ~= "" then
                    call_raw(raw.create_data_file, TRACE_PREV_FILE)
                    pcall(raw.write_data_file, TRACE_PREV_FILE, old)
                end
            end
            call_raw(raw.create_data_file, TRACE_FILE)
            local lines = M.trace_lines()
            lines[#lines + 1] = ""
            pcall(raw.write_data_file, TRACE_FILE, table.concat(lines, "\n"))
            trace_dirty = false
        end
        save_error = nil
        dirty, counts_moved = false, false
        last_save = now()
        saved_at = last_save
        return true
    end

    -- --- loading the last sessions -----------------------------------------
    --
    -- Format 2 is read back as written. A format 1 file (JCore 1.5.4 to
    -- 1.5.11) is converted: its samples become examples, its answer shapes
    -- give the answer kinds, and every entry counts as known (not new) this
    -- session. Nothing it holds is dropped.

    local function load_entry(key, r, fmt, prev_sessions)
        if type(r) ~= "table" or record_count >= MAX_RECORDS then return end
        local method = key:sub(1, 12) == "game_object:"
        local path, name = "", key
        if method then
            name = key:sub(13)
        else
            local p, n = key:match("^(.*)%.([^.]+)$")
            if p then path, name = p, n end
        end
        local mode = r.mode
        if mode == nil then mode = (r.kind == "paint" or r.kind == "clock") and "count" or "full" end
        local rec = new_record(key, mode, method, r.kind or kind_for(path, name, mode, method))
        rec.calls = tonumber(r.calls) or 0
        rec.tallied = tonumber(r.tallied) or 0
        rec.empty = tonumber(r.empty) or 0
        rec.inspected = tonumber(r.inspected) or 0
        rec.errors = tonumber(r.errors) or 0
        rec.first_session = tonumber(r.first_session) or 1
        rec.last_session = tonumber(r.last_session) or (fmt == 1 and prev_sessions or nil)
        rec.origin = type(r.origin) == "string" and r.origin or nil
        local shapes = type(r.answers) == "table" and r.answers or r.shapes
        rec.shapes = type(shapes) == "table" and shapes or {}

        if fmt == 1 then
            for _, s in ipairs(type(r.samples) == "table" and r.samples or {}) do
                if type(s) == "table" then
                    local args = tostring(s.args or "")
                    local ex = { call = "(" .. args .. ")", answer = tostring(s.ret or ""), shape = tostring(s.shape or "") }
                    rec.examples[#rec.examples + 1] = ex
                    rec.example_keys[ex.shape .. "|" .. args] = true
                end
            end
            for shape in pairs(rec.shapes) do
                local i = 0
                for part in tostring(shape):gmatch("[^,]+") do
                    i = i + 1
                    if part ~= "none" and part ~= "other" and not part:find("^%+") and i <= MAX_POSITIONS then
                        add_kind(rec.rets, i, part)
                    end
                end
            end
            for _, e in ipairs(type(r.error_samples) == "table" and r.error_samples or {}) do
                if type(e) == "table" then
                    rec.error_samples[#rec.error_samples + 1] = { error = tostring(e.error or ""),
                        call = "(" .. tostring(e.args or "") .. ")" }
                end
            end
            return
        end

        for _, ex in ipairs(type(r.examples) == "table" and r.examples or {}) do
            if type(ex) == "table" then
                rec.examples[#rec.examples + 1] = ex
                local call = tostring(ex.call or "")
                call = call:match("^%((.*)%)$") or call
                rec.example_keys[tostring(ex.shape or "") .. "|" .. call] = true
            end
        end
        split_kinds(r.args, rec.args)
        split_kinds(r.returns, rec.rets)
        for t, n in pairs(type(r.triggers) == "table" and r.triggers or {}) do
            rec.triggers[t] = tonumber(n) or 0
            if t ~= "(other)" then rec.n_triggers = rec.n_triggers + 1 end
        end
        if type(r.effects) == "table" then
            rec.effects = { windows = tonumber(r.effects.windows) or 0 }
            for k, n in pairs(r.effects) do
                if k ~= "windows" then
                    rec.effects[k] = tonumber(n) or 0
                    rec.n_effects = rec.n_effects + 1
                end
            end
        end
        if type(r.raised) == "table" then rec.error_samples = r.raised end
    end

    local function load_event(key, e, fmt)
        if type(e) ~= "table" or event_count >= MAX_EVENTS then return end
        local ev = new_event(tonumber(e.first_session) or 1)
        ev.count = tonumber(e.count) or 0
        ev.unprompted = tonumber(e.unprompted) or 0
        if fmt == 1 then
            for _, sig in ipairs(type(e.signatures) == "table" and e.signatures or {}) do ev.signatures[sig] = true end
            for _, s in ipairs(type(e.samples) == "table" and e.samples or {}) do
                if type(s) == "table" then
                    ev.layouts[#ev.layouts + 1] = { size = s.size, example = s.args }
                end
            end
        else
            for _, l in ipairs(type(e.layouts) == "table" and e.layouts or {}) do
                if type(l) == "table" then
                    ev.layouts[#ev.layouts + 1] = l
                    if l.kinds then ev.signatures[l.kinds] = true end
                end
            end
            for action, n in pairs(type(e.after) == "table" and e.after or {}) do
                ev.after[action] = tonumber(n) or 0
                ev.n_after = ev.n_after + 1
            end
        end
        events[key] = ev
        event_count = event_count + 1
    end

    --- Seeds the records from the last session's file, so sessions add up.
    --- A file from another client version is left to be overwritten.
    local function load_previous()
        local text = call_raw(raw.read_data_file, FILE)
        if type(text) ~= "string" or text == "" then return end
        local ok, data = pcall(json.decode, text)
        if not ok or type(data) ~= "table" then return end
        local fmt = data.format
        if fmt ~= 1 and fmt ~= FORMAT then return end
        if type(data.client) ~= "table" or data.client.version ~= version then return end

        local prev = data.sessions
        local prev_count = type(prev) == "table" and tonumber(prev.count) or tonumber(prev) or 0
        sessions = prev_count + 1
        if type(prev) == "table" and type(prev.log) == "table" then
            for _, entry in ipairs(prev.log) do
                if type(entry) == "table" then session_log[#session_log + 1] = entry end
            end
        end

        if fmt == 1 then
            for key, r in pairs(type(data.calls) == "table" and data.calls or {}) do
                load_entry(key, r, 1, prev_count)
            end
        else
            for key, r in pairs(type(data.functions) == "table" and data.functions or {}) do
                load_entry(key, r, 2, prev_count)
            end
            for name, r in pairs(type(data.methods) == "table" and data.methods or {}) do
                load_entry("game_object:" .. name, r, 2, prev_count)
            end
        end
        for key, e in pairs(type(data.events) == "table" and data.events or {}) do
            load_event(key, e, fmt)
        end
        local s = type(data.surface) == "table" and data.surface or {}
        for _, name in ipairs(type(s.object_methods) == "table" and s.object_methods or {}) do
            object_surface.methods[name] = true
        end
        -- A converted file is written in the new layout at the first save.
        if fmt ~= FORMAT then dirty = true end
    end

    local function save_check()
        if not active then return end
        local t = now()
        if (dirty or trace_dirty) and t - last_save >= SAVE_DIRTY then
            M.save()
        elseif counts_moved and t - last_save >= SAVE_COUNTS then
            M.save()
        end
    end

    -- --- control ----------------------------------------------------------

    function M.active() return active end

    --- Wraps everything and starts recording. False when already running.
    function M.start()
        if active then return false end
        if not watch.installed then install() end
        subscribe()
        active = true
        dirty = true
        last_save = now()
        if not timer_id then
            timer_id = rt.scheduler.every(SAVE_CHECK, save_check, "jcore.recorder")
        end
        if not catalog_timer then
            catalog_timer = rt.scheduler.every(CATALOG_TICK, function()
                recorder_busy = true
                local ok, err = pcall(catalog_tick)
                recorder_busy = false
                if not ok then log.fmt("debug", "catalog tick: %s", tostring(err)) end
            end, "jcore.recorder")
        end
        return true
    end

    --- Saves and stops, and puts every original back unless the watch is
    --- on (then the wrappers stay, passing calls through it).
    function M.stop()
        if not active then return end
        M.save()
        active = false
        unsubscribe()
        if not watch.on then uninstall() end
        if timer_id then
            rt.scheduler.cancel(timer_id)
            timer_id = nil
        end
        if catalog_timer then
            rt.scheduler.cancel(catalog_timer)
            catalog_timer = nil
        end
    end

    --- The watch on or off (the fault log's page). On, the wrappers go in if
    --- they are not; off with recording stopped, the originals go back.
    ---@param on boolean
    ---@return boolean watching
    function M.set_watch(on)
        on = on and true or false
        if on == watch.on then return watch.on end
        watch.on = on
        if on and not watch.installed then install() end
        if not on and not active and watch.installed then uninstall() end
        return watch.on
    end

    function M.watching() return watch.on end

    --- What the watch saw: raises and nils, with the functions that went nil
    --- most and those that raised, busiest first.
    function M.watch_stats(limit)
        limit = limit or 10
        local nulls, raised = {}, {}
        for key, rec in pairs(records) do
            if (rec.nulls or 0) > 0 then
                local sites = {}
                for site, n in pairs(rec.null_sites or {}) do sites[#sites + 1] = site .. " x" .. n end
                table.sort(sites)
                nulls[#nulls + 1] = { key = key, count = rec.nulls, sites = sites }
            end
            if (rec.raised or 0) > 0 then raised[#raised + 1] = { key = key, count = rec.raised } end
        end
        local function busiest(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.key < b.key
        end
        table.sort(nulls, busiest)
        table.sort(raised, busiest)
        for i = #nulls, limit + 1, -1 do nulls[i] = nil end
        for i = #raised, limit + 1, -1 do raised[i] = nil end
        return { watching = watch.on, installed = watch.installed, raised = watch.raised, nulls = watch.nulls,
                 top_nulls = nulls, top_raised = raised }
    end

    --- Forgets everything recorded so far, this session and the saved ones.
    function M.clear()
        for _, rec in pairs(records) do
            rec.calls, rec.session, rec.tallied, rec.empty = 0, 0, 0, 0
            rec.inspected, rec.errors = 0, 0
            rec.first_session, rec.last_session = 1, nil
            rec.args, rec.rets = {}, {}
            rec.shapes, rec.examples, rec.example_keys = {}, {}, {}
            rec.triggers, rec.n_triggers = {}, 0
            rec.effects, rec.n_effects = nil, 0
            rec.error_samples = {}
        end
        events, event_count = {}, 0
        open_windows = {}
        trace_lines, trace_head, trace_count = {}, 0, 0
        trace_seen, trace_keys, trace_skipped = {}, 0, 0
        trace_dirty = true
        sessions = 1
        session_log = {}
        for k in pairs(learned) do learned[k] = 0 end
        session_started = now()
        session_begun = local_stamp()
        dirty = true
        M.save()
    end

    function M.stats()
        local calls, functions, empty_only, erroring, actions = 0, 0, 0, 0, 0
        for _, rec in pairs(records) do
            if rec.calls > 0 then
                functions = functions + 1
                calls = calls + rec.calls
                if always_empty(rec) then empty_only = empty_only + 1 end
                if rec.kind == "action" then actions = actions + 1 end
            end
            if rec.errors > 0 then erroring = erroring + 1 end
        end
        local got = {}
        for k, v in pairs(learned) do got[k] = v end
        return {
            available = true,
            active = active,
            wrapped = #installed,
            unwritable = #surface.unwritable,
            object_index = object_surface.index,
            calls = calls,
            functions = functions,
            actions = actions,
            empty_only = empty_only,
            erroring = erroring,
            events = event_count,
            sessions = sessions,
            learned = got,
            triggers_from = getinfo and "stack" or "phase",
            trace_lines = trace_count,
            trace_skipped = trace_skipped,
            saved_at = saved_at,
            save_error = save_error,
            file = "scripts_data/" .. FILE,
        }
    end

    --- The keys whose every tallied answer was empty, busiest first.
    function M.empty_only(limit)
        local out = {}
        for key, rec in pairs(records) do
            if always_empty(rec) then
                out[#out + 1] = { key = key, calls = rec.calls }
            end
        end
        table.sort(out, function(a, b)
            if a.calls ~= b.calls then return a.calls > b.calls end
            return a.key < b.key
        end)
        local keys = {}
        for i = 1, math.min(#out, limit or #out) do keys[i] = out[i].key end
        return keys, #out
    end

    --- The keys that raised, with their first message.
    function M.erroring(limit)
        local out = {}
        for key, rec in pairs(records) do
            if rec.errors > 0 then
                local first = rec.error_samples[1]
                out[#out + 1] = { key = key, errors = rec.errors, message = first and first.error or "" }
            end
        end
        table.sort(out, function(a, b)
            if a.errors ~= b.errors then return a.errors > b.errors end
            return a.key < b.key
        end)
        local rows = {}
        for i = 1, math.min(#out, limit or #out) do rows[i] = out[i] end
        return rows, #out
    end

    --- The actions called so far, busiest first, with the event that most
    --- often followed each: { key, calls, windows, effect, followed }.
    function M.actions(limit)
        local out = {}
        for key, rec in pairs(records) do
            if rec.kind == "action" and rec.calls > 0 then
                local best, best_n = nil, 0
                for ev, n in pairs(rec.effects or {}) do
                    if ev ~= "windows" and n > best_n then best, best_n = ev, n end
                end
                out[#out + 1] = { key = key, calls = rec.calls, windows = rec.effects and rec.effects.windows or 0,
                    effect = best, followed = best_n }
            end
        end
        table.sort(out, function(a, b)
            if a.calls ~= b.calls then return a.calls > b.calls end
            return a.key < b.key
        end)
        local rows = {}
        for i = 1, math.min(#out, limit or #out) do rows[i] = out[i] end
        return rows, #out
    end

    -- --- menu page --------------------------------------------------------

    local function build_page()
        local page = rt.menu_ns.for_plugin("jambix_debug", "API recorder",
            { path = { "Jambix Debug", "API recorder" }, icon = "activity" })
        if not page.available then return page end

        local section = page:section("Forever API recorder", "list", { column = "left" })
        section:label("Records the Forever client's API as it answers: per function what triggered each call, what it answered, and what an action did (the events that followed). Only new things add rows. Saved to scripts_data/jcore/jcore.recorder.json; read it with tools/jcheck/recorder_report.js.")
        section:toggle("record", "Record calls", true)
        section:button("save", "Save now", { on_click = function() M.save() end })
        section:button("clear", "Clear recording", { on_click = function() M.clear() end })

        page:on_change("record", function(value)
            if value == false then M.stop() else M.start() end
        end)
        if page:get("record") == false then M.stop() end

        page:live_lines(LIVE_ROWS, function()
            local s = M.stats()
            local l = s.learned
            local out = {}
            out[#out + 1] = string.format("%s   %d wrapped, %d functions called (%d calls), %d events, session %d",
                s.active and "Recording" or "Stopped", s.wrapped, s.functions, s.calls, s.events, s.sessions)
            local saved = s.saved_at and string.format("saved %.0fs ago", now() - s.saved_at) or "not saved yet"
            out[#out + 1] = string.format("%s to %s%s   game objects: %s", saved, s.file,
                s.save_error and (" (" .. s.save_error .. ")") or "", tostring(s.object_index))
            out[#out + 1] = string.format("new this session: %d functions, %d examples, %d triggers, %d effects, %d events",
                l.functions, l.examples, l.triggers, l.effects, l.events)
            out[#out + 1] = string.format("triggers from the %s   trace: %d lines kept, %d repeats skipped",
                s.triggers_from == "stack" and "call stack" or "phase only", s.trace_lines, s.trace_skipped)
            local empty, n_empty = M.empty_only(3)
            out[#out + 1] = string.format("always empty: %d   %s", n_empty, table.concat(empty, ", "))
            local acts, n_acts = M.actions(2)
            local parts = {}
            for i = 1, #acts do
                local a = acts[i]
                parts[#parts + 1] = a.effect
                    and string.format("%s x%d -> %s %d/%d", a.key, a.calls, a.effect, a.followed, a.windows)
                    or string.format("%s x%d", a.key, a.calls)
            end
            out[#out + 1] = string.format("actions: %d   %s", n_acts, table.concat(parts, "; "))
            local errs, n_err = M.erroring(LIVE_ROWS - 7)
            out[#out + 1] = string.format("raising: %d", n_err)
            for i = 1, #errs do
                if #out >= LIVE_ROWS then break end
                out[#out + 1] = string.format("  %s x%d: %s", errs[i].key, errs[i].errors, errs[i].message)
            end
            return out
        end)
        return page
    end

    -- --- start ------------------------------------------------------------

    load_previous()
    M.start()

    -- The page waits for the runtime: declared now, it would sit above Core
    -- in the JCore sidebar node. A menu host that is not up yet gets one
    -- more try, as the diagnostics page does.
    -- Built after JCore was up (Jambix Debug ran late, JCore.attach_debug):
    -- jcore.ready has come and gone, so the page is declared now.
    local function page_when_ready()
        local page = build_page()
        if not page.available then
            rt.scheduler.after(2.0, function() build_page() end, "jcore.recorder")
        end
    end
    if rt.ready then
        page_when_ready()
    else
        rt.events.once("jcore.ready", page_when_ready, { owner = "jcore.recorder" })
    end

    log.fmt("info", "recording the Forever API: %d functions wrapped, %d not writable, triggers from the %s",
        #installed, #surface.unwritable, getinfo and "call stack" or "phase only")

    return M
end

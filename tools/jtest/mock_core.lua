-- mock_core -- a headless stand-in for the loader's native `core` host and
-- for the declarative `_G.menu` host, so the whole JCore runtime can boot
-- and run frames inside the offline harness (tools/jtest/run.js).
--
-- Usage from a test:
--
--     local mock = require("mock_core")
--     mock.install()                    -- _G.core, _G.menu, package.path
--     mock.wow_fs["_classic_era_/WTF/Config.wtf"] = "x"
--     require("jcore/main")
--     mock.frame(10)                    -- pre_tick, update, render per frame
--     assert(#mock.errors == 0)
--
-- Everything the runtime touches is either implemented (time, input,
-- files, http, textures, logging) or stubbed to answer nil. An unknown
-- `core.<namespace>.<name>` read is recorded in `mock.missing` and answers
-- nil, which is what the runtime's `cache.try` wrappers expect of a native
-- that a given loader build lacks.

local M = {}

-- --- clocks ----------------------------------------------------------------

M.time = 1000.0                 -- core.time(), seconds; advanced by frame()
M.frame_dt = 1 / 60
M.frame_no = 0
-- frame() runs the render_window callbacks after render, as the loader
-- paints its window pass over the game's frames. false: a loader without it.
M.window_pass = true

local cpu_counter = 0
local function cpu_time_ns()
    -- os.clock exists in fengari; a monotone counter keeps every call
    -- distinct even when the clock does not tick between two reads.
    cpu_counter = cpu_counter + 1000
    local ok, c = pcall(os.clock)
    if ok and type(c) == "number" then
        return math.floor(c * 1e9) + cpu_counter
    end
    return cpu_counter
end

-- --- input --------------------------------------------------------------

M.mouse = { x = 10, y = 10 }
M.keys = {}                     -- vk -> true while held
M.wheel = 0
M.textbox_focused = false

-- What core.get_game_version / get_exact_game_version answer. The real host
-- answers one word per product: "Vanilla", "Tbc", "Mop", "Titan", "Midnight",
-- "Forever". Set before require("jcore/main"); the world service reads it once.
M.game_version = "Vanilla"
M.exact_game_version = "wow_vanilla_us"

function M.press(vk) M.keys[vk] = true end
function M.release(vk) M.keys[vk] = nil end
function M.move(x, y) M.mouse.x, M.mouse.y = x, y end

-- --- logs ---------------------------------------------------------------

M.errors = {}
M.warnings = {}
M.logs = {}
M.missing = {}                  -- "namespace.name" -> count of reads

local function record(list, msg)
    list[#list + 1] = tostring(msg)
end

-- --- data files (scripts_data) ----------------------------------------------

M.data_fs = {}                  -- path -> contents
M.data_folders = {}             -- path -> true

local function norm(p)
    p = tostring(p or ""):gsub("\\", "/"):gsub("^%./", ""):gsub("/+", "/"):gsub("/$", "")
    return p
end

local function list_dir(fs, folders, dir)
    dir = norm(dir)
    local prefix = dir == "" and "" or (dir .. "/")
    local names, seen = {}, {}
    local function consider(path)
        if path:sub(1, #prefix) ~= prefix then return end
        local rest = path:sub(#prefix + 1)
        if rest == "" then return end
        local head = rest:match("^([^/]+)")
        if head and not seen[head] then
            seen[head] = true
            names[#names + 1] = head
        end
    end
    for path in pairs(fs) do consider(path) end
    for path in pairs(folders) do consider(path) end
    table.sort(names)
    if #names == 0 and dir ~= "" and not folders[dir] then return nil end
    return names
end

-- --- WoW folder files ---------------------------------------------------

M.wow_fs = {}                   -- path -> contents

-- --- http ---------------------------------------------------------------

M.http_log = {}                 -- urls in request order
M.http_responses = {}           -- url -> { code = 200, type = "image/png", body = "..." }
local http_pending = {}         -- delivered at the start of the next frame

local function http_request(url, headers_or_cb, cb)
    local callback = type(headers_or_cb) == "function" and headers_or_cb or cb
    M.http_log[#M.http_log + 1] = url
    http_pending[#http_pending + 1] = { url = url, callback = callback }
end

local function drain_http()
    if #http_pending == 0 then return end
    local batch = http_pending
    http_pending = {}
    for i = 1, #batch do
        local job = batch[i]
        local canned = M.http_responses[job.url]
        if canned then
            job.callback(canned.code or 200, canned.type or "application/octet-stream", canned.body or "", "")
        else
            job.callback(404, "text/plain", "", "")
        end
    end
end

-- --- textures -----------------------------------------------------------

M.textures = {}                 -- id -> { bytes = ..., kind = ..., w = ..., h = ... }
M.gifs = {}
local next_tex = 0

local function u32be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function sniff(bytes)
    if type(bytes) ~= "string" or #bytes < 4 then return nil end
    if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if bytes:sub(1, 3) == "GIF" then return "gif" end
    if bytes:sub(1, 2) == "\255\216" then return "jpg" end
    if bytes:sub(1, 2) == "BM" then return "bmp" end
    if bytes:sub(1, 4) == "BLP2" then return "blp" end
    if #bytes >= 18 then
        local image_type = bytes:byte(3)
        if image_type == 2 or image_type == 3 or image_type == 10 or image_type == 1 or image_type == 9 then
            return "tga"
        end
    end
    return nil
end
M.sniff = sniff

local function load_texture(bytes)
    local kind = sniff(bytes)
    if not kind or kind == "blp" then return nil end
    local w, h = 8, 8
    if kind == "png" and #bytes >= 24 then
        w, h = u32be(bytes, 17), u32be(bytes, 21)
    end
    next_tex = next_tex + 1
    M.textures[next_tex] = { id = next_tex, bytes = bytes, kind = kind, w = w, h = h }
    M.last_texture = M.textures[next_tex]
    return next_tex, w, h
end

local function load_gif(bytes)
    if sniff(bytes) ~= "gif" then return nil end
    next_tex = next_tex + 1
    M.gifs[next_tex] = { id = next_tex, bytes = bytes }
    return next_tex, 8, 8, 1, 100
end

-- --- draw call counters -------------------------------------------------

M.counts = {}                   -- name -> total calls
M.frame_counts = {}             -- name -> calls this frame

local function count(name)
    M.counts[name] = (M.counts[name] or 0) + 1
    M.frame_counts[name] = (M.frame_counts[name] or 0) + 1
end

local function counter(name, ...)
    local rets = { ... }
    return function()
        count(name)
        return table.unpack(rets)
    end
end

-- --- stub namespaces ----------------------------------------------------

--- A table whose listed names answer nil-returning functions and whose
--- unknown names are recorded in M.missing.
local function stub_namespace(label, names, overrides)
    local ns = {}
    for i = 1, #names do
        local name = names[i]
        ns[name] = function() return nil end
    end
    for name, fn in pairs(overrides or {}) do ns[name] = fn end
    return setmetatable(ns, {
        __index = function(_, key)
            if type(key) == "string" then
                local full = label .. "." .. key
                M.missing[full] = (M.missing[full] or 0) + 1
            end
            return nil
        end,
    })
end

-- --- vec2 -------------------------------------------------------------------

local function vec2(x, y)
    local ok, lib = pcall(require, "common/geometry/vector_2")
    if ok then return lib.new(x, y) end
    return { x = x, y = y }
end

-- --- the core table -----------------------------------------------------

M.callbacks = {
    update = {}, pre_tick = {}, render = {}, render_window = {}, render_menu = {}, render_control_panel = {},
    spell_cast = {}, legit_spell_cast = {}, game_event = {},
}

local function registrar(phase)
    return function(fn)
        local list = M.callbacks[phase]
        list[#list + 1] = fn
        return #list
    end
end

local function build_core()
    local core = {}

    core.time = function() return M.time end
    core.game_time = function() return math.floor(M.time * 1000) end
    core.cpu_time = cpu_time_ns
    core.get_ping = function() return 30 end
    core.get_map_id = function() return 0 end
    core.get_map_name = function() return "Nowhere" end
    core.get_instance_id = function() return 0 end
    core.get_instance_name = function() return "" end
    core.get_instance_type = function() return "none" end
    core.get_difficulty_id = function() return 0 end
    core.get_difficulty_name = function() return "" end
    core.get_game_version = function() return M.game_version end
    core.get_exact_game_version = function() return M.exact_game_version end
    core.get_game_region = function() return "EU" end
    core.get_local_time = function() return os.time() end
    core.get_keystone_map_id = function() return 0 end
    core.get_keystone_level = function() return 0 end
    core.is_main_menu_open = function() return false end
    core.is_textbox_focused = function() return M.textbox_focused end
    core.get_cursor_position = function() return vec2(M.mouse.x, M.mouse.y) end
    core.get_mouse_wheel_delta = function() return M.wheel end
    core.get_height_for_position = function() return 0 end

    core.log = function(msg) record(M.logs, msg) end
    core.log_warning = function(msg) record(M.warnings, msg) end
    core.log_error = function(msg) record(M.errors, msg) end
    core.log_debug = function(msg) record(M.logs, msg) end

    core.register_on_update_callback = registrar("update")
    core.register_on_pre_tick_callback = registrar("pre_tick")
    core.register_on_render_callback = registrar("render")
    core.register_on_render_window_callback = registrar("render_window")
    core.register_on_render_menu_callback = registrar("render_menu")
    core.register_on_render_control_panel_callback = registrar("render_control_panel")
    core.register_on_spell_cast_callback = registrar("spell_cast")
    core.register_on_legit_spell_cast_callback = registrar("legit_spell_cast")
    core.register_on_game_event_callback = registrar("game_event")

    -- scripts_data
    core.read_data_file = function(path) return M.data_fs[norm(path)] end
    core.read_data_file_partial = function(path, offset, size)
        local s = M.data_fs[norm(path)]
        if not s then return nil end
        return s:sub((offset or 0) + 1, (offset or 0) + (size or #s))
    end
    core.write_data_file = function(path, data)
        M.data_fs[norm(path)] = data
        return true
    end
    core.create_data_file = function(path)
        path = norm(path)
        if M.data_fs[path] == nil then M.data_fs[path] = "" end
        return true
    end
    core.create_data_folder = function(path)
        M.data_folders[norm(path)] = true
        return true
    end
    core.get_data_file_size = function(path)
        local s = M.data_fs[norm(path)]
        return s and #s or 0
    end
    core.read_dir = function(dir) return list_dir(M.data_fs, M.data_folders, dir) end
    core.delete_data_file = function(path)
        path = norm(path)
        local had = M.data_fs[path] ~= nil
        M.data_fs[path] = nil
        return had
    end

    -- WoW folder
    core.read_file = function(path) return M.wow_fs[norm(path)] end
    core.read_file_partial = function(path, offset, size)
        local s = M.wow_fs[norm(path)]
        if not s then return nil end
        return s:sub((offset or 0) + 1, (offset or 0) + (size or #s))
    end
    core.get_file_size = function(path)
        local s = M.wow_fs[norm(path)]
        return s and #s or 0
    end

    -- logs
    core.create_log_file = function() return true end
    core.write_log_file = function() return true end
    core.create_log_folder = function() return true end

    -- http
    core.http_get = http_request
    core.http_post = function(url, a, b, c)
        local callback = type(b) == "function" and b or c
        http_request(url, callback)
    end

    -- graphics
    local g = {}
    for _, name in ipairs({
        "rect_2d_filled", "rect_2d", "line_2d", "text_2d", "circle_2d", "circle_2d_filled",
        "triangle_2d_filled", "rect_3d", "rect_3d_filled", "line_3d", "text_3d", "circle_3d",
        "circle_3d_filled", "circle_3d_percentage", "cone_3d", "render_polygon_3d",
        "draw_texture", "draw_texture_rect", "draw_gif", "scissor_push", "scissor_pop",
    }) do
        g[name] = counter(name)
    end
    g.get_screen_size = function() return vec2(1920, 1080) end
    g.get_text_width = function(text, size) return #tostring(text or "") * (size or 14) * 0.55 end
    g.set_mouse_capture_state = function(state) M.mouse_captured = state and true or false end
    g.set_keyboard_capture_state = function(state) M.keyboard_captured = state and true or false end
    g.translate_vkey_to_string = function(vk) return "VK" .. tostring(vk) end
    g.load_texture = load_texture
    g.load_gif = load_gif
    g.w2s = function() return nil end
    g.is_line_of_sight = function() return false end
    g.trace_line = function() return nil end
    g.get_cursor_world_position = function() return nil end
    g.add_notification = function() return true end
    core.graphics = setmetatable(g, {
        __index = function(_, key)
            if type(key) == "string" then
                M.missing["graphics." .. key] = (M.missing["graphics." .. key] or 0) + 1
            end
            return nil
        end,
    })

    -- input
    local movement = {}
    for _, key in ipairs({ "move_forward", "move_backward", "strafe_left", "strafe_right", "turn_left",
        "turn_right", "move_up", "move_down", "descend" }) do
        movement[#movement + 1] = key .. "_start"
        movement[#movement + 1] = key .. "_stop"
    end
    local input_names = {
        "enable_movement", "disable_movement", "cancel_spells", "look_at", "look_at_3d", "set_pitch",
        "set_target", "set_focus", "get_focus", "loot_object", "skin_object", "use_object",
        "interact_with_object", "jump", "dismount", "stop_attack", "clear_afk", "release_spirit",
        "resurrect_corpse", "mount", "cancel_buff", "pet_attack", "pet_cast_target_spell",
        "pet_cast_position_spell", "pet_move_position", "set_pet_follow", "set_pet_wait",
        "set_pet_passive", "set_pet_defensive", "set_pet_aggressive", "set_pet_assist",
        "cast_target_spell", "cast_position_spell", "use_item", "use_container_item",
        "pickup_container_item", "destroy_container_item", "repair_all_items", "equip_pending_item",
        "leave_party",
    }
    for i = 1, #movement do input_names[#input_names + 1] = movement[i] end
    core.input = stub_namespace("input", input_names, {
        is_key_pressed = function(vk) return M.keys[vk] == true end,
    })

    core.object_manager = stub_namespace("object_manager", {
        "get_local_player", "get_object_from_guid", "get_mouse_over_object", "get_boss_count",
        "get_arena_target", "get_arena_opponent_spec",
    }, {
        get_visible_objects = function() return {} end,
        get_party_members = function() return {} end,
        get_party_frames = function() return {} end,
        get_arena_frames = function() return {} end,
        get_boss_frames = function() return {} end,
        get_all_missiles = function() return {} end,
    })

    core.spell_book = stub_namespace("spell_book", {
        "get_spell_name", "get_spell_min_range", "get_spell_max_range", "is_melee_spell",
        "is_spell_position_cast", "get_spell_school", "get_spell_cast_time", "get_spell_cooldown",
        "get_global_cooldown", "is_spell_known", "has_spell", "is_usable_spell", "get_spell_charge",
        "get_spell_charge_max", "is_spell_in_range", "is_rune_slot_active", "get_rune_type",
        "get_rune_info", "get_shapeshift_form_id", "get_professions", "is_item_usable",
        "has_item_range", "is_item_in_range",
    })

    core.character = stub_namespace("character", { "is_swimming", "is_resting", "get_breath" }, {
        get_realm_name = function() return "Mock" end,
    })
    core.world = stub_namespace("world", {
        "get_active_challenge_map_id", "get_active_keystone_info", "get_challenge_completion_info",
        "get_encounters_on_map", "is_flyable_area", "is_advanced_flyable_area", "is_raid_marker_active",
        "place_raid_marker", "clear_raid_marker",
    })
    core.game_ui = stub_namespace("game_ui", {
        "request_party_keystones", "register_keystone_prefix", "get_resurrect_corpse_delay",
        "get_corpse_position", "get_battlefield_state", "get_battlefield_run_time",
        "get_all_completed_quest_ids", "get_active_talents", "get_active_match_winner",
        "get_active_match_state", "get_active_match_personal_rated_info",
    })
    core.quests = stub_namespace("quests", { "is_quest_flagged_completed", "is_on_quest" })
    core.party = stub_namespace("party", { "can_invite", "invite_unit" })
    core.inventory = stub_namespace("inventory", {
        "get_gold", "get_total_repair_cost", "get_num_bag_slots", "get_items_in_bag",
        "get_item_durability", "can_merchant_repair",
    })
    core.delves = stub_namespace("delves", { "is_in_delve", "is_delve_complete" })
    core.damage_meter = stub_namespace("damage_meter", {}, {
        is_available = function() return false end,
    })
    core.addons = {}

    -- The only menu-host object the runtime creates itself: a native
    -- window used for its clipboard methods.
    M.clipboard = ""
    core.menu = {
        window = function(id)
            return {
                id = id,
                copy_to_clipboard = function(_, s) M.clipboard = tostring(s) return true end,
                get_clipboard_text = function() return M.clipboard end,
            }
        end,
    }

    return setmetatable(core, {
        __index = function(_, key)
            if type(key) == "string" then
                M.missing[key] = (M.missing[key] or 0) + 1
            end
            return nil
        end,
    })
end

-- --- the declarative menu host -----------------------------------------------

--- A minimal `_G.menu`: pages with sections, widgets that record their
--- declared defaults so `menu:get` answers them, `menu:set` fires observers,
--- and live title providers that a frame can evaluate.
local function build_menu()
    local menu = {
        values = {},        -- page_path -> id -> value
        observers = {},     -- page_path -> id -> { fn, ... }
        titles = {},        -- { path, fn } for every function-valued title
        pages = {},         -- page_path -> page
        categories = {},
        title_errors = {},
        widget_opts = {},   -- page_path -> id -> the opts it was declared with
    }

    local function path_key(path)
        if type(path) == "table" then return table.concat(path, "/") end
        return tostring(path)
    end

    local function bucket(t, key)
        local b = t[key]
        if not b then b = {}; t[key] = b end
        return b
    end

    local Section = {}
    Section.__index = Section

    local function declare(section, id, value, opts)
        local values = bucket(menu.values, section.page_path)
        if values[id] == nil then values[id] = value end
        if opts ~= nil then bucket(menu.widget_opts, section.page_path)[id] = opts end
        return section
    end

    function Section:toggle(id, _, default, opts) return declare(self, id, default and true or false, opts) end
    Section.checkbox = Section.toggle
    function Section:slider(id, _, _, _, default, _, opts) return declare(self, id, default or 0, opts) end
    Section.slider_int = Section.slider
    Section.slider_float = Section.slider
    function Section:dropdown(id, _, _, default, opts) return declare(self, id, default or 1, opts) end
    Section.combobox = Section.dropdown
    function Section:keybind(id, _, default) return declare(self, id, { vk = default or 0, active = false, toggled = false }) end
    function Section:text_input(id, _, default, opts) return declare(self, id, default or "", opts) end
    function Section:color(id, _, default, opts) return declare(self, id, default or { r = 255, g = 255, b = 255, a = 255 }, opts) end
    Section.color_picker = Section.color
    function Section:button(id, _, opts)
        self.buttons = self.buttons or {}
        self.buttons[id] = opts
        return self
    end
    function Section:icon_button(id, _, opts) return self:button(id, nil, opts) end
    function Section:label() return self end
    function Section:progress(id) return declare(self, id, 0) end
    function Section:separator() return self end
    function Section:spacer() return self end
    function Section:header() return self end
    function Section:live() return self end
    function Section:image() return self end
    function Section:list(id, _, _, default) return declare(self, id, default or 0) end
    function Section:tree_node() return self end
    function Section:end_tree_node() return self end

    local Page = {}
    Page.__index = Page

    function Page:section(title, icon, opts)
        local section = setmetatable({ title = title, icon = icon, opts = opts, page_path = self.page_path }, Section)
        self.sections[#self.sections + 1] = section
        return section
    end

    function Page:title(text, opts)
        if type(text) == "function" then
            menu.titles[#menu.titles + 1] = { path = self.page_path, fn = text, opts = opts }
        end
        return self
    end

    function Page:button(id, _, opts)
        self.buttons[id] = opts
        return self
    end
    Page.icon_button = Page.button

    function Page:on_change(id, fn)
        local list = bucket(bucket(menu.observers, self.page_path), id)
        list[#list + 1] = fn
        return true
    end

    function Page:get(id) return menu:get(self.page_path, id) end
    function Page:set(id, v) return menu:set(self.page_path, id, v) end

    --- Is this declared widget shown? Its `visible` option, when it has one.
    function menu:visible(path, id)
        local o = (menu.widget_opts[path_key(path)] or {})[id]
        if type(o) ~= "table" or o.visible == nil then return true end
        if type(o.visible) == "function" then return o.visible() == true end
        return o.visible == true
    end

    function menu:category(path, opts)
        self.categories[path_key(path)] = opts or {}
        return self
    end

    function menu:page(path, meta)
        local key = path_key(path)
        local page = self.pages[key]
        if page then return page end
        page = setmetatable({ page_path = key, meta = meta or {}, sections = {}, buttons = {} }, Page)
        self.pages[key] = page
        return page
    end

    function menu:get(path, id)
        local values = self.values[path_key(path)]
        if not values then return nil end
        return values[id]
    end

    function menu:set(path, id, value)
        local key = path_key(path)
        local values = bucket(self.values, key)
        local old = values[id]
        if old == value then return true end
        values[id] = value
        local list = self.observers[key] and self.observers[key][id]
        if list then
            for i = 1, #list do list[i](value, old) end
        end
        return true
    end

    function menu:on_change(path, id, fn)
        local list = bucket(bucket(self.observers, path_key(path)), id)
        list[#list + 1] = fn
        return true
    end

    function menu:is_cursor_over_ui() return false end
    function menu:is_surface_open() return false end
    function menu:is_open() return false end

    --- Evaluates every live title provider once, as the host would when the
    --- menu is drawn. Failures are collected rather than raised.
    function menu:render_titles()
        for i = 1, #self.titles do
            local t = self.titles[i]
            local ok, result = pcall(t.fn)
            if not ok then
                self.title_errors[#self.title_errors + 1] = t.path .. ": " .. tostring(result)
            elseif type(result) ~= "string" then
                self.title_errors[#self.title_errors + 1] = t.path .. ": title returned " .. type(result)
            end
        end
    end

    return menu
end

-- --- install and frames -------------------------------------------------

function M.install()
    local root = (jtest and jtest.root) or "."
    local mock_dir = root .. "/tools/jtest/mock/?.lua"
    if not package.path:find(mock_dir, 1, true) then
        package.path = mock_dir .. ";" .. package.path
    end
    M.core = build_core()
    M.menu = build_menu()
    _G.core = M.core
    _G.menu = M.menu
    -- JCore 1.8.1 runs no pass until a local player is valid (its world
    -- gate). Most tests have no player, so the harness opens the gate; a
    -- test of the gate sets this back to nil before require("jcore/main").
    _G.JCORE_NO_WORLD_GATE = true
    return M
end

local function run(list, ...)
    for i = 1, #list do
        list[i](...)
    end
end

--- Runs `n` frames (default 1): time advances, pending http completions
--- deliver, then every registered pre_tick, update, render and (while
--- M.window_pass) render_window callback runs in that order, exactly as the
--- loader would call them.
function M.frame(n)
    for _ = 1, n or 1 do
        M.frame_no = M.frame_no + 1
        M.time = M.time + M.frame_dt
        M.frame_counts = {}
        drain_http()
        run(M.callbacks.pre_tick)
        run(M.callbacks.update)
        run(M.callbacks.render)
        if M.window_pass then run(M.callbacks.render_window) end
        M.wheel = 0
    end
end

--- Fires a native game event through the registered hooks.
function M.game_event(name, args)
    run(M.callbacks.game_event, name, args)
end

--- Everything logged as an error so far, joined for an assertion message.
function M.error_text()
    return table.concat(M.errors, "\n")
end

return M

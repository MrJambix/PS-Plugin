-- JAMBIX DEBUG (1.0.0): moved here from JCore's services/dump.lua with JCore
-- 1.7.0, so users do not get it. Still a factory of JCore's runtime, built by
-- JCore's main.lua when this plugin is there (see jambix_debug/main.lua). Its
-- page sits under "Jambix Debug" in the sidebar; its files stay in
-- scripts_data/jcore/, so the tools in tools/jcheck read them as before.
--
-- Jambix Debug / dump -- everything the running client says about this character's
-- spells and talents, and which API it has, written to one file on demand
-- (JCore 1.6.0). Pressed on the Dump page; nothing runs until then, on any
-- client.
--
-- WHY. Forever is the classic world on the retail engine, with new spells,
-- trait-tree talents and a different API. Dump the same class on Forever and
-- on Era, then diff the two files offline:
--
--   node tools/jcheck/dump_diff.js scripts_data/jcore/jcore.dump.forever.json \
--        scripts_data/jcore/jcore.dump.vanilla.json --md
--
-- WHAT IS IN IT (scripts_data/jcore/jcore.dump.<client>.json)
--   client     version, exact build string, the world.client() flags
--   character  class, race, level, specialization
--   spells     every spellbook entry the client names: id, name, known (and
--              how: is_spell_known / has_spell / is_spell_learned), base and
--              override id, school, cast time, base cooldown, costs, ranges,
--              melee, position cast, its tooltip
--   pet        the pet's spellbook, as the client gives it
--   talents    Era's classic tabs (every talent: name, rank, max, its spell);
--              Forever's trait trees (every node: type, ranks, entries,
--              availability), the active talents (with spell id and name),
--              unspent points
--   api        every core.* function by namespace, and every game_object
--              method, as this client exposes them
-- Only getters are called. Nothing is learned, bought, cast or changed.

local MAX_DEPTH = 6

return function(rt)
    local log = rt.log.for_tag("JambixDebug/dump")

    local M = {}

    local function call(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, a = pcall(fn, ...)
        if ok then return a end
        return nil
    end

    --- A value as JSON can hold it: numbers, strings, booleans, and tables of
    --- those. Game objects and functions become a word.
    local function plain(v, depth)
        depth = depth or 0
        local t = type(v)
        if t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
            return v
        end
        if t == "string" or t == "boolean" or t == "nil" then return v end
        if t == "table" then
            if depth >= MAX_DEPTH then return "(table)" end
            local out = {}
            for k, x in pairs(v) do
                local key = (type(k) == "number" or type(k) == "string") and k or tostring(k)
                out[key] = plain(x, depth + 1)
            end
            return out
        end
        return "(" .. t .. ")"
    end

    local function client_tag(c)
        local v = type(c) == "table" and tostring(c.version or "") or ""
        if v == "" then return "unknown" end
        return v:lower():gsub("[^%w]", "")
    end

    -- --- spells ---------------------------------------------------------------

    local function spell_row(book, id)
        local name = call(book.get_spell_name, id)
        if type(name) ~= "string" or name == "" then return nil end
        local known = call(book.is_spell_known, id)
        local row = {
            id = id,
            name = name,
            known = known == true,
            has_spell = call(book.has_spell, id) == true,
            learned = plain(call(book.is_spell_learned, id)),
            base_id = plain(call(book.get_base_spell_id, id)),
            override_id = plain(call(book.get_override_spell_id, id)),
            school = plain(call(book.get_spell_school, id)),
            cast_time = plain(call(book.get_spell_cast_time, id)),
            cooldown = plain(call(book.get_spell_base_cooldown, id)),
            costs = plain(call(book.get_spell_costs, id)),
            min_range = plain(call(book.get_spell_min_range, id)),
            max_range = plain(call(book.get_spell_max_range, id)),
            melee = plain(call(book.is_melee_spell, id)),
            position_cast = plain(call(book.is_spell_position_cast, id)),
            description = plain(call(book.get_spell_description, id)),
        }
        return row
    end

    local function spells()
        local book = core.spell_book
        if type(book) ~= "table" then return {} end
        local list = call(book.get_spells)
        local out, seen = {}, {}
        local count = type(list) == "table" and #list or 0
        local function consider(id, position)
            if type(id) ~= "number" or id <= 0 or seen[id] then return end
            seen[id] = true
            local row = spell_row(book, id)
            if row then
                -- An array position the client names (1..N) is a GM spell nobody
                -- has, not an entry of the book: kept, but marked.
                if position then row.position_only = true end
                out[#out + 1] = row
            end
        end
        if type(list) == "table" then
            for k, v in pairs(list) do
                consider(v, false)
                consider(k, type(k) == "number" and k >= 1 and k <= count)
            end
        end
        table.sort(out, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            return a.id < b.id
        end)
        return out
    end

    -- --- talents ----------------------------------------------------------------

    local function talents()
        local ui = core.game_ui
        local book = core.spell_book
        local t = {}
        if type(ui) ~= "table" then return t end
        t.unspent = plain(call(ui.get_unspent_talent_points))
        t.specialization = plain(call(ui.get_specialization))
        t.active = plain(call(ui.get_active_talents))

        -- Era: the classic tabs.
        local tabs = tonumber((call(ui.get_num_talent_tabs))) or 0
        t.classic = { tabs = tabs }
        for tab = 1, math.min(tabs, 5) do
            local entry = { info = plain(call(ui.get_talent_tab_info, tab)), talents = {} }
            local n = tonumber((call(ui.get_num_talents, tab))) or 0
            for i = 1, math.min(n, 60) do
                local info = call(ui.get_talent_info, tab, i)
                local row = plain(info)
                if type(row) ~= "table" then row = { value = row } end
                local talent_id = type(info) == "table" and tonumber(info.talent_id) or nil
                if talent_id and type(book) == "table" then
                    row.spell_id = plain(call(book.get_talent_spell_id, talent_id))
                    row.talent_name = plain(call(book.get_talent_name, talent_id))
                end
                row.prereqs = plain(call(ui.get_talent_prereqs, tab, i))
                entry.talents[i] = row
            end
            t.classic[tab] = entry
        end

        -- Forever (and retail): the trait trees, every node.
        local trees = call(ui.get_talent_tree_ids)
        t.tree_ids = plain(trees)
        t.trees = {}
        if type(trees) == "table" then
            for i = 1, math.min(#trees, 8) do
                local tree = trees[i]
                local nodes = call(ui.get_talent_tree_nodes, tree)
                local rows = {}
                if type(nodes) == "table" then
                    for j = 1, math.min(#nodes, 600) do
                        local node = nodes[j]
                        local info = plain(call(ui.get_talent_node_info, node))
                        if type(info) ~= "table" then info = { node_id = node } end
                        rows[#rows + 1] = info
                    end
                end
                t.trees[tostring(tree)] = rows
            end
        end
        return t
    end

    -- --- the API surface ----------------------------------------------------------

    local function sorted_keys(tbl, want)
        local out = {}
        for k, v in pairs(tbl) do
            if type(k) == "string" and (want == nil or type(v) == want) then out[#out + 1] = k end
        end
        table.sort(out)
        return out
    end

    local function api_surface()
        local out = { core = {}, game_object = {} }
        if type(core) ~= "table" then return out end
        out.core["(root)"] = sorted_keys(core, "function")
        for _, ns in ipairs(sorted_keys(core, "table")) do
            local tbl = core[ns]
            out.core[ns] = sorted_keys(tbl, "function")
            for _, sub in ipairs(sorted_keys(tbl, "table")) do
                out.core[ns .. "." .. sub] = sorted_keys(tbl[sub], "function")
            end
        end
        -- The game_object methods, through the local player's metatable.
        local player = call(core.object_manager and core.object_manager.get_local_player)
        if player then
            local mt = getmetatable(player)
            local index = type(mt) == "table" and mt.__index or nil
            if type(index) == "table" then out.game_object = sorted_keys(index, "function") end
            if type(player) == "table" then
                local own = sorted_keys(player, "function")
                if #own > 0 then out.game_object_own = own end
            end
        end
        return out
    end

    -- --- the dump ---------------------------------------------------------------

    local last = nil

    --- Writes the dump. Returns the file name and the counts, or nil and why.
    ---@return string|nil filename
    ---@return table|string counts_or_error
    function M.dump()
        local world = rt.world
        local c = world and world.client and call(world.client) or {}
        local player = rt.player
        local doc = {
            format = 1,
            jcore = rt.VERSION,
            client = plain(c),
            exact = c and c.exact or nil,
            character = {
                class_id = player and call(player.class_id) or nil,
                race_id = player and call(player.race_id) or nil,
                level = player and call(player.level) or nil,
                spec_id = player and call(player.spec_id) or nil,
            },
        }
        local ok_s, s = pcall(spells)
        doc.spells = ok_s and s or { error = tostring(s) }
        doc.pet = plain(call(core.spell_book and core.spell_book.get_pet_spells))
        local ok_t, t = pcall(talents)
        doc.talents = ok_t and t or { error = tostring(t) }
        local ok_a, a = pcall(api_surface)
        doc.api = ok_a and a or { error = tostring(a) }

        local filename = "jcore/jcore.dump." .. client_tag(c) .. ".json"
        local storage = rt.storage
        if not (storage and storage.write_json) then return nil, "no storage" end
        if not storage.write_json(filename, doc, true) then return nil, "could not write " .. filename end
        local nodes = 0
        for _, rows in pairs(type(doc.talents.trees) == "table" and doc.talents.trees or {}) do nodes = nodes + #rows end
        local functions = 0
        for _, list in pairs(type(doc.api.core) == "table" and doc.api.core or {}) do functions = functions + #list end
        last = {
            filename = filename,
            spells = type(doc.spells) == "table" and #doc.spells or 0,
            tabs = type(doc.talents.classic) == "table" and doc.talents.classic.tabs or 0,
            nodes = nodes,
            functions = functions,
            methods = type(doc.api.game_object) == "table" and #doc.api.game_object or 0,
        }
        log.fmt("info", "dump: %d spells, %d talent tabs, %d trait nodes, %d core functions, %d object methods -> %s",
            last.spells, last.tabs, last.nodes, last.functions, last.methods, filename)
        return filename, last
    end

    function M.last() return last end

    -- The click-to-move probe (JCore 1.6.13) is gone (Jambix Debug 1.1.0):
    -- it called core.input.cm, which is not in scripts/.api. The user,
    -- 2026-10-12: "if its not in the .api remove it from game calls".

    -- --- menu page --------------------------------------------------------------

    local function build_page()
        local menu_ns = rt.menu_ns
        if not (menu_ns and menu_ns.for_plugin) then return end
        local page = menu_ns.for_plugin("jambix_debug", "Dump", { path = { "Jambix Debug", "Dump" }, icon = "download" })
        if not page.available then return end
        local section = page:section("Spells, talents and API", "list", { column = "left" })
        section:label("Writes what this client says about your character's spells and talents, with their ids, and which API it exposes, to scripts_data/jcore/jcore.dump.<client>.json. Dump the same class on Forever and on Era, then compare them with tools/jcheck/dump_diff.js. Only getters are called.")
        section:button("dump", "Dump now", { on_click = function()
            local ok, file, info = pcall(M.dump)
            if not ok then log.fmt("error", "dump failed: %s", tostring(file)) end
            if ok and not file then log.fmt("warn", "dump: %s", tostring(info)) end
        end })
        -- The corpse and loot-window study (services/lootstudy.lua, 1.6.8).
        local study = rt.lootstudy
        if study then
            local s2 = page:section("Corpses and loot windows", "list", { column = "left" })
            s2:label("Records how this client marks a corpse that has loot (every read of every corpse within 40 yd, each change with what was happening) and how each loot window was opened (our press or yours, what the mouseover, target and soft-interact pointed at, the events before it, the slots). Each client writes its own file, scripts_data/jcore/jcore.lootstudy.<client>.json, after each loot window closes: run it on Forever, Season of Discovery and Retail, then compare them with tools/jcheck/lootstudy_diff.js. Only getters are called.")
            s2:toggle("lootstudy", "Study corpses and loot windows", study.enabled())
            s2:button("lootstudy_write", "Write now", { on_click = function()
                local ok, file, err = pcall(study.write)
                if not ok then log.fmt("error", "lootstudy failed: %s", tostring(file)) end
                if ok and not file then log.fmt("warn", "lootstudy: %s", tostring(err)) end
            end })
            page:on_change("lootstudy", function(value) study.set_enabled(value ~= false) end)
            local value = page:get("lootstudy")
            if value ~= nil then study.set_enabled(value ~= false) end
        end
        page:live_lines(2, function()
            local l = last
            local out = {}
            out[1] = l and string.format("Last dump: %d spells, %d talent tabs, %d trait nodes, %d functions, %d methods -> %s",
                l.spells, l.tabs, l.nodes, l.functions, l.methods, l.filename) or "Not dumped yet this session."
            local s = study and study.stats and study.stats() or nil
            if s then
                out[2] = string.format("Corpse study: %s, %d corpses, %d changes, %d windows%s", s.enabled and "on" or "off",
                    s.corpses, s.changes, s.windows, s.file and (" -> " .. s.file) or (s.error and (" (" .. s.error .. ")") or ""))
            end
            return out
        end)
    end
    pcall(build_page)

    return M
end

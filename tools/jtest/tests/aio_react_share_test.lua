-- Jambix AIO: reactions imported from a GitHub link, and exported to files
-- (1.77.2).
--
-- The whole plugin on top of JCore under mock_core, as an Era hunter. The
-- link is read the way a player pastes it; GitHub's tree API and
-- raw.githubusercontent.com are canned answers in mock_core's http table;
-- what is found is checked before anything is saved, imported into the
-- hunter's list (and a mage's, for a file of the mage's), and drawn in the
-- Reactions window's Import view. Export writes files Import reads back.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local NAMES = { [5384] = "Feign Death", [1978] = "Serpent Sting", [2973] = "Raptor Strike" }

local function hunter()
    local p = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001",
        get_name = "Hunter", get_class = 3, get_race_id = 1, get_level = 30,
        get_health = 900, get_max_health = 1000, get_power = 800, get_max_power = 1000,
        is_moving = false, is_mounted = false, is_in_combat = false, is_casting_spell = false,
        is_channelling_spell = false, is_auto_attacking = false, can_attack = false,
        get_rotation = 0, get_classification = 0, get_attack_speed = 2.8,
        get_auras = {}, get_buffs = {}, get_debuffs = {},
        get_loss_of_control_info = { valid = false },
        get_unit_ranged_damage = { speed = 2.8 },
        get_active_spell_cast_end_time = 0, get_active_channel_cast_end_time = 0,
        is_player = true, is_unit = true, get_type = 6,
    }
    local obj = {}
    for k, v in pairs(p) do obj[k] = function() return v end end
    obj.get_position = function() return { x = 100, y = 100, z = 0 } end
    return setmetatable(obj, { __index = function() return function() return nil end end })
end

local T = {}
local b, C, S

local TREE_URL = "https://api.github.com/repos/alice/packs/git/trees/HEAD?recursive=1"
local function raw(path) return "https://raw.githubusercontent.com/alice/packs/HEAD/" .. path end

local PANIC = [[{
  "format": "jambix-reaction", "version": 1,
  "name": "Panic button", "importance": "survival", "priority": 500, "combat_only": false,
  "description": "Feign Death when it goes wrong",
  "conds": [ { "mode": "gui", "key": "me_hp", "op": "<", "value": 30 },
             { "mode": "gui", "key": "no_such_condition", "op": "is" },
             { "mode": "lua", "code": "return fight.on_me >= 2" } ],
  "actions": [ { "mode": "gui", "kind": "spell", "spell": "Feign Death", "target": "self" },
               { "mode": "gui", "kind": "teleport_home" } ],
  "env": { "arena": false, "raid_pick": "Molten Core", "nonsense": 5 }
}]]

local PACK = [[{
  "format": "jambix-reaction", "version": 1, "class": "Hunter", "author": "alice",
  "reactions": [
    { "name": "Deter the melee", "importance": "defensive",
      "conds": [ { "mode": "gui", "key": "me_attackers", "op": ">=", "value": 2 } ],
      "actions": [ { "mode": "gui", "kind": "spell", "spell": "Deterrence", "target": "self" } ] },
    { "name": "Trap the add", "importance": "cc",
      "actions": [ { "mode": "gui", "kind": "lua_fn", "fn": "trap_the_add" } ] }
  ]
}]]

local NOVA = [[{ "name": "Nova when surrounded", "importance": "cc",
  "conds": [ { "mode": "gui", "key": "me_attackers", "op": ">=", "value": 3 } ],
  "actions": [ { "mode": "gui", "kind": "spell", "spell": "Frost Nova", "target": "self" } ] }]]

local LIBRARY = "function trap_the_add()\n    return cast(\"Freezing Trap\", \"attacker\")\nend\n"

local function serve_repo()
    local json = b.JCore.json
    local tree = {
        { path = "README.md", type = "blob", size = 10 },
        { path = "Reaction", type = "tree" },
        { path = "Reaction/panic.json", type = "blob", size = #PANIC },
        { path = "Reaction/pack.json", type = "blob", size = #PACK },
        { path = "Reaction/broken.json", type = "blob", size = 9 },
        { path = "Reaction/Mage", type = "tree" },
        { path = "Reaction/Mage/nova.json", type = "blob", size = #NOVA },
        { path = "Reaction/library.lua", type = "blob", size = #LIBRARY },
        { path = "Reaction/notes.txt", type = "blob", size = 5 },
        { path = "other/elsewhere.json", type = "blob", size = 5 },
    }
    local R = b.mock.http_responses
    R[TREE_URL] = { code = 200, type = "application/json", body = json.encode({ sha = "x", tree = tree, truncated = false }) }
    R[raw("Reaction/panic.json")] = { code = 200, body = PANIC }
    R[raw("Reaction/pack.json")] = { code = 200, body = PACK }
    R[raw("Reaction/broken.json")] = { code = 200, body = "{ nope" }
    R[raw("Reaction/Mage/nova.json")] = { code = 200, body = NOVA }
    R[raw("Reaction/library.lua")] = { code = 200, body = LIBRARY }
end

local function settle(label)
    for _ = 1, 40 do
        b.mock.frame(1)
        if S.job and not S.job.busy then return end
    end
    error(label .. ": the fetch never finished (status: " .. tostring(S.job and S.job.status) .. ")", 2)
end

local function item(name)
    for _, it in ipairs(S.job.items) do
        if it.name == name then return it end
    end
    return nil
end

local function has_note(it, part)
    for _, n in ipairs(it.notes or {}) do
        if n:find(part, 1, true) then return true end
    end
    return false
end

T[#T + 1] = { "boot: a hunter, and the share module loaded with the reactions", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" })
    local me = hunter()
    core.object_manager.get_local_player = function() return me end
    core.spell_book.get_spells = function() return { 5384, 1978, 2973 } end
    core.spell_book.get_spell_name = function(id) return NAMES[id] end
    core.spell_book.is_spell_known = function(id) return NAMES[id] ~= nil end
    core.spell_book.is_usable_spell = function(id) return NAMES[id] ~= nil end
    core.spell_book.get_spell_cooldown = function() return 0 end
    b.P.spellbook.refresh()
    b.mock.frame(10)
    C = b.P.react.custom
    S = C.share
    assert(S, "custom.share is there")
    assert_eq(C.class(), "HUNTER", "the class")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "links: a repository, a folder, one file, raw, and what is not a GitHub link", function()
    local l = assert(S.parse_link("https://github.com/alice/packs"))
    assert_eq(l.owner .. "/" .. l.repo .. "@" .. l.ref .. ":" .. l.path, "alice/packs@HEAD:", "plain repository")
    l = assert(S.parse_link("  github.com/alice/packs.git/  "))
    assert_eq(l.repo, "packs", ".git and slashes trimmed")
    l = assert(S.parse_link("https://www.github.com/alice/packs/tree/main/stuff/Reaction?tab=readme"))
    assert_eq(l.ref .. ":" .. l.path, "main:stuff/Reaction", "a folder on a branch")
    l = assert(S.parse_link("https://github.com/alice/packs/blob/dev/Reaction/My%20Panic.json"))
    assert_eq(l.ref .. ":" .. l.file, "dev:Reaction/My Panic.json", "one file, unescaped")
    l = assert(S.parse_link("https://raw.githubusercontent.com/alice/packs/main/Reaction/panic.json"))
    assert_eq(l.ref .. ":" .. l.file, "main:Reaction/panic.json", "a raw link")
    for _, bad in ipairs({ "", "https://gitlab.com/alice/packs", "github.com/alice",
        "https://github.com/alice/packs/blob/main/README.md", "https://github.com/alice/pa cks" }) do
        local got, err = S.parse_link(bad)
        assert(got == nil and type(err) == "string" and err ~= "", "refused: " .. bad)
    end
end }

T[#T + 1] = { "the folder: Reaction or Reactions in any case, the shallowest under the link's path", function()
    local tree = {
        { path = "docs", type = "tree" }, { path = "deep/x/Reaction", type = "tree" },
        { path = "REACTIONS", type = "tree" }, { path = "sub", type = "tree" }, { path = "sub/reaction", type = "tree" },
    }
    assert_eq(S.find_folder(tree, ""), "REACTIONS", "the top one")
    assert_eq(S.find_folder(tree, "sub"), "sub/reaction", "under the link's path")
    assert_eq(S.find_folder(tree, "sub/reaction"), "sub/reaction", "the link is the folder")
    assert_eq(S.find_folder({ { path = "docs", type = "tree" } }, ""), nil, "none")
    local files, libs = S.pick_files({
        { path = "R/a.json", type = "blob" }, { path = "R/Mage/b.json", type = "blob" },
        { path = "R/x/y/c.json", type = "blob" }, { path = "R/library_mage.lua", type = "blob" },
        { path = "R/readme.md", type = "blob" },
    }, "R")
    assert_eq(#files, 2, "the folder and one level down")
    assert_eq(files[1].class, "MAGE", "a class's subfolder gives its files the class")
    assert_eq(#libs, 1, "a Library")
    assert_eq(libs[1].class, "MAGE", "library_mage.lua is the mage's")
end }

T[#T + 1] = { "a file is checked: unknown rows left out and said, numbers held in range, Lua kept and marked", function()
    local list = assert(S.decode(PANIC))
    assert_eq(#list, 1, "one reaction")
    local it = list[1]
    assert_eq(it.class, nil, "no class: it goes to whoever imports it")
    local r = it.r
    assert_eq(r.name, "Panic button", "name")
    assert_eq(r.priority, 120, "priority held to 120")
    assert_eq(r.combat_only, false, "combat_only")
    assert_eq(#r.conds, 2, "the unknown condition left out")
    assert_eq(r.conds[2].mode, "lua", "the Lua condition kept")
    assert_eq(it.lua, true, "marked as having Lua")
    assert_eq(#r.actions, 1, "the unknown action left out")
    assert_eq(r.actions[1].target, "self", "target")
    assert(has_note(it, "no_such_condition"), "the left-out condition is named")
    assert(has_note(it, "teleport_home"), "the left-out action is named")
    assert_eq(r.env.arena, false, "where: arenas off")
    assert_eq(r.env.raid_pick, "Molten Core", "where: the raid")
    assert_eq(r.env.nonsense, nil, "where: nothing unknown")
    local pack = assert(S.decode(PACK))
    assert_eq(#pack, 2, "a pack")
    assert_eq(pack[1].class, "HUNTER", "the pack's class, any case")
    assert_eq(pack[1].author, "alice", "the pack's author")
    local none, err = S.decode("{ nope")
    assert(none == nil and err:find("not JSON", 1, true), "bad JSON: " .. tostring(err))
    none, err = S.decode('{ "format": "something-else", "name": "x" }')
    assert(none == nil and err:find("format", 1, true), "another format: " .. tostring(err))
end }

T[#T + 1] = { "fetch: one tree call, the Reaction folder's files from raw, a class's subfolder, the author's Library", function()
    serve_repo()
    local before = #b.mock.http_log
    assert(S.fetch("https://github.com/alice/packs"), "started")
    assert(S.job.busy, "busy while it reads")
    settle("fetch")
    assert_eq(S.job.err, nil, "no error")
    local api_calls = 0
    for i = before + 1, #b.mock.http_log do
        local url = b.mock.http_log[i]
        if url:find("api.github.com", 1, true) then api_calls = api_calls + 1 end
        assert(not url:find("elsewhere", 1, true) and not url:find("notes.txt", 1, true), "only the folder's .json and Library: " .. url)
    end
    assert_eq(api_calls, 1, "one API call")
    assert_eq(S.job.found, 4, "four reactions: panic, the pack's two, the mage's nova")
    local broken
    for _, it in ipairs(S.job.items) do if it.file == "Reaction/broken.json" then broken = it end end
    assert(broken and broken.err, "the broken file is listed, with why")
    assert_eq(item("Nova when surrounded").class, "MAGE", "the Mage subfolder")
    assert_eq(#S.job.libraries, 1, "the Library")
    assert(has_note(item("Deter the melee"), "Deterrence is not in your spellbook"), "a spell the hunter lacks")
    assert(has_note(item("Trap the add"), "trap_the_add() is in the Library that comes with it"), "the function's Library")
    assert(not has_note(item("Nova when surrounded"), "spellbook"), "a mage's spells are not checked against a hunter's book")
    assert(item("Panic button").pick, "picked to start with")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "import: switched off, named apart from what you have, the mage's to the mage, the Library added once", function()
    -- One of yours already has the name.
    C.save({ name = "Panic button", importance = "survival",
        actions = { { mode = "gui", kind = "spell", spell = "Feign Death", target = "self" } } })
    local n0 = #C.list()
    item("Trap the add").pick = true
    local done = assert(S.import({ switch_on = false, add_library = true }))
    assert_eq(done.mine, 3, "three to the hunter")
    assert_eq(done.other.MAGE, 1, "one to the mage")
    assert_eq(done.libraries, 1, "the Library")
    assert_eq(#C.list(), n0 + 3, "in the hunter's list")
    local names = {}
    for _, r in ipairs(C.list()) do names[r.name] = r end
    local imported = names["Panic button (2)"]
    assert(imported, "the second Panic button comes in with a number")
    assert_eq(imported.on, false, "switched off")
    assert_eq(imported.source.repo, "github.com/alice/packs", "where it came from")
    assert_eq(imported.source.file, "Reaction/panic.json", "and its file")
    local mage = C.bucket("MAGE")
    assert_eq(#mage.custom, 1, "the mage's list")
    assert_eq(mage.custom[1].name, "Nova when surrounded", "the mage's reaction")
    assert(mage.custom[1].id, "with an id")
    assert(C.library():find("-- From github.com/alice/packs (Reaction/library.lua)", 1, true), "the Library, under where it came from")
    assert(C.library_state().fns and #C.library_state().fns >= 1, "its functions are there")
    -- Again: nothing more comes in.
    local again = S.import({ add_library = true })
    assert_eq(again.total, 0, "already imported")
    local _, count = C.library():gsub("%-%- From github.com/alice/packs", "")
    assert_eq(count, 1, "the Library once")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "what goes wrong is said: no repository, no Reaction folder, GitHub's hourly limit, no connection", function()
    local R = b.mock.http_responses
    S.fetch("https://github.com/alice/missing")
    settle("missing")
    assert(S.job.err and S.job.err:find("no such repository", 1, true), "404: " .. tostring(S.job.err))
    R["https://api.github.com/repos/alice/plain/git/trees/HEAD?recursive=1"] = { code = 200,
        body = b.JCore.json.encode({ tree = { { path = "src", type = "tree" }, { path = "src/a.lua", type = "blob" } } }) }
    S.fetch("github.com/alice/plain")
    settle("plain")
    assert(S.job.err and S.job.err:find("no folder called Reaction", 1, true), "no folder: " .. tostring(S.job.err))
    R["https://api.github.com/repos/alice/busy/git/trees/HEAD?recursive=1"] = { code = 403, body = "{}" }
    S.fetch("github.com/alice/busy")
    settle("busy")
    assert(S.job.err and S.job.err:find("60 lookups", 1, true), "403: " .. tostring(S.job.err))
    R["https://api.github.com/repos/alice/offline/git/trees/HEAD?recursive=1"] = { code = 6, body = "" }
    S.fetch("github.com/alice/offline")
    settle("offline")
    assert(S.job.err and S.job.err:find("Could not reach GitHub", 1, true), "curl error: " .. tostring(S.job.err))
    S.fetch("https://gitlab.com/alice/packs")
    assert(not S.job.busy and S.job.err, "a link that is not GitHub's is refused at once")
    -- One file, no API call.
    local before = #b.mock.http_log
    b.mock.http_responses["https://raw.githubusercontent.com/alice/packs/main/Reaction/one.json"] = { code = 200, body = NOVA }
    S.fetch("https://github.com/alice/packs/blob/main/Reaction/one.json")
    settle("one file")
    assert_eq(S.job.found, 1, "one reaction")
    for i = before + 1, #b.mock.http_log do
        assert(not b.mock.http_log[i]:find("api.github.com", 1, true), "no API call for one file")
    end
end }

T[#T + 1] = { "export: one file per reaction in the shared format, and Import reads them back the same", function()
    C.set_library(C.library() .. "\nfunction my_own() return true end\n")
    local done = assert(S.export_all())
    assert(done.count == #C.list(), "a file per reaction: " .. done.count)
    assert_eq(done.library, true, "the Library too")
    assert_eq(done.folder, "scripts_data/jambix_aio/share/Reaction", "where")
    local fs = b.mock.data_fs
    local files = {}
    for path, text in pairs(fs) do
        local p = path:gsub("\\", "/")
        if p:find("jambix_aio/share/Reaction/", 1, true) and p:match("%.json$") then files[#files + 1] = text end
    end
    assert_eq(#files, done.count, "the files are there")
    for _, text in ipairs(files) do
        local list = assert(S.decode(text))
        assert_eq(list[1].class, "HUNTER", "with the class")
        local name = list[1].r.name
        local mine
        for _, r in ipairs(C.list()) do if r.name == name then mine = r end end
        assert(mine, "the same name comes back: " .. name)
        assert_eq(#list[1].r.conds, #mine.conds, name .. ": the conditions")
        assert_eq(#list[1].r.actions, #mine.actions, name .. ": the actions")
        assert_eq(list[1].r.importance, mine.importance, name .. ": the importance")
    end
end }

T[#T + 1] = { "the window's Import view draws empty, reading, found, imported and failed", function()
    local st = b.P.reactwin.state
    b.P.reactwin.open(6)
    S.clear()
    b.mock.frame(3)
    assert_eq(st.shown, true, "the window is open")
    assert_eq(st.tab, 6, "on the Import view")
    assert_eq(st.err, nil, "empty")
    serve_repo()
    st.import_url = "https://github.com/alice/packs"
    S.fetch(st.import_url)
    b.mock.frame(1)
    assert_eq(st.err, nil, "reading")
    settle("window fetch")
    st.fmt_open = true
    b.mock.frame(3)
    assert_eq(st.err, nil, "found, with the file format open")
    S.import({})
    b.mock.frame(3)
    assert_eq(st.err, nil, "imported")
    S.fetch("github.com/alice/missing")
    settle("window missing")
    b.mock.frame(2)
    assert_eq(st.err, nil, "failed")
    st.tab = 2
    b.mock.frame(2)
    assert_eq(st.err, nil, "My reactions, with imported cards")
    assert_eq(b.errors(), "", "core.log_error")
end }

return T

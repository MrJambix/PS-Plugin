-- Jambix AIO / react / share -- reactions in from GitHub, and out to files
-- (1.77.2).
--
-- The user, 2026-10-05: "an import option on the UI to import someone's
-- reaction... they can import from a github link as long as it's got a
-- folder called Reaction".
--
-- THE FORMAT. One reaction per .json file, or a pack of them in one file:
--
--   { "format": "jambix-reaction", "version": 1, "class": "HUNTER",
--     "name": "Panic button", "importance": "survival", "priority": 100,
--     "wait": 0, "combat_only": false, "off_gcd": false, "match": "all",
--     "conds":   [ { "mode": "gui", "key": "me_hp", "op": "<", "value": 40 },
--                  { "mode": "lua", "code": "return fight.on_me >= 2" } ],
--     "actions": [ { "mode": "gui", "kind": "spell", "spell": "Feign Death", "target": "self" } ],
--     "env": { "world": true, "dungeon": true, "raid_pick": "Molten Core", ... } }
--
--   { "format": "jambix-reaction", "version": 1, "class": "MAGE",
--     "reactions": [ { ... }, { ... } ] }
--
-- These are the fields the editor makes (custom.lua's store, less its ids
-- and file links). "class" may be left out: such a reaction goes to the
-- class you are playing. A subfolder named after a class (Reaction/Mage/)
-- gives its files that class. library.lua, or library_<class>.lua, is the
-- author's Library, offered to add to yours. Export writes exactly this, so
-- what one player exports another imports.
--
-- FETCHING. The link names a public repository, a folder in it, or one
-- .json file. One call to GitHub's API lists the repository's files (its
-- tree); the shallowest folder called Reaction (or Reactions, any case) at
-- or under the link's path is the one read, with one level of subfolders;
-- its files come straight from raw.githubusercontent.com. Without signing
-- in GitHub allows 60 API calls an hour from one address, and a fetch costs
-- one (a link to one file costs none).
--
-- NOTHING RUNS ON IMPORT. A file is parsed as JSON, never loaded as code,
-- and every field is checked against what the editor can make: an unknown
-- condition or action is left out, and the preview says so. Lua rows are
-- kept (they run in the reactions' sandbox, like your own) and the preview
-- marks every reaction that has them. Imported reactions arrive switched
-- off unless you ask otherwise.

local FORMAT, VERSION = "jambix-reaction", 1
local API_TREE = "https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1"
local RAW = "https://raw.githubusercontent.com/%s/%s/%s/%s"
local SHARE_FOLDER = "jambix_aio/share/Reaction"
local MAX_FILES, MAX_BYTES = 40, 128 * 1024
local MAX_CONDS, MAX_ACTIONS, MAX_CODE = 24, 12, 8000

local CLASSES = {
    WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, PRIEST = true,
    SHAMAN = true, MAGE = true, WARLOCK = true, DRUID = true,
}

return function(C, P, D, h)
    local ctx, log = P.ctx, P.log
    local book = P.spellbook
    local net = ctx and ctx.net
    local json = ctx and ctx.json

    local S = { FORMAT = FORMAT, VERSION = VERSION, FOLDER = SHARE_FOLDER }
    S.job = nil

    -- --- small pieces ----------------------------------------------------------

    local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

    local function unescape(s)
        return (tostring(s or ""):gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end))
    end

    --- Percent-encodes a path for a URL, keeping its slashes.
    local function url_part(s)
        return (tostring(s):gsub("[^%w%-%._~/]", function(ch) return string.format("%%%02X", ch:byte()) end))
    end

    local function last_seg(p) return p:match("([^/]+)$") or p end
    local function parent_of(p) return p:match("^(.*)/[^/]+$") or "" end
    local function depth_of(p) return select(2, p:gsub("/", "")) end

    local function slug(s)
        local out = tostring(s or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
        return out ~= "" and out:sub(1, 40) or "reaction"
    end

    --- "Hunter", "hunter", "HUNTER" -> "HUNTER"; nil for anything else.
    local function class_of_word(w)
        if type(w) ~= "string" then return nil end
        local k = w:upper():gsub("[^%a]", "")
        return CLASSES[k] and k or nil
    end
    S.class_of_word = class_of_word

    local function class_label(cls)
        if not cls then return "any class" end
        return cls:sub(1, 1) .. cls:sub(2):lower()
    end
    S.class_label = class_label

    local function str(v, max)
        if type(v) ~= "string" then return nil end
        v = v:gsub("%z", "")
        if #v > max then v = v:sub(1, max) end
        return v
    end

    local function num(v, lo, hi)
        v = tonumber(v)
        if not v or v ~= v then return nil end
        return math.max(lo, math.min(hi, v))
    end

    local OPS_OK = {}
    for kind, list in pairs(D.OPS) do
        OPS_OK[kind] = {}
        for _, o in ipairs(list) do OPS_OK[kind][o.key] = true end
    end
    local KIND_OK, TARGET_OK, ITEM_OK = {}, {}, {}
    for _, k in ipairs(D.ACTION_KINDS) do KIND_OK[k.key] = true end
    for _, t in ipairs(D.TARGETS) do TARGET_OK[t.key] = true end
    for _, it in ipairs(D.ITEMS) do ITEM_OK[it.key] = true end

    -- --- the link ----------------------------------------------------------------

    --- Reads a GitHub link: a repository, a folder in it, or one file.
    ---@return table|nil link { owner, repo, ref, path, file }
    ---@return string|nil err
    function S.parse_link(text)
        local s = trim(text)
        if s == "" then return nil, "Paste a link to a GitHub repository first." end
        s = s:gsub("^%a+://", ""):gsub("^www%.", ""):gsub("[?#].*$", "")
        local host, rest = s:match("^([^/]+)/?(.*)$")
        host = (host or ""):lower()
        local parts = {}
        for seg in (rest or ""):gmatch("[^/]+") do parts[#parts + 1] = unescape(seg) end
        local link
        if host == "raw.githubusercontent.com" then
            if #parts < 4 then return nil, "That raw link is missing the file's path." end
            link = { owner = parts[1], repo = parts[2], ref = parts[3], path = "", file = table.concat(parts, "/", 4) }
        elseif host == "github.com" then
            if #parts < 2 then return nil, "The link needs the repository too: github.com/<who>/<repository>." end
            link = { owner = parts[1], repo = (parts[2]:gsub("%.git$", "")), ref = "HEAD", path = "" }
            if parts[3] == "tree" or parts[3] == "blob" then
                if not parts[4] then return nil, "The link stops after /" .. parts[3] .. "/." end
                link.ref = parts[4]
                local path = table.concat(parts, "/", 5)
                if parts[3] == "blob" then
                    if path == "" then return nil, "That link does not name a file." end
                    link.file = path
                else
                    link.path = path
                end
            end
        else
            return nil, "That is not a GitHub link: it should look like github.com/<who>/<repository>."
        end
        if not link.owner:match("^[%w%-%._]+$") or not link.repo:match("^[%w%-%._]+$") then
            return nil, "That repository name does not look right."
        end
        if link.file and not link.file:lower():match("%.json$") then
            return nil, "Link a .json reaction file, or the repository (or its Reaction folder)."
        end
        return link
    end

    local function is_reaction_dir(name)
        local n = tostring(name):lower()
        return n == "reaction" or n == "reactions"
    end

    --- The folder to read: the link's path when it is a Reaction folder,
    --- else the shallowest Reaction folder under it.
    function S.find_folder(tree, base)
        base = base or ""
        local lbase = base:lower()
        if base ~= "" and is_reaction_dir(last_seg(base)) then
            for _, e in ipairs(tree) do
                if e.type == "tree" and type(e.path) == "string" and e.path:lower() == lbase then return e.path end
            end
        end
        local best, best_depth
        for _, e in ipairs(tree) do
            if e.type == "tree" and type(e.path) == "string" and is_reaction_dir(last_seg(e.path)) then
                local under = base == "" or e.path:lower():sub(1, #lbase + 1) == lbase .. "/"
                if under then
                    local d = depth_of(e.path)
                    if not best or d < best_depth then best, best_depth = e.path, d end
                end
            end
        end
        return best
    end

    local function http_error(status, what)
        status = tonumber(status) or 0
        if status == 404 then
            return what == "tree" and "GitHub has no such repository: is it public, and is the link right?"
                or "A file was not found on GitHub."
        end
        if status == 403 or status == 429 then
            return "GitHub is not answering for now: without signing in it allows 60 lookups an hour. Try again later."
        end
        if status < 100 then return "Could not reach GitHub (no connection, or the loader blocked it)." end
        return "GitHub answered " .. status .. "."
    end

    -- --- checking a reaction ----------------------------------------------------------

    --- A reaction as the editor would have made it, from whatever a file
    --- held. Returns it, the notes for the preview, and whether it has Lua.
    function S.clean(raw)
        local notes, has_lua = {}, false
        local function note(s) if #notes < 12 then notes[#notes + 1] = s end end
        local r = {
            name = trim(str(raw.name, 200) or ""),
            importance = D.IMPORTANCE_BY_KEY[raw.importance or ""] and raw.importance or "defensive",
            match = raw.match == "any" and "any" or "all",
            combat_only = raw.combat_only ~= false,
            off_gcd = raw.off_gcd == true,
            wait = num(raw.wait, 0, 30) or 0,
            conds = {}, actions = {},
            -- 1.79.0
            per_fight = math.floor(num(raw.per_fight, 0, 99) or 0),
            notify_alert = raw.notify_alert == true, notify_sound = raw.notify_sound == true,
        }
        if r.name == "" then r.name = "Imported reaction" end
        if #r.name > 40 then r.name = trim(r.name:sub(1, 40)) end
        if raw.importance ~= nil and not D.IMPORTANCE_BY_KEY[raw.importance] then
            note(string.format("importance \"%s\" is not one this version knows: Defensive", tostring(raw.importance)))
        end
        r.priority = num(raw.priority, 1, 120) or D.IMPORTANCE_BY_KEY[r.importance].priority

        for _, c in ipairs(type(raw.conds) == "table" and raw.conds or {}) do
            if #r.conds >= MAX_CONDS then note("only the first " .. MAX_CONDS .. " conditions were kept") break end
            if type(c) == "table" then
                if c.mode == "lua" then
                    local code = str(c.code, MAX_CODE)
                    if code and code:find("%S") then
                        r.conds[#r.conds + 1] = { mode = "lua", code = code }
                        has_lua = true
                    else
                        note("an empty Lua condition was left out")
                    end
                else
                    local d = D.CONDITION_BY_KEY[c.key or ""]
                    if not d then
                        note(string.format("condition \"%s\" is not one this version knows: left out", tostring(c.key)))
                    else
                        local row = { mode = "gui", key = d.key }
                        local ops = OPS_OK[d.type] or OPS_OK.bool
                        row.op = ops[c.op or ""] and c.op or (d.type == "number" and (d.op or "<") or "is")
                        if d.type == "number" then
                            row.value = num(c.value, d.min or -1e9, d.max or 1e9) or d.default
                        elseif d.type == "text" or d.type == "choice" then
                            row.value = str(c.value, 80) or d.default
                            if d.choices == "library" and not tostring(row.value):match("^[%a_][%w_]*$") then row.value = "" end
                        elseif d.type == "text_number" then
                            row.value = str(c.value, 80) or d.default
                            row.num = num(c.num, d.min or 0, d.max or 1e9) or d.default_num
                        elseif d.type == "key" then
                            row.value = math.floor(num(c.value, 0, 255) or 0)
                        else
                            row.value = d.default
                        end
                        local hold = num(c.for_s, 0, 60)
                        if hold and hold > 0 then row.for_s = hold end
                        r.conds[#r.conds + 1] = row
                    end
                end
            end
        end

        for _, a in ipairs(type(raw.actions) == "table" and raw.actions or {}) do
            if #r.actions >= MAX_ACTIONS then note("only the first " .. MAX_ACTIONS .. " actions were kept") break end
            if type(a) == "table" then
                if a.mode == "lua" then
                    local code = str(a.code, MAX_CODE)
                    if code and code:find("%S") then
                        r.actions[#r.actions + 1] = { mode = "lua", code = code }
                        has_lua = true
                    else
                        note("an empty Lua action was left out")
                    end
                else
                    local kind = a.kind or "spell"
                    local row = KIND_OK[kind] and { mode = "gui", kind = kind } or nil
                    if not row then
                        note(string.format("action \"%s\" is not one this version knows: left out", tostring(kind)))
                    else
                        if kind == "spell" or kind == "pet_spell" then row.spell = trim(str(a.spell, 80) or "") end
                        if kind == "spell" or kind == "pet_spell" or kind == "pet_attack" then
                            row.target = TARGET_OK[a.target or ""] and a.target or "target"
                        end
                        if kind == "item" then
                            if ITEM_OK[a.item or ""] then row.item = a.item
                            else note(string.format("item \"%s\" is not one this version knows: left out", tostring(a.item))); row = nil end
                        elseif kind == "lua_fn" then
                            local fn = str(a.fn, 60)
                            if fn and fn:match("^[%a_][%w_]*$") then row.fn = fn
                            else note("a \"Run my Lua function\" action names no function: left out"); row = nil end
                        elseif kind == "named_item" then
                            row.name = trim(str(a.name, 80) or "")
                        elseif kind == "alert" then
                            row.text = trim(str(a.text, 80) or "")
                            row.color = D.ALERT_COLOR_BY_KEY[a.color or ""] and a.color or "red"
                            row.sound = a.sound ~= false
                        elseif kind == "target" then
                            local ok_who = false
                            for _, t in ipairs(D.SWITCH_TARGETS) do if t.key == a.who then ok_who = true end end
                            row.who = ok_who and a.who or "attacker"
                        end
                        if row then r.actions[#r.actions + 1] = row end
                    end
                end
            end
        end
        if #r.actions == 0 then note("it has no action it can send") end

        local env = C.fresh_env()
        if type(raw.env) == "table" then
            for _, e in ipairs(D.ENV) do
                if type(raw.env[e.key]) == "boolean" then env[e.key] = raw.env[e.key] end
            end
            for _, pk in pairs(C.PICK_OF) do
                local v = trim(str(raw.env[pk], 80) or "")
                if v ~= "" then env[pk] = v end
            end
        end
        r.env = env
        return r, notes, has_lua
    end

    --- A file's text, as reactions: one, or a pack. Each comes back checked:
    --- { name, class, r, notes, lua, description, author } or { name, err }.
    ---@return table[]|nil items
    ---@return string|nil err
    function S.decode(text, default_class)
        if type(text) ~= "string" or text == "" then return nil, "the file is empty" end
        if not json then return nil, "this JCore has no JSON reader" end
        text = text:gsub("^\239\187\191", "")
        local data, err = json.decode(text)
        if type(data) ~= "table" then return nil, "not JSON (" .. tostring(err or "?") .. ")" end
        if json.strip_nulls then data = json.strip_nulls(data) end
        if data.format ~= nil and data.format ~= FORMAT then
            return nil, "not a Jambix reaction (its format says " .. tostring(data.format) .. ")"
        end
        local raws = {}
        if type(data.reactions) == "table" then
            for _, x in ipairs(data.reactions) do if type(x) == "table" then raws[#raws + 1] = x end end
        else
            raws[1] = data
        end
        if #raws == 0 then return nil, "it has no reactions in it" end
        local file_class = class_of_word(data.class) or default_class
        local newer = (tonumber(data.version) or VERSION) > VERSION
        local out = {}
        for _, raw in ipairs(raws) do
            if raw.name == nil and type(raw.conds) ~= "table" and type(raw.actions) ~= "table" then
                out[#out + 1] = { name = "?", err = "not a reaction (no name, conditions or actions)" }
            else
                local r, notes, has_lua = S.clean(raw)
                local cls = class_of_word(raw.class) or file_class
                if raw.class ~= nil and not class_of_word(raw.class) then
                    notes[#notes + 1] = string.format("class \"%s\" is not one we know: it goes to yours", tostring(raw.class))
                end
                if newer then notes[#notes + 1] = "made by a newer version: what this one knows was read" end
                out[#out + 1] = {
                    name = r.name, class = cls, r = r, notes = notes, lua = has_lua,
                    description = str(raw.description, 300), author = str(raw.author or data.author, 60),
                }
            end
        end
        return out
    end

    -- --- fetching ---------------------------------------------------------------------

    local function headers()
        return { ["User-Agent"] = "JambixAIO/" .. tostring(ctx and ctx.version or "1"),
                 ["Accept"] = "application/vnd.github+json" }
    end

    local function raw_url(link, path)
        return string.format(RAW, url_part(link.owner), url_part(link.repo), url_part(link.ref), url_part(path))
    end

    local function fail(job, msg)
        job.busy = false
        job.err = msg
        job.status = nil
    end

    --- What a reaction meets in your game: spells you do not know, Library
    --- functions you do not have, a name you already use.
    local function annotate(job)
        local mine = C.class()
        local fns = {}
        for _, f in ipairs(C.choices("library") or {}) do fns[f] = "yours" end
        for _, lib in ipairs(job.libraries) do
            if lib.text then
                for f in lib.text:gmatch("function%s+([%a_][%w_]*)%s*%(") do fns[f] = fns[f] or "theirs" end
            end
        end
        local taken = {}
        for _, r in ipairs(C.list()) do taken[(r.name or ""):lower()] = true end
        for _, it in ipairs(job.items) do
            if it.r then
                local here = it.class == nil or it.class == mine
                local function fn_note(f)
                    if fns[f] == "theirs" then
                        it.notes[#it.notes + 1] = f .. "() is in the Library that comes with it"
                        it.needs_library = true
                    elseif not fns[f] then
                        it.notes[#it.notes + 1] = f .. "() is not in your Library"
                    end
                end
                for _, a in ipairs(it.r.actions) do
                    if a.mode == "gui" and a.kind == "spell" and here and a.spell ~= "" and book and book.known
                        and not book.known(a.spell) then
                        it.notes[#it.notes + 1] = a.spell .. " is not in your spellbook"
                    elseif a.mode == "gui" and a.kind == "lua_fn" then
                        fn_note(a.fn)
                    end
                end
                for _, c in ipairs(it.r.conds) do
                    if c.mode == "gui" and c.key == "lua_fn" and c.value and c.value ~= "" then fn_note(c.value) end
                end
                if here and taken[it.r.name:lower()] then
                    it.notes[#it.notes + 1] = "you already have one named " .. it.r.name .. ": it comes in with a number"
                end
            end
        end
    end

    local function finish_one(job)
        job.pending = job.pending - 1
        if job.pending > 0 then return end
        job.busy = false
        table.sort(job.items, function(a, b)
            local fa, fb = tostring(a.file):lower(), tostring(b.file):lower()
            if fa ~= fb then return fa < fb end
            return (a.index or 0) < (b.index or 0)
        end)
        annotate(job)
        local n = 0
        for _, it in ipairs(job.items) do
            if it.r then
                n = n + 1
                it.pick = true
            end
        end
        job.found = n
        if n == 0 then
            fail(job, "Nothing in " .. (job.folder ~= "" and job.folder or job.label) .. " could be read as a reaction.")
            return
        end
        job.status = string.format("Found %d reaction%s in %s/%s.", n, n == 1 and "" or "s", job.label,
            job.folder ~= "" and job.folder or "")
        log.fmt("info", "reactions: %d found to import from %s", n, job.label)
    end

    local function download(job, f)
        if f.size and f.size > MAX_BYTES then
            job.items[#job.items + 1] = { file = f.path, name = last_seg(f.path),
                err = string.format("too big to be a reaction (%d KB)", math.floor(f.size / 1024)) }
            finish_one(job)
            return
        end
        net.get(raw_url(job.link, f.path), { headers = headers(), ttl = 30, fresh = true }, function(res)
            if S.job ~= job then return end
            if not res.ok then
                job.items[#job.items + 1] = { file = f.path, name = last_seg(f.path), err = http_error(res.status, "file") }
            elseif #(res.body or "") > MAX_BYTES then
                job.items[#job.items + 1] = { file = f.path, name = last_seg(f.path), err = "too big to be a reaction" }
            elseif f.library then
                job.libraries[#job.libraries + 1] = { path = f.path, class = f.class, text = (res.body:gsub("\r\n", "\n")) }
            else
                local list, err = S.decode(res.body, f.class)
                if not list then
                    job.items[#job.items + 1] = { file = f.path, name = last_seg(f.path), err = err }
                else
                    for i, it in ipairs(list) do
                        it.file, it.index = f.path, i
                        job.items[#job.items + 1] = it
                    end
                end
            end
            finish_one(job)
        end)
    end

    --- The files to read from a tree: the folder's .json files and
    --- Libraries, and those of its subfolders (a class's name gives its
    --- files that class).
    local function pick_files(tree, folder)
        local files, libs = {}, {}
        local prefix = folder .. "/"
        for _, e in ipairs(tree) do
            if e.type == "blob" and type(e.path) == "string" and e.path:sub(1, #prefix) == prefix then
                local rel = e.path:sub(#prefix + 1)
                local d = depth_of(rel)
                if d <= 1 then
                    local name = last_seg(rel):lower()
                    local sub_class = d == 1 and class_of_word(rel:match("^([^/]+)/")) or nil
                    local size = tonumber(e.size)
                    if name:match("%.json$") then
                        files[#files + 1] = { path = e.path, size = size, class = sub_class }
                    elseif name == "library.lua" or name:match("^library_%a+%.lua$") then
                        local named = name:match("^library_(%a+)%.lua$")
                        libs[#libs + 1] = { path = e.path, size = size, library = true,
                            class = (named and class_of_word(named)) or sub_class }
                    end
                end
            end
        end
        table.sort(files, function(a, b) return a.path < b.path end)
        return files, libs
    end
    S.pick_files = pick_files

    --- Starts reading a link. The window watches S.job: busy, status, err,
    --- items (each with pick), libraries.
    ---@return boolean started
    function S.fetch(text)
        if S.job and S.job.busy then return false end
        local link, err = S.parse_link(text)
        local job = { link = link, items = {}, libraries = {}, notes = {}, busy = true, pending = 0,
            status = "Asking GitHub...", folder = "" }
        S.job = job
        if not link then fail(job, err) return false end
        if not (net and net.get and json) then fail(job, "This JCore cannot reach the web.") return false end
        job.label = "github.com/" .. link.owner .. "/" .. link.repo
        if link.file then
            job.folder = parent_of(link.file)
            job.status = "Reading " .. last_seg(link.file) .. "..."
            job.pending = 1
            local sub = class_of_word(last_seg(job.folder))
            download(job, { path = link.file, class = sub })
            return true
        end
        local url = string.format(API_TREE, url_part(link.owner), url_part(link.repo), url_part(link.ref))
        net.get(url, { headers = headers(), ttl = 30, fresh = true }, function(res)
            if S.job ~= job then return end
            if not res.ok then return fail(job, http_error(res.status, "tree")) end
            local data = json.decode(res.body or "")
            if type(data) ~= "table" or type(data.tree) ~= "table" then
                return fail(job, "GitHub's answer was not a list of files.")
            end
            local folder = S.find_folder(data.tree, link.path)
            if not folder then
                return fail(job, string.format("%s has no folder called Reaction%s.", job.label,
                    link.path ~= "" and (" in " .. link.path) or ""))
            end
            job.folder = folder
            local files, libs = pick_files(data.tree, folder)
            if #files == 0 then return fail(job, "The folder " .. folder .. " has no .json reactions in it.") end
            if #files > MAX_FILES then
                job.notes[#job.notes + 1] = string.format("Only the first %d of its %d files were read.", MAX_FILES, #files)
            end
            local n = math.min(#files, MAX_FILES)
            job.status = string.format("Reading %d file%s from %s...", n, n == 1 and "" or "s", folder)
            job.pending = n + #libs
            for i = 1, n do download(job, files[i]) end
            for _, l in ipairs(libs) do download(job, l) end
        end)
        return true
    end

    --- Forgets the last fetch.
    function S.clear() S.job = nil end

    -- --- importing ----------------------------------------------------------------------

    local function unique_name(list, name)
        local taken = {}
        for _, r in ipairs(list) do taken[(r.name or ""):lower()] = true end
        if not taken[name:lower()] then return name end
        for n = 2, 99 do
            local cand = trim(name:sub(1, 34)) .. " (" .. n .. ")"
            if not taken[cand:lower()] then return cand end
        end
        return name
    end

    local function add_library(cls, lib, job)
        local header = string.format("-- From %s (%s)", job.label, lib.path)
        local text = "\n\n" .. header .. "\n" .. lib.text
        if cls == C.class() then
            local cur = C.library()
            if cur:find(header, 1, true) then lib.added = "already" return end
            C.set_library(cur .. text)
        else
            local b = h.bucket(cls)
            if not b then return end
            if b.library:find(header, 1, true) then lib.added = "already" return end
            b.library = b.library .. text
            if h.reset_programs then h.reset_programs() end
            h.touch()
        end
        lib.added = true
    end

    --- Saves the picked reactions: yours into your list, another class's
    --- into that class's (they are there when you log in with one).
    ---@param opts? { switch_on?: boolean, add_library?: boolean }
    ---@return table|nil done { mine, other = { CLASS = n }, libraries }
    ---@return string|nil err
    function S.import(opts)
        opts = opts or {}
        local job = S.job
        if not job or job.busy then return nil, "Nothing fetched to import." end
        local mine = C.class()
        if not mine then return nil, "Your class is not known yet: log in with a character." end
        local done = { mine = 0, other = {}, libraries = 0, total = 0 }
        for _, it in ipairs(job.items) do
            if it.pick and it.r and not it.imported then
                local cls = it.class or mine
                local r = h.copy(it.r)
                r.on = opts.switch_on == true
                r.source = { repo = job.label, file = it.file }
                if cls == mine then
                    r.name = unique_name(C.list(), r.name)
                    r.id = nil
                    if C.save(r) then done.mine = done.mine + 1 end
                else
                    local b = h.bucket(cls)
                    if b then
                        r.name = unique_name(b.custom, r.name)
                        r.id = b.next_id
                        b.next_id = b.next_id + 1
                        h.normalise(r, r.id)
                        b.custom[#b.custom + 1] = r
                        h.touch()
                        done.other[cls] = (done.other[cls] or 0) + 1
                    end
                end
                it.imported, it.pick, it.imported_on = true, false, r.on
                done.total = done.total + 1
            end
        end
        if opts.add_library then
            for _, lib in ipairs(job.libraries) do
                if lib.text and not lib.added then
                    add_library(lib.class or mine, lib, job)
                    if lib.added == true then done.libraries = done.libraries + 1 end
                end
            end
        end
        log.fmt("info", "reactions: imported %d from %s (%d yours)", done.total, job.label, done.mine)
        return done
    end

    -- --- exporting ----------------------------------------------------------------------

    --- A reaction in the shared format, as JSON text.
    function S.encode(r, cls)
        local out = {
            format = FORMAT, version = VERSION, class = cls, name = r.name, importance = r.importance,
            priority = r.priority, wait = r.wait or 0, combat_only = r.combat_only ~= false, off_gcd = r.off_gcd == true,
            match = r.match == "any" and "any" or "all", conds = {}, actions = {}, env = h.copy(r.env or C.fresh_env()),
            per_fight = (tonumber(r.per_fight) or 0) > 0 and r.per_fight or nil,
            notify_alert = r.notify_alert == true or nil, notify_sound = r.notify_sound == true or nil,
        }
        for _, c in ipairs(r.conds or {}) do
            if c.mode == "lua" then
                out.conds[#out.conds + 1] = { mode = "lua", code = c.code or "" }
            else
                out.conds[#out.conds + 1] = { mode = "gui", key = c.key, op = c.op, value = c.value, num = c.num,
                    for_s = (tonumber(c.for_s) or 0) > 0 and c.for_s or nil }
            end
        end
        for _, a in ipairs(r.actions or {}) do
            if a.mode == "lua" then
                out.actions[#out.actions + 1] = { mode = "lua", code = a.code or "" }
            else
                local row = { mode = "gui", kind = a.kind or "spell", spell = a.spell,
                    target = a.target, item = a.item, fn = a.fn, name = a.name, text = a.text, color = a.color, who = a.who }
                if a.kind == "alert" then row.sound = a.sound ~= false end
                out.actions[#out.actions + 1] = row
            end
        end
        return json.encode(out, { pretty = true })
    end

    local function write(path, text)
        if type(core.write_data_file) ~= "function" then return false end
        local acc = nil
        for seg in parent_of(path):gmatch("[^/]+") do
            acc = acc and (acc .. "/" .. seg) or seg
            pcall(core.create_data_folder, acc)
        end
        pcall(core.create_data_file, path)
        local ok = pcall(core.write_data_file, path, text)
        return ok
    end

    --- Writes your class's reactions (and your Library, when it is your own)
    --- to scripts_data/jambix_aio/share/Reaction, one file each.
    ---@return table|nil done { folder, count, library }
    ---@return string|nil err
    function S.export_all()
        local cls = C.class()
        if not cls then return nil, "Your class is not known yet: log in with a character." end
        local list = C.list()
        if #list == 0 then return nil, "You have no reactions of your own to export yet." end
        if not json then return nil, "This JCore has no JSON writer." end
        local used, count = {}, 0
        for _, r in ipairs(list) do
            local base = cls:lower() .. "_" .. slug(r.name)
            local name, k = base, 2
            while used[name] do name = base .. "_" .. k; k = k + 1 end
            used[name] = true
            local text = S.encode(r, cls)
            if text and write(SHARE_FOLDER .. "/" .. name .. ".json", text) then count = count + 1 end
        end
        if count == 0 then return nil, "This loader cannot write files." end
        local lib = C.library()
        local wrote_lib = false
        if lib:find("%S") and lib ~= D.LIBRARY_EXAMPLE then
            wrote_lib = write(SHARE_FOLDER .. "/library_" .. cls:lower() .. ".lua", lib)
        end
        log.fmt("info", "reactions: exported %d to scripts_data/%s", count, SHARE_FOLDER)
        return { folder = "scripts_data/" .. SHARE_FOLDER, count = count, library = wrote_lib }
    end

    return S
end

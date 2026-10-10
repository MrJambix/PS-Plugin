-- JCore / assets -- every icon and texture a plugin can draw, from anywhere.
--
-- Depends on: util, log, cache, scheduler, events, net, storage, image, draw.
--
-- ONE REFERENCE STRING, MANY SOURCES
-- A plugin names art with a short reference and never learns where the bytes
-- came from or what format they were in:
--
--   "data:icons/sword.png"            a file under scripts_data
--   "addon:Questie/Icons/available"   a file inside an installed addon
--   "wow:_retail_/Interface/AddOns/X/y.tga"   any file under the WoW folder
--   "icon:spell_holy_flashheal"       a game icon by name, from Wowhead's CDN
--   "Interface\\Icons\\Spell_Holy_FlashHeal"  the same, as addons spell it
--   "spell:2061" / "item:6948"        resolved to the icon name, then as above
--   "https://..."                     any image on the web, disk-cached
--   "tex:<name>"                      a texture a plugin loaded itself
--   "atlas:<name>/<cell>"             one cell of a registered sprite sheet
--
-- WHY A QUEUE
-- Loading an image is a file read (native), possibly a BLP decode (Lua, up to
-- millions of pixels), then a GPU upload. None of that belongs in a render
-- job. So a draw of an asset that is not ready yet queues it, draws nothing,
-- and answers false; the pump loads one asset at a time on a per-frame CPU
-- budget, and the next frame that asks for it gets the texture. Failures
-- back off rather than retrying every frame, and "not found" is final.
--
-- IMPORTING FROM ADDONS
-- The loader has no directory listing for the game folder, so "every icon
-- an addon ships" is found the way the game itself finds them: read the
-- addon's .toc, walk its Lua and XML files, and collect every
-- Interface\AddOns\... path they mention, keeping the ones that exist on
-- disk. Game icons (Interface\Icons\...) live inside the client's data
-- archives and are served from Wowhead instead. Everything found goes into a
-- persistent catalog that the icon browser shows and any plugin can query.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local scheduler = rt.scheduler
    local events = rt.events
    local net = rt.net
    local storage = rt.storage
    local image = rt.image
    local draw = rt.draw
    local log = rt.log.for_tag("JCore/assets")

    local try = cache.try

    local M = {}

    -- The clock, read once per tick. Every draw of every icon asks request()
    -- for its entry, and request() stamped it with core.time(), a native
    -- call: four to eleven a frame for each textured mark, a few hundred in a
    -- crowd. Retry timing does not need finer than a frame.
    local clock_tick, clock_now = -1, 0
    local function now()
        local t = cache.tick_id()
        if t ~= clock_tick then
            clock_tick = t
            clock_now = core.time()
        end
        return clock_now
    end

    -- --- tuning -------------------------------------------------------------

    -- CPU the pump may spend per frame on decoding and scanning, milliseconds.
    local BUDGET_MS = 2.5
    -- Largest side an imported texture is decoded at. A BLP with mips is read
    -- at the level that fits; one without is decoded in full regardless.
    local DEFAULT_MAX_DIM = 512
    -- Retry backoff for transient failures.
    local RETRY_BASE = 20.0
    local RETRY_MAX = 600.0
    -- Addon scan limits, so a huge addon cannot own the pump for minutes.
    local SCAN_MAX_FILES = 600
    local SCAN_MAX_TOTAL_BYTES = 12 * 1024 * 1024
    local SCAN_MAX_FILE_BYTES = 2 * 1024 * 1024
    local SCAN_MAX_PROBES = 1500
    local DATA_SCAN_MAX_ENTRIES = 3000

    local NS_TO_MS = 1 / 1000000

    local ICON_CDN = "https://wow.zamimg.com/images/wow/icons/%s/%s.jpg"
    local TOOLTIP_URL = "https://nether.wowhead.com/tooltip/%s/%d?dataEnv=%d&locale=0"

    local IMAGE_EXT = { png = true, jpg = true, jpeg = true, tga = true, blp = true, bmp = true, gif = true }

    -- Client folders the install root can hold. Probed in this order; the
    -- first one with a config file is the one the client is running from.
    local FLAVORS = {
        "_classic_era_", "_classic_", "_retail_", "_anniversary_", "_classic_era_ptr_",
        "_classic_ptr_", "_ptr_", "_xptr_", "_beta_", "_classic_beta_",
    }

    -- Addon folder names worth probing when asked to import "everything".
    -- The loader's own addon namespaces map to folders first; the rest are
    -- the addons most likely to be installed and to ship their own art.
    local KNOWN_ADDONS = {
        "Questie", "RXPGuides", "ZygorGuidesViewer", "Details", "BigWigs", "LittleWigs",
        "DBM-Core", "WeakAuras", "ElvUI", "Bartender4", "Leatrix_Plus", "Leatrix_Maps",
        "TradeSkillMaster", "Auctionator", "Auctioneer", "AtlasLoot", "AtlasLootClassic",
        "Pawn", "Plater", "MythicDungeonTools", "MaxDps", "Conroc", "SwingTimer",
        "ArenaCore", "TimelineReminders", "Gladius", "GladiusEx", "Gladdy", "OmniCC", "OmniBar",
        "TellMeWhen", "NovaWorldBuffs", "NovaInstanceTracker", "ClassicCastbars",
        "ThreatClassic2", "TitanPanel", "Bagnon", "AdiBags", "ArkInventory", "Baganator",
        "Recount", "Skada", "Dominos", "Masque", "Postal", "Prat-3.0", "Chatter",
        "SexyMap", "Carbonite", "GatherMate2", "Gatherer", "HandyNotes", "TomTom",
        "Mapster", "Cartographer", "ItemRack", "Outfitter", "AttuneHelper", "Attune",
        "GuidelimeClassic", "Guidelime", "WhatsTraining", "Clique", "Grid2", "Grid", "VuhDo",
        "HealBot", "Cell", "ShadowedUnitFrames", "PitBull4", "LunaUnitFrames", "XPerl",
        "Decursive", "Quartz", "NeedToKnow", "Raven", "BuffWatch", "ClassicAuraDurations",
        "Immersion", "Storyline", "TotalRP3", "MogIt", "AllTheThings", "Rarity",
        "TSM_AppHelper", "Hekili", "ConRO", "GSE", "AutoLoot", "Leatrix", "RealMobHealth",
        "Vendor", "Scrap", "Peggle", "EnhancedTooltip", "TipTac", "NPCScan", "SilverDragon",
        "Auctionator", "WIM", "BadBoy", "SpamFilter", "WorldQuestTracker", "AngryKeystones",
        "OmniAuras", "Nameplates", "KuiNameplates", "NeatPlates", "TidyPlates", "ThreatPlates",
    }

    local NAMESPACE_FOLDERS = {
        bigwigs = "BigWigs", exboss = "ExBoss", details = "Details", questie = "Questie",
        zygor = "ZygorGuidesViewer", rested_xp = "RXPGuides", conroc = "ConRO", maxdps = "MaxDps",
        swing_timer = "SwingTimer", arena_core = "ArenaCore", mdt = "MythicDungeonTools",
        tsm = "TradeSkillMaster", timeline_reminders = "TimelineReminders",
    }

    -- --- state --------------------------------------------------------------

    local entries = {}        -- canonical ref -> entry
    local queue = {}          -- entries and scan jobs waiting for the pump
    local active = nil        -- the job currently being stepped
    local atlases = {}        -- name -> { ref, cells, cols, rows }
    local registered = {}     -- refs a plugin registered with metadata, in order
    local flavor = nil        -- detected client folder, "" for the root

    local stats = {
        loaded = 0, failed = 0, decoded_pixels = 0, converted = 0,
        downloads = 0, cache_hits = 0, scans = 0, pump_ms = 0, extracted = 0,
    }

    -- Persistent: client-folder override, resolved icon names, catalogs.
    local store = storage.store("jcore.assets")
    local data = store.data
    data.slugs = data.slugs or { spell = {}, item = {} }
    data.slugs.spell = data.slugs.spell or {}
    data.slugs.item = data.slugs.item or {}
    data.catalog = data.catalog or {}
    data.data_catalog = data.data_catalog or {}
    data.installed = data.installed or {}

    local vec2_lib
    do
        local ok, mod = pcall(require, "common/geometry/vector_2")
        if ok then vec2_lib = mod end
    end

    local function to_vec2(p)
        if not p then return nil end
        if not vec2_lib or getmetatable(p) ~= nil then return p end
        local ok, v = pcall(vec2_lib.new, p.x or 0, p.y or 0)
        return ok and v or p
    end

    -- --- paths --------------------------------------------------------------

    local function slashes(p)
        p = tostring(p or ""):gsub("\\", "/")
        p = p:gsub("/+", "/")
        return p
    end

    local function ext_of(p)
        local e = tostring(p or ""):match("%.([%w]+)$")
        return e and e:lower() or nil
    end

    local function basename(p)
        return slashes(p):match("([^/]+)$") or p
    end

    local function strip_ext(p)
        return (p:gsub("%.[%w]+$", ""))
    end

    --- djb2, for cache file names. Not cryptographic, only unique enough.
    local function hash_string(s)
        local h = 5381
        for i = 1, #s do
            h = (h * 33 + s:byte(i)) % 4294967296
        end
        -- Two 16-bit halves: a value past 2^31 has no integer
        -- representation for %x on a 32-bit-integer Lua.
        return string.format("%04x%04x", math.floor(h / 65536), math.floor(h % 65536))
    end

    local function file_size_wow(path)
        return try(core.get_file_size, path) or 0
    end

    -- --- client folder -------------------------------------------------------
    --
    -- Every client but Forever is found by the fixed probe below, exactly as it
    -- always was: the first FLAVORS folder with a config file.
    --
    -- Forever (Classic+, 2026) is ADDED in front of that. Its folder is not in
    -- the list, and when it shares an install root with Era, Era's folder
    -- would win the probe because both have a config file. So on Forever the
    -- candidates come from the install itself and the one whose product is
    -- not an older client's is taken:
    --
    --   .build.info   one row per installed product; nearly every product
    --                 lives in "_<code minus wow_>_" (wow_classic_era in
    --                 _classic_era_), and FOLDER_BY_PRODUCT lists the rest
    --   .product.db   Battle.net's install record, which names the folder
    --   <folder>/.flavor.info   the product a folder really belongs to

    local FOLDER_BY_PRODUCT = { wow = "_retail_", wowt = "_ptr_", wowxptr = "_xptr_" }

    -- Every product code that is NOT Forever. Forever's own code is not known
    -- in advance, so it is recognised as the one that is not these.
    local OLDER_PRODUCTS = {
        wow = true, wowt = true, wowxptr = true, wow_beta = true,
        wow_classic = true, wow_classic_ptr = true, wow_classic_beta = true,
        wow_classic_era = true, wow_classic_era_ptr = true, wow_classic_era_beta = true,
        wow_anniversary = true, wow_anniversary_ptr = true,
    }

    local product = nil       -- the folder's product code; nil = not read yet, false = unknown

    local function folder_for_product(code)
        if FOLDER_BY_PRODUCT[code] then return FOLDER_BY_PRODUCT[code] end
        local rest = code:match("^wow_([%w_]+)$")
        return rest and ("_" .. rest .. "_") or nil
    end

    --- The product code a client folder declares, or nil.
    local function folder_product(folder)
        local text = try(core.read_file, folder .. "/.flavor.info")
        if type(text) ~= "string" then return nil end
        -- "Product Flavor!STRING:0" then the value on the next line.
        local value = text:match("\n%s*([%w_]+)%s*$") or text:match("\n%s*([%w_]+)")
        return value
    end

    local function is_forever_product(code)
        if type(code) ~= "string" then return false end
        return code:find("forever", 1, true) ~= nil or not OLDER_PRODUCTS[code]
    end

    -- Which client folders belong to which client, by core.get_game_version.
    -- A private server answers like its Blizzard counterpart and may live in
    -- a folder of its own; then none of these matches and the fixed order in
    -- flavor() decides, as it always did.
    local FOLDERS_BY_VERSION = {
        Vanilla  = { "_classic_era_", "_classic_era_ptr_" },
        Tbc      = { "_anniversary_", "_classic_" },
        Titan    = { "_classic_", "_classic_ptr_" },
        Mop      = { "_classic_", "_classic_ptr_" },
        Midnight = { "_retail_", "_ptr_", "_xptr_", "_beta_" },
    }

    local function version_folders()
        local world = rt.world
        if type(world) ~= "table" or type(world.game_version) ~= "function" then return {} end
        local ok, version = pcall(world.game_version)
        return (ok and FOLDERS_BY_VERSION[version]) or {}
    end

    local function running_forever()
        local world = rt.world
        if type(world) ~= "table" or type(world.client) ~= "function" then return false end
        local ok, client = pcall(world.client)
        return ok and type(client) == "table" and client.forever == true
    end

    --- Every folder name the install could be using, known ones first.
    local function folder_candidates()
        local out, seen = {}, {}
        local function add(name)
            if type(name) == "string" and name ~= "" and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
        for i = 1, #FLAVORS do add(FLAVORS[i]) end

        local info = try(core.read_file, ".build.info")
        if type(info) == "string" then
            local col = nil
            for line in info:gmatch("[^\r\n]+") do
                local cells = {}
                for cell in (line .. "|"):gmatch("([^|]*)|") do cells[#cells + 1] = cell end
                if not col then
                    for i = 1, #cells do
                        if cells[i]:match("^Product!") then col = i end
                    end
                    if not col then break end
                elseif cells[col] then
                    add(folder_for_product(cells[col]))
                end
            end
        end

        -- The folder is a length-prefixed string in a protobuf; anything that
        -- looks like one is only a candidate, and has to pass the probe.
        local db = try(core.read_file, ".product.db")
        if type(db) == "string" then
            for name in db:gmatch("_[%l%d_]+_") do add(name) end
        end
        return out
    end

    --- Forever's client folder from the install, or nil to let the classic
    --- probe answer.
    local function forever_folder()
        local found = {}
        local candidates = folder_candidates()
        for i = 1, #candidates do
            local name = candidates[i]
            if file_size_wow(name .. "/WTF/Config.wtf") > 0 then
                local code = folder_product(name)
                if not code and name:match("^_[%w_]+_$") then
                    -- No .flavor.info: invert the folder rule.
                    local inner = name:sub(2, -2)
                    code = (inner == "retail" and "wow") or (inner == "ptr" and "wowt")
                        or (inner == "xptr" and "wowxptr") or ("wow_" .. inner)
                end
                if is_forever_product(code) then return name, code end
                found[#found + 1] = name
            end
        end
        -- One client installed: it is the one running, whatever it calls itself.
        if #found == 1 then return found[1], folder_product(found[1]) end
        return nil
    end

    --- The client folder under the install root, detected once. An override
    --- from the store wins, for a layout the probe cannot work out.
    ---@return string
    function M.flavor()
        if flavor ~= nil then return flavor end
        local override = data.flavor
        if type(override) == "string" and override ~= "" then
            flavor = override
            return flavor
        end

        if running_forever() then
            local folder, code = forever_folder()
            if folder then
                flavor = folder
                product = code or false
                log.fmt("info", "client folder detected: %s (Forever, %s)", flavor, tostring(code or "?"))
                return flavor
            end
        end

        -- The running client's own folder first. An install with several
        -- clients -- Era beside Retail, say -- has a Config.wtf in each, and
        -- the fixed order below would hand Retail the Era folder: its AddOns,
        -- its archives, its art.
        local own = version_folders()
        for i = 1, #own do
            if file_size_wow(own[i] .. "/WTF/Config.wtf") > 0 then
                flavor = own[i]
                log.fmt("info", "client folder detected: %s (the running client's)", flavor)
                return flavor
            end
        end

        for i = 1, #FLAVORS do
            if file_size_wow(FLAVORS[i] .. "/WTF/Config.wtf") > 0 then
                flavor = FLAVORS[i]
                log.fmt("info", "client folder detected: %s", flavor)
                return flavor
            end
        end
        if file_size_wow("WTF/Config.wtf") > 0 then
            flavor = ""
            return flavor
        end
        log.once("warn", "no_flavor",
            "could not detect the client folder; set it on the JCore > UI page (e.g. _classic_era_)")
        flavor = "_classic_era_"
        return flavor
    end

    --- The Battle.net product code of the client folder ("wow_classic_era",
    --- ...), from its .flavor.info, or nil when the folder does not say. Read
    --- on first ask; the classic clients never read it during detection.
    ---@return string|nil
    function M.product()
        local f = M.flavor()
        if product == nil then
            product = (f ~= "" and folder_product(f)) or false
        end
        return product or nil
    end

    ---@param name string e.g. "_retail_"; "" for the install root
    function M.set_flavor(name)
        data.flavor = tostring(name or "")
        flavor = nil
        product = nil
        store:touch()
    end

    --- A path under the WoW install root for a path relative to the client
    --- folder.
    ---@param rel string e.g. "Interface/AddOns/Questie/Questie.toc"
    ---@return string
    function M.wow_path(rel)
        local f = M.flavor()
        rel = slashes(rel)
        if f == "" then return rel end
        return f .. "/" .. rel
    end

    -- --- references ---------------------------------------------------------

    ---@class jcore_asset_ref
    ---@field kind "data"|"wow"|"addon"|"http"|"icon"|"spell"|"item"|"tex"|"atlas"
    ---@field key string     canonical reference
    ---@field path string|nil
    ---@field url string|nil
    ---@field slug string|nil
    ---@field id integer|nil
    ---@field ext string|nil

    --- Parses a reference string into its parts.
    ---@param ref string
    ---@return jcore_asset_ref|nil
    function M.parse(ref)
        if type(ref) ~= "string" or ref == "" then return nil end
        local lower = ref:lower()

        if lower:match("^https?://") then
            return { kind = "http", key = ref, url = ref, ext = ext_of(ref:match("^[^%?#]+")) }
        end

        local scheme, rest = ref:match("^(%a+):(.+)$")
        if scheme then
            scheme = scheme:lower()
            if scheme == "data" then
                rest = slashes(rest)
                return { kind = "data", key = "data:" .. rest, path = rest, ext = ext_of(rest) }
            elseif scheme == "wow" then
                rest = slashes(rest)
                return { kind = "wow", key = "wow:" .. rest, path = rest, ext = ext_of(rest) }
            elseif scheme == "game" then
                -- A file inside the client's data archives, by its game
                -- path: "game:Interface/Icons/ClassIcon_Warrior.blp".
                rest = slashes(rest):gsub("^/+", "")
                return { kind = "game", key = "game:" .. rest:lower(), path = rest, ext = ext_of(rest) }
            elseif scheme == "addon" then
                rest = slashes(rest)
                return { kind = "addon", key = "addon:" .. rest, path = rest, ext = ext_of(rest) }
            elseif scheme == "icon" then
                local slug = strip_ext(basename(rest)):lower()
                return { kind = "icon", key = "icon:" .. slug, slug = slug }
            elseif scheme == "spell" or scheme == "item" then
                local id = tonumber(rest)
                if not id or id <= 0 then return nil end
                return { kind = scheme, key = scheme .. ":" .. math.floor(id), id = math.floor(id) }
            elseif scheme == "tex" then
                return { kind = "tex", key = "tex:" .. rest, name = rest }
            elseif scheme == "atlas" then
                local name, cell = rest:match("^([^/]+)/(.+)$")
                if not name then return nil end
                return { kind = "atlas", key = "atlas:" .. rest, name = name, cell = cell }
            end
        end

        local norm = slashes(ref)
        local icons_rest = norm:match("^[Ii]nterface/[Ii]cons/(.+)$")
        if icons_rest then
            local slug = strip_ext(basename(icons_rest)):lower()
            return { kind = "icon", key = "icon:" .. slug, slug = slug }
        end
        local addons_rest = norm:match("^[Ii]nterface/[Aa]dd[Oo]ns/(.+)$")
        if addons_rest then
            return { kind = "addon", key = "addon:" .. addons_rest, path = addons_rest, ext = ext_of(addons_rest) }
        end
        if norm:find("/", 1, true) or IMAGE_EXT[ext_of(norm) or ""] then
            return { kind = "data", key = "data:" .. norm, path = norm, ext = ext_of(norm) }
        end
        -- A bare token is an icon name.
        return { kind = "icon", key = "icon:" .. lower, slug = lower }
    end

    ---@param slug string
    ---@param size? "large"|"medium"|"small"
    function M.icon_url(slug, size)
        return string.format(ICON_CDN, size or "large", slug)
    end

    -- --- entries ------------------------------------------------------------

    ---@class jcore_asset
    ---@field ref jcore_asset_ref
    ---@field key string
    ---@field state "idle"|"queued"|"loading"|"resolving"|"downloading"|"ready"|"failed"
    ---@field tex integer|nil
    ---@field gif integer|nil
    ---@field w integer|nil
    ---@field h integer|nil
    ---@field uv number[]|nil   {u0, v0, u1, v1} for atlas cells
    ---@field err string|nil
    ---@field dead boolean      failed for good; no retry
    ---@field tries integer
    ---@field next_try number
    ---@field last_used number
    ---@field label string

    local function new_entry(parsed)
        local e = {
            ref = parsed, key = parsed.key, kind = parsed.kind,
            state = "idle", tries = 0, next_try = 0, dead = false,
            last_used = 0, label = parsed.slug or parsed.path or parsed.url or parsed.name or parsed.key,
        }
        entries[parsed.key] = e
        return e
    end

    local function enqueue(e)
        local s = e.state
        -- "resolving" and "downloading" are waiting on a callback that will
        -- queue the entry itself; queueing it again would spin a coroutine a
        -- frame for nothing.
        if s == "queued" or s == "loading" or s == "ready" or s == "resolving" or s == "downloading" then
            return
        end
        if e.dead then return end
        if e.state == "failed" and now() < e.next_try then return end
        e.state = "queued"
        queue[#queue + 1] = e
    end

    local function fail(e, err, permanent, quiet)
        e.state = "failed"
        e.err = err
        e.tries = e.tries + 1
        e.bytes = nil
        if permanent then
            e.dead = true
        else
            e.next_try = now() + math.min(RETRY_MAX, RETRY_BASE * (2 ^ (e.tries - 1)))
        end
        stats.failed = stats.failed + 1
        log.fmt((permanent and not quiet) and "warn" or "debug", "asset %s failed: %s", e.key, tostring(err))
    end

    local function ready(e, tex, w, h, gif)
        e.state = "ready"
        e.tex = tex
        e.gif = gif
        e.w = w or e.w
        e.h = h or e.h
        e.err = nil
        e.bytes = nil
        e.loaded_at = now()
        stats.loaded = stats.loaded + 1
        events.emit("jcore.asset.ready", e.key, e)
    end

    --- The entry for a reference, created on first sight. Does not queue.
    ---@param ref string
    ---@return jcore_asset|nil
    function M.get(ref)
        local e = entries[ref]
        if e then return e end
        local parsed = M.parse(ref)
        if not parsed then return nil end
        e = entries[parsed.key]
        if e then
            entries[ref] = e
            return e
        end
        e = new_entry(parsed)
        entries[ref] = e
        if parsed.kind == "game" and rt.casc then
            -- Registered now, so the first root scan answers every game
            -- path asked for so far in one pass.
            rt.casc.want(parsed.path)
        end
        if parsed.kind == "atlas" then
            e.atlas = atlases[parsed.name]
            if not e.atlas then
                fail(e, "atlas '" .. parsed.name .. "' is not registered", true)
            end
        end
        return e
    end

    --- Requests an asset. The first call queues the load; later calls answer
    --- whether it is ready. Cheap enough to call every frame.
    ---@param ref string
    ---@return boolean ready
    ---@return jcore_asset|nil entry
    function M.request(ref)
        local e = M.get(ref)
        if not e then return false, nil end
        e.last_used = now()

        if e.kind == "atlas" then
            if not e.atlas then return false, e end
            local base = M.get(e.atlas.ref)
            local ok = M.request(e.atlas.ref)
            if ok and base then
                e.tex, e.gif = base.tex, base.gif
                if not e.uv then e.uv = M._atlas_uv(e.atlas, e.ref.cell, base) end
                e.state = e.uv and "ready" or "failed"
                if not e.uv then e.err = "unknown atlas cell " .. tostring(e.ref.cell) end
                return e.state == "ready", e
            end
            return false, e
        end

        if e.state == "ready" then return true, e end
        enqueue(e)
        return false, e
    end

    ---@param refs string[]
    function M.preload(refs)
        for i = 1, #refs do M.request(refs[i]) end
    end

    --- Drops the record for a reference. The GPU texture, if any, stays
    --- loaded; there is no native call to release one.
    function M.forget(ref)
        local e = entries[ref]
        if not e then return end
        for k, v in pairs(entries) do
            if v == e then entries[k] = nil end
        end
    end

    -- --- registered textures and atlases ------------------------------------

    --- Registers a texture a plugin loaded itself under "tex:<name>".
    ---@param name string
    ---@param tex_id integer
    ---@param w? integer
    ---@param h? integer
    function M.register_texture(name, tex_id, w, h)
        local e = M.get("tex:" .. name)
        if not e then return nil end
        ready(e, tex_id, w, h, nil)
        return e
    end

    --- Registers a sprite sheet. Cells are named by either a grid (cols and
    --- rows, cells addressed "atlas:<name>/<index>" from 1, row-major, or by
    --- the optional names list) or a map of cell name to a rect, given as
    --- {u0, v0, u1, v1} fractions or {x =, y =, w =, h =} pixels.
    ---@param name string
    ---@param ref string The sheet image, any reference kind.
    ---@param cells { cols?: integer, rows?: integer, names?: string[] }|table<string, table>
    function M.atlas(name, ref, cells)
        atlases[name] = { ref = ref, cells = cells or {} }
        M.request(ref)
        return atlases[name]
    end

    function M._atlas_uv(atlas, cell, base)
        local cells = atlas.cells
        if cells.cols and cells.rows then
            local index = tonumber(cell)
            if not index and cells.names then
                for i = 1, #cells.names do
                    if cells.names[i] == cell then index = i break end
                end
            end
            if not index then return nil end
            index = index - 1
            local col = index % cells.cols
            local row = math.floor(index / cells.cols)
            if row >= cells.rows then return nil end
            return { col / cells.cols, row / cells.rows, (col + 1) / cells.cols, (row + 1) / cells.rows }
        end
        local rect = cells[cell]
        if type(rect) ~= "table" then return nil end
        if rect.x then
            local w, h = base and base.w or 0, base and base.h or 0
            if w == 0 or h == 0 then return nil end
            return { rect.x / w, rect.y / h, (rect.x + rect.w) / w, (rect.y + rect.h) / h }
        end
        return { rect[1], rect[2], rect[3], rect[4] }
    end

    -- --- drawing ------------------------------------------------------------

    --- Paints an asset NOW. Only legal inside a draw closure or a raw render
    --- callback; from a render job use M.submit, which queues in layer order.
    ---@param ref string
    ---@param pos vec2
    ---@param w number
    ---@param h number
    ---@param tint? color
    ---@param opts? { for_window?: boolean, speed?: number, uv?: number[] }
    ---@return boolean drawn
    -- The tint every texture is drawn with when the caller gives none. The
    -- contract says a nil colour defaults to white; the loader's own examples
    -- never rely on that and always pass one, and a nil that the binding
    -- read as "no colour" would paint every icon fully transparent -- which
    -- is indistinguishable from an icon that never loaded. So nil is never
    -- sent: white is.
    local WHITE
    do
        local ok, lib = pcall(require, "common/color")
        if ok and lib and type(lib.new) == "function" then
            local ok_c, c = pcall(lib.new, 255, 255, 255, 255)
            if ok_c then WHITE = c end
        end
        WHITE = WHITE or { r = 255, g = 255, b = 255, a = 255 }
    end
    M.WHITE = WHITE

    --- A native draw that threw is recorded on the entry and logged once,
    --- so a texture that is "ready" and still invisible has a reason on the
    --- debug page instead of being a mystery.
    local function note_draw(e, ok, err)
        if ok then
            e.draw_err = nil
            return true
        end
        err = tostring(err)
        if e.draw_err ~= err then
            e.draw_err = err
            log.fmt("warn", "asset %s draw failed: %s", e.key, err)
        end
        return false
    end

    function M.draw(ref, pos, w, h, tint, opts)
        local ok, e = M.request(ref)
        if not ok or not e then return false end
        local at = to_vec2(pos)
        local for_window = opts and opts.for_window or false
        tint = tint or WHITE
        if e.gif then
            local speed = opts and opts.speed or 1.0
            local uv = (opts and opts.uv) or e.uv
            if uv then
                return note_draw(e, pcall(core.graphics.draw_gif, e.gif, at, w, h, tint, for_window, speed, 0,
                    uv[1], uv[2], uv[3], uv[4]))
            end
            return note_draw(e, pcall(core.graphics.draw_gif, e.gif, at, w, h, tint, for_window, speed))
        end
        if not e.tex then return false end
        local uv = (opts and opts.uv) or e.uv
        if uv then
            return note_draw(e, pcall(core.graphics.draw_texture_rect, e.tex, at, w, h,
                uv[1], uv[2], uv[3], uv[4], tint, for_window))
        end
        return note_draw(e, pcall(core.graphics.draw_texture, e.tex, at, w, h, tint, for_window))
    end

    --- Queues an asset draw on the shared layer queue.
    ---@param ref string
    ---@param pos vec2
    ---@param w number
    ---@param h number
    ---@param tint? color
    ---@param opts? { layer?: integer, droppable?: boolean, speed?: number, uv?: number[] }
    ---@return boolean available True when the asset is loaded and will paint.
    function M.submit(ref, pos, w, h, tint, opts)
        local ok = M.request(ref)
        if not ok then return false end
        local at = to_vec2(pos)
        draw.submit(opts and opts.layer or draw.LAYER.OVERLAY, function()
            M.draw(ref, at, w, h, tint, opts)
        end, opts and opts.droppable)
        return true
    end

    --- Whether an asset is loaded, without queueing it.
    ---@param ref string
    ---@return boolean
    function M.is_ready(ref)
        local e = entries[ref]
        return e ~= nil and e.state == "ready"
    end

    -- --- the pump -----------------------------------------------------------
    --
    -- Every load and every scan is a coroutine. The pump resumes the active
    -- one until the frame budget is spent, then leaves it for the next frame.
    -- `checkpoint` is what a job calls between units of work; it yields when
    -- the budget is gone and is a no-op otherwise, so job code reads as
    -- straight-line Lua.

    local frame_start_ns = 0

    local function spent_ms()
        return (core.cpu_time() - frame_start_ns) * NS_TO_MS
    end

    local function checkpoint()
        if spent_ms() >= BUDGET_MS then coroutine.yield() end
    end

    --- Yields unconditionally: the next unit of work is a native read that is
    --- better placed at the start of a fresh frame budget.
    local function next_frame()
        coroutine.yield()
    end

    local function cache_path_for(url, ext)
        return "jcore/assets/" .. hash_string(url) .. "." .. (ext or "img")
    end

    local cache_folder_ready = false
    local function ensure_cache_folder()
        if cache_folder_ready then return end
        cache_folder_ready = true
        storage.create_folder("jcore")
        storage.create_folder("jcore/assets")
        storage.create_folder("jcore/game")
    end

    --- A file out of the client's own archives, through the casc service.
    --- Extracted once per client build and kept under scripts_data, because
    --- the extraction is a root-file scan the first time and a chunk read
    --- and inflate every time after -- neither of which belongs in a frame
    --- that already has the bytes on disk.
    local function fetch_game(e)
        local casc = rt.casc
        if not casc then return nil, "no archive reader in this build", true end
        local build = casc.build()
        if not build then
            -- For good: the reader keeps its reason for the session, so a
            -- retry can only fail the same way -- and each one put the entry
            -- back to loading, which blanked every mark drawing it for a
            -- frame. In the game this is every game: ref; the loader's files
            -- are the client folder, and the archives sit above it.
            -- The casc reader has already said why, once, in its own line;
            -- this one only adds what it means for the pictures.
            local _, why = casc.available()
            log.once("debug", "game_archives", string.format(
                "art from the game's archives is not available (%s); every game: picture falls back to its stand-in",
                tostring(why)))
            return nil, tostring(why), true, true
        end
        ensure_cache_folder()
        local key = casc.key(e.ref.path)
        local path = "jcore/game/" .. hash_string(build.key .. "|" .. key) .. "." .. (e.ref.ext or "bin")
        if (try(core.get_data_file_size, path) or 0) > 0 then
            local bytes = try(core.read_data_file, path)
            if bytes and #bytes > 0 then
                stats.cache_hits = stats.cache_hits + 1
                e.cache_path = path
                return bytes
            end
        end
        e.state = "loading"
        local bytes, err, permanent = casc.read(e.ref.path, checkpoint)
        if not bytes then return nil, "game archive: " .. tostring(err), permanent == true end
        storage.write(path, bytes)
        e.cache_path = path
        stats.extracted = stats.extracted + 1
        return bytes
    end

    --- Resolves a spell or item id to an icon name, asynchronously. Fills
    --- e.slug and re-queues the entry; on failure marks it.
    ---
    --- Through Wowhead's tooltip service only (1.8.3). Until then a spell
    --- went to the loader's icons_helper first, which reads the spell's page
    --- on www.wowhead.com. That site answers it 403 (seen 2026-10-04 for
    --- every id, and for a plain request from the same machine), and each
    --- refusal printed an [ERR] line in the console before the tooltip
    --- service, which answers the same ids, was asked.
    local function resolve_slug(e)
        local kind, id = e.kind, e.ref.id
        local known = data.slugs[kind][tostring(id)]
        if known then
            e.slug = known
            return true
        end

        if e.resolving then return false end
        e.resolving = true
        e.state = "resolving"

        -- Wowhead's data environments: 1 is the live game, 4 is Classic Era,
        -- 16 is Forever. Only 16 knows Forever's own spells (Bait and Tackle,
        -- 1278067, was "no icon name" in every other one), and it answers the
        -- classic ids and items as well. The client decides which is asked first.
        local envs
        if running_forever() then
            envs = { 16, 4, 1 }
        else
            local f = M.flavor()
            envs = (f:find("classic", 1, true) or f:find("anniversary", 1, true)) and { 4, 1 } or { 1, 4 }
        end
        local unreached = nil     -- why an environment could not be asked, if one could not

        local function attempt(i)
            if i > #envs then
                e.resolving = false
                if unreached then
                    -- Not an answer, so not for good: asked again after the backoff.
                    fail(e, "icon name for " .. kind .. " " .. id .. " not fetched: " .. unreached, false)
                else
                    -- Every environment said it has no such id. A spell
                    -- without its icon is drawn with its stand-in, so this
                    -- is no warning.
                    fail(e, "no icon name for " .. kind .. " " .. id, true, true)
                end
                return
            end
            local url = string.format(TOOLTIP_URL, kind, id, envs[i])
            net.get_json(url, { ttl = 3600 }, function(body, err, result)
                local slug = type(body) == "table" and body.icon
                if type(slug) == "string" and slug ~= "" then
                    e.slug = slug:lower()
                    data.slugs[kind][tostring(id)] = e.slug
                    store:touch()
                    e.resolving = false
                    e.state = "idle"
                    enqueue(e)
                else
                    local status = type(result) == "table" and tonumber(result.status) or nil
                    if err and status ~= 404 then unreached = tostring(err) end
                    attempt(i + 1)
                end
            end)
        end
        attempt(1)
        return false
    end

    --- Fetches bytes for an http-backed entry: from the disk cache when it
    --- is there, else downloads and stores them. Returns bytes or nil after
    --- arranging for a re-queue.
    local function fetch_http(e, url, ext)
        ensure_cache_folder()
        local path = cache_path_for(url, ext)
        if (try(core.get_data_file_size, path) or 0) > 0 then
            local bytes = try(core.read_data_file, path)
            if bytes and #bytes > 0 then
                stats.cache_hits = stats.cache_hits + 1
                e.cache_path = path
                return bytes
            end
        end

        if e.downloading then return nil end
        e.downloading = true
        e.state = "downloading"
        stats.downloads = stats.downloads + 1
        net.get(url, { ttl = 0 }, function(result)
            e.downloading = false
            if result.ok and result.body and #result.body > 0 then
                storage.write(path, result.body)
                e.cache_path = path
                e.bytes = result.body
                e.state = "idle"
                enqueue(e)
            else
                local status = result.status or 0
                fail(e, "http " .. tostring(status), status == 404 or status == 410)
            end
        end)
        return nil
    end

    --- The load job for one entry. Runs inside a coroutine.
    local function load_job(e)
        local kind = e.kind
        local bytes = e.bytes
        local ext = e.ref.ext

        if not bytes then
            if kind == "data" then
                bytes = try(core.read_data_file, e.ref.path)
                if not bytes or #bytes == 0 then
                    return fail(e, "not found under scripts_data: " .. e.ref.path, true)
                end
            elseif kind == "wow" or kind == "addon" then
                local rel = kind == "addon" and ("Interface/AddOns/" .. e.ref.path) or e.ref.path
                local path = kind == "addon" and M.wow_path(rel) or rel
                if not ext then
                    -- Addons name textures without an extension and let the
                    -- client pick. Probe the two it would.
                    if file_size_wow(path .. ".blp") > 0 then path, ext = path .. ".blp", "blp"
                    elseif file_size_wow(path .. ".tga") > 0 then path, ext = path .. ".tga", "tga"
                    elseif file_size_wow(path .. ".png") > 0 then path, ext = path .. ".png", "png"
                    end
                end
                e.resolved_path = path
                bytes = try(core.read_file, path)
                if not bytes or #bytes == 0 then
                    return fail(e, "not found in the game folder: " .. path, true)
                end
            elseif kind == "http" then
                bytes = fetch_http(e, e.ref.url, ext)
                if not bytes then return end
            elseif kind == "game" then
                local got, err, permanent, quiet = fetch_game(e)
                if not got then return fail(e, err, permanent, quiet) end
                bytes = got
            elseif kind == "icon" or kind == "spell" or kind == "item" then
                if kind ~= "icon" and not e.slug then
                    if not resolve_slug(e) then return end
                end
                local slug = e.slug or e.ref.slug
                e.label = slug
                bytes = fetch_http(e, M.icon_url(slug, "large"), "jpg")
                if not bytes then return end
            elseif kind == "tex" then
                return fail(e, "texture '" .. tostring(e.ref.name) .. "' was never registered", false)
            else
                return fail(e, "unsupported reference kind " .. tostring(kind), true)
            end
        end

        e.state = "loading"
        e.bytes = nil
        next_frame()

        local sniffed = image.sniff(bytes, ext)
        if sniffed == "gif" then
            local id, w, h = try(core.graphics.load_gif, bytes)
            if not id then return fail(e, "gif decode failed", true) end
            return ready(e, nil, w, h, id)
        end

        local out, info = image.to_native(bytes, {
            ext = ext, max_dim = data.max_dim or DEFAULT_MAX_DIM, step = checkpoint,
        })
        if not out then
            return fail(e, info.err or "unreadable image", true)
        end
        if info.converted then
            stats.converted = stats.converted + 1
            stats.decoded_pixels = stats.decoded_pixels + (info.w or 0) * (info.h or 0)
        end
        checkpoint()

        local tex, w, h = try(core.graphics.load_texture, out)
        if not tex and sniffed == "tga" and not info.converted then
            -- This build's loader does not read TGA; unpack it ourselves.
            out, info = image.to_native(bytes, { ext = ext, force_tga = true, step = checkpoint })
            if out then tex, w, h = try(core.graphics.load_texture, out) end
        end
        if not tex then
            return fail(e, "texture upload failed (" .. sniffed .. ")", true)
        end
        ready(e, tex, w or info.w, h or info.h, nil)
    end

    --- Runs the queue for this frame's budget. Registered on the update
    --- phase by main.lua.
    function M._pump()
        if not active and #queue == 0 then return end
        frame_start_ns = core.cpu_time()

        while spent_ms() < BUDGET_MS do
            if not active then
                local job = table.remove(queue, 1)
                if not job then break end
                if job.kind_job then
                    active = { co = coroutine.create(job.fn), name = job.name, entry = nil }
                else
                    if job.state ~= "queued" then
                        -- Re-queued while already handled; skip it.
                        job = nil
                    else
                        active = { co = coroutine.create(load_job), entry = job, name = job.key }
                    end
                end
                if not active then
                    if #queue == 0 then break end
                end
            end

            if active then
                local ok, err = coroutine.resume(active.co, active.entry)
                if not ok then
                    if active.entry then
                        fail(active.entry, "load crashed: " .. tostring(err), false)
                    else
                        log.fmt("error", "asset job %s crashed: %s", tostring(active.name), tostring(err))
                    end
                    active = nil
                elseif coroutine.status(active.co) == "dead" then
                    active = nil
                else
                    -- Yielded: out of budget or waiting for a fresh frame.
                    break
                end
            end
        end

        stats.pump_ms = spent_ms()
    end

    --- Queues an arbitrary coroutine job on the pump.
    ---@param name string
    ---@param fn function
    function M.job(name, fn)
        queue[#queue + 1] = { kind_job = true, name = name, fn = fn }
    end

    -- --- addon import -------------------------------------------------------

    local function toc_candidates(name)
        local suffixes = {
            "", "_Vanilla", "-Vanilla", "_Classic", "-Classic", "_TBC", "-TBC", "-BCC", "_Wrath", "-Wrath",
            "-WOTLKC", "_Cata", "-Cata", "_Mists", "-Mists", "_Mainline", "-Mainline", "_Standard",
        }
        local out = {}
        for i = 1, #suffixes do
            out[i] = "Interface/AddOns/" .. name .. "/" .. name .. suffixes[i] .. ".toc"
        end
        return out
    end

    --- Whether an addon folder exists, judged by its .toc. Cached per
    --- session; it costs up to a dozen size probes the first time.
    ---@param name string
    ---@return boolean
    ---@return string|nil toc_path
    local installed_cache = {}
    function M.addon_installed(name)
        local hit = installed_cache[name]
        if hit ~= nil then return hit and true or false, hit or nil end
        local candidates = toc_candidates(name)
        for i = 1, #candidates do
            if file_size_wow(M.wow_path(candidates[i])) > 0 then
                installed_cache[name] = candidates[i]
                return true, candidates[i]
            end
        end
        installed_cache[name] = false
        return false, nil
    end

    local function parse_toc(text)
        local meta, files = {}, {}
        for line in text:gmatch("[^\r\n]+") do
            local key, value = line:match("^##%s*([%w%-_]+)%s*:%s*(.-)%s*$")
            if key then
                meta[key:lower()] = value
            elseif not line:match("^%s*#") then
                local f = line:match("^%s*(.-)%s*$")
                if f ~= "" then files[#files + 1] = slashes(f) end
            end
        end
        return meta, files
    end

    local function dirname(p)
        return p:match("^(.*)/[^/]*$") or ""
    end

    --- Scans one addon for the textures it references. Asynchronous: the
    --- callback receives the catalog entry when the scan completes.
    ---@param name string Addon folder name.
    ---@param opts? { force?: boolean }
    ---@param callback? fun(result: table|nil, err: string|nil)
    function M.scan_addon(name, opts, callback)
        opts = opts or {}
        if type(opts) == "function" then opts, callback = {}, opts end
        if type(name) ~= "string" or name == "" then
            if callback then callback(nil, "addon name required") end
            return false
        end

        local existing = data.catalog[name]
        if existing and not opts.force then
            if callback then callback(existing) end
            return true
        end

        local present, first_toc = M.addon_installed(name)
        if not present then
            if callback then callback(nil, "addon '" .. name .. "' is not installed") end
            return false
        end

        M.job("scan:" .. name, function()
            local root = "Interface/AddOns/" .. name .. "/"
            local result = {
                name = name, entries = {}, files = 0, bytes = 0, scanned_at = core.time(),
                game_icons = 0, addon_textures = 0,
            }
            local seen_ref = {}
            local seen_file = {}
            local probes = 0

            local function add_entry(entry)
                if seen_ref[entry.ref] then return end
                seen_ref[entry.ref] = true
                result.entries[#result.entries + 1] = entry
                if entry.kind == "game" then
                    result.game_icons = result.game_icons + 1
                else
                    result.addon_textures = result.addon_textures + 1
                end
            end

            --- An Interface/AddOns/... path from source text, with or
            --- without an extension. Verified against the disk.
            local function consider_addon_path(rest)
                rest = slashes(rest):gsub("^/", "")
                if rest == "" or rest:sub(-1) == "/" then return end
                if #rest > 200 then return end
                local addon_name = rest:match("^([^/]+)/")
                if not addon_name then return end
                local ext = ext_of(rest)
                local candidates
                if ext then
                    if not IMAGE_EXT[ext] then return end
                    candidates = { rest }
                else
                    candidates = { rest .. ".blp", rest .. ".tga", rest .. ".png" }
                end
                for i = 1, #candidates do
                    if probes >= SCAN_MAX_PROBES then return end
                    probes = probes + 1
                    if file_size_wow(M.wow_path("Interface/AddOns/" .. candidates[i])) > 0 then
                        add_entry({
                            ref = "addon:" .. candidates[i], kind = "addon", source = name,
                            label = strip_ext(basename(candidates[i])),
                        })
                        return
                    end
                end
            end

            local function consider_game_icon(rest)
                local slug = strip_ext(basename(rest)):lower()
                if slug == "" or #slug > 80 or slug:find("[^%w_%-]") then return end
                add_entry({ ref = "icon:" .. slug, kind = "game", source = name, label = slug })
            end

            local function scan_text(text)
                -- Every Interface\...\ path, in any slash spelling, including
                -- the doubled backslashes of a Lua string literal.
                for rest in text:gmatch("[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee][\\/]+([%w_%-%.\\/]+)") do
                    local norm = slashes(rest)
                    local lower = norm:lower()
                    if lower:sub(1, 6) == "icons/" then
                        consider_game_icon(norm:sub(7))
                    elseif lower:sub(1, 7) == "addons/" then
                        consider_addon_path(norm:sub(8))
                    end
                end
            end

            -- The manifest(s).
            local pending = {}
            local candidates = toc_candidates(name)
            for i = 1, #candidates do
                local path = M.wow_path(candidates[i])
                if candidates[i] == first_toc or file_size_wow(path) > 0 then
                    local text = try(core.read_file, path)
                    next_frame()
                    if text and #text > 0 then
                        local meta, files = parse_toc(text)
                        result.title = result.title or meta.title
                        result.version = result.version or meta.version
                        result.notes = result.notes or meta.notes
                        local icon = meta.icontexture
                        if icon and icon ~= "" and not tonumber(icon) then
                            local rest = slashes(icon):match("^[Ii]nterface/[Aa]dd[Oo]ns/(.+)$")
                            if rest then
                                consider_addon_path(rest)
                                local ref = "addon:" .. slashes(rest)
                                if seen_ref[ref] or seen_ref[ref .. ".tga"] or seen_ref[ref .. ".blp"] then
                                    result.icon = seen_ref[ref] and ref
                                        or (seen_ref[ref .. ".tga"] and ref .. ".tga")
                                        or ref .. ".blp"
                                end
                            end
                        end
                        for j = 1, #files do
                            local f = files[j]
                            if not seen_file[f:lower()] then
                                seen_file[f:lower()] = true
                                pending[#pending + 1] = f
                            end
                        end
                    end
                end
            end

            -- The conventional icon names, when the manifest names none.
            if not result.icon then
                for _, guess in ipairs({ "icon", "Icon", "logo", "Logo", name }) do
                    for _, ext in ipairs({ ".tga", ".blp", ".png" }) do
                        local rel = name .. "/" .. guess .. ext
                        if probes < SCAN_MAX_PROBES and file_size_wow(M.wow_path("Interface/AddOns/" .. rel)) > 0 then
                            probes = probes + 1
                            result.icon = "addon:" .. rel
                            add_entry({ ref = result.icon, kind = "addon", source = name, label = guess })
                            break
                        end
                        probes = probes + 1
                    end
                    if result.icon then break end
                end
            end

            -- The source files, breadth first, bounded.
            local index = 1
            while index <= #pending and result.files < SCAN_MAX_FILES and result.bytes < SCAN_MAX_TOTAL_BYTES do
                local rel = pending[index]
                index = index + 1
                local ext = ext_of(rel)
                if ext == "lua" or ext == "xml" then
                    local path = M.wow_path(root .. rel)
                    local size = file_size_wow(path)
                    if size > 0 and size <= SCAN_MAX_FILE_BYTES then
                        local text = try(core.read_file, path)
                        next_frame()
                        if text and #text > 0 then
                            result.files = result.files + 1
                            result.bytes = result.bytes + #text
                            scan_text(text)
                            checkpoint()
                            if ext == "xml" then
                                local folder = dirname(rel)
                                for inc in text:gmatch("[Ff][Ii][Ll][Ee]%s*=%s*[\"']([^\"']+)[\"']") do
                                    local child = slashes(inc)
                                    local child_ext = ext_of(child)
                                    if child_ext == "lua" or child_ext == "xml" then
                                        local full = folder ~= "" and (folder .. "/" .. child) or child
                                        if not seen_file[full:lower()] then
                                            seen_file[full:lower()] = true
                                            pending[#pending + 1] = full
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            table.sort(result.entries, function(a, b) return a.ref < b.ref end)
            data.catalog[name] = result
            store:touch()
            stats.scans = stats.scans + 1
            log.fmt("info", "scanned addon %s: %d addon textures, %d game icons from %d files",
                name, result.addon_textures, result.game_icons, result.files)
            events.emit("jcore.assets.scanned", name, result)
            if callback then
                local ok, err = pcall(callback, result)
                if not ok then log.fmt("error", "scan callback failed: %s", tostring(err)) end
            end
        end)
        return true
    end

    --- Names of addons found on disk, from the known list plus the loader's
    --- own addon namespaces. Runs as a job because the probing is many
    --- native calls; the callback receives the list.
    ---@param callback fun(names: string[])
    function M.find_installed(callback)
        M.job("find_installed", function()
            local names, seen = {}, {}
            local list = {}
            for _, folder in pairs(NAMESPACE_FOLDERS) do list[#list + 1] = folder end
            for i = 1, #KNOWN_ADDONS do list[#list + 1] = KNOWN_ADDONS[i] end
            for i = 1, #list do
                local n = list[i]
                if not seen[n] then
                    seen[n] = true
                    if M.addon_installed(n) then names[#names + 1] = n end
                    checkpoint()
                end
            end
            table.sort(names)
            data.installed = { names = names, at = core.time() }
            store:touch()
            if callback then pcall(callback, names) end
        end)
    end

    --- Scans every installed addon it can find. Slow by design; runs across
    --- many frames.
    ---@param callback? fun(scanned: string[])
    function M.scan_installed(callback)
        M.find_installed(function(names)
            for i = 1, #names do
                M.scan_addon(names[i], { force = false })
            end
            if callback then pcall(callback, names) end
        end)
    end

    --- Scans a folder under scripts_data for image files.
    ---@param folder string e.g. "icons"; "" for the data root
    ---@param opts? { depth?: integer, force?: boolean }
    ---@param callback? fun(result: table)
    function M.scan_data(folder, opts, callback)
        opts = opts or {}
        if type(opts) == "function" then opts, callback = {}, opts end
        folder = slashes(folder or ""):gsub("/$", "")
        local key = folder == "" and "." or folder
        if data.data_catalog[key] and not opts.force then
            if callback then callback(data.data_catalog[key]) end
            return true
        end

        M.job("scan_data:" .. key, function()
            local result = { folder = folder, entries = {}, scanned_at = core.time() }
            local count = 0
            local max_depth = opts.depth or 4

            local function walk(dir, depth)
                if count >= DATA_SCAN_MAX_ENTRIES or depth > max_depth then return end
                local names = try(core.read_dir, dir == "" and "." or dir) or try(core.read_dir, dir)
                next_frame()
                if type(names) ~= "table" then return end
                for i = 1, #names do
                    local n = names[i]
                    local full = dir == "" and n or (dir .. "/" .. n)
                    local ext = ext_of(n)
                    if ext and IMAGE_EXT[ext] then
                        count = count + 1
                        result.entries[#result.entries + 1] = {
                            ref = "data:" .. full, kind = "data", source = key, label = strip_ext(n),
                        }
                    elseif not ext or #ext > 5 then
                        -- No extension: probably a folder. read_dir answers
                        -- nil for a file, so the recursion is self-limiting.
                        walk(full, depth + 1)
                    end
                    if count >= DATA_SCAN_MAX_ENTRIES then break end
                end
            end
            walk(folder, 1)

            table.sort(result.entries, function(a, b) return a.ref < b.ref end)
            data.data_catalog[key] = result
            store:touch()
            stats.scans = stats.scans + 1
            log.fmt("info", "scanned scripts_data/%s: %d images", key, #result.entries)
            events.emit("jcore.assets.scanned", "data:" .. key, result)
            if callback then pcall(callback, result) end
        end)
        return true
    end

    --- Adds a reference to the catalog with a label, so it shows in the
    --- browser and in queries. A plugin's own art belongs here.
    ---@param ref string
    ---@param meta? { label?: string, source?: string, tags?: string[] }
    function M.register(ref, meta)
        meta = meta or {}
        local parsed = M.parse(ref)
        if not parsed then return false end
        for i = 1, #registered do
            if registered[i].ref == parsed.key then
                registered[i].label = meta.label or registered[i].label
                return true
            end
        end
        registered[#registered + 1] = {
            ref = parsed.key, kind = "registered", source = meta.source or "plugin",
            label = meta.label or parsed.slug or basename(parsed.path or parsed.key), tags = meta.tags,
        }
        return true
    end

    --- Everything the catalog knows, flattened. `filter` narrows by source
    --- (an addon name, "data:<folder>", "registered") or by a substring of
    --- the label or reference.
    ---@param filter? { source?: string, text?: string, kind?: string, limit?: integer }
    ---@return table[] entries
    function M.catalog(filter)
        filter = filter or {}
        local text = filter.text and filter.text:lower() or nil
        local out = {}
        local limit = filter.limit or math.huge

        local function accept(entry)
            if filter.source and entry.source ~= filter.source then return false end
            if filter.kind and entry.kind ~= filter.kind then return false end
            if text and not (entry.label:lower():find(text, 1, true) or entry.ref:lower():find(text, 1, true)) then
                return false
            end
            return true
        end

        for i = 1, #registered do
            if #out >= limit then break end
            if accept(registered[i]) then out[#out + 1] = registered[i] end
        end
        for name, result in pairs(data.catalog) do
            if #out >= limit then break end
            for i = 1, #result.entries do
                local entry = result.entries[i]
                entry.source = entry.source or name
                if accept(entry) then
                    out[#out + 1] = entry
                    if #out >= limit then break end
                end
            end
        end
        for key, result in pairs(data.data_catalog) do
            if #out >= limit then break end
            for i = 1, #result.entries do
                local entry = result.entries[i]
                entry.source = entry.source or key
                if accept(entry) then
                    out[#out + 1] = entry
                    if #out >= limit then break end
                end
            end
        end
        return out
    end

    --- The catalog's sources with entry counts, for a filter strip.
    ---@return { name: string, count: integer, kind: string }[]
    function M.sources()
        local out = {}
        if #registered > 0 then out[#out + 1] = { name = "registered", count = #registered, kind = "registered" } end
        for name, result in pairs(data.catalog) do
            out[#out + 1] = { name = name, count = #result.entries, kind = "addon", title = result.title }
        end
        for key, result in pairs(data.data_catalog) do
            out[#out + 1] = { name = key, count = #result.entries, kind = "data" }
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end

    --- The catalog record for one addon, when it has been scanned.
    ---@param name string
    function M.addon_catalog(name)
        return data.catalog[name]
    end

    --- Drops a scanned catalog so the next scan starts fresh.
    ---@param name? string nil clears every catalog
    function M.clear_catalog(name)
        if name then
            data.catalog[name] = nil
            data.data_catalog[name] = nil
        else
            data.catalog = {}
            data.data_catalog = {}
        end
        store:touch()
    end

    ---@param n integer
    function M.set_max_dim(n)
        data.max_dim = math.max(16, math.floor(n or DEFAULT_MAX_DIM))
        store:touch()
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local by_state = {}
        local total = 0
        for key, e in pairs(entries) do
            if e.key == key then
                total = total + 1
                by_state[e.state] = (by_state[e.state] or 0) + 1
            end
        end
        return {
            entries   = total,
            ready     = by_state.ready or 0,
            queued    = #queue + (active and 1 or 0),
            failed    = by_state.failed or 0,
            loaded    = stats.loaded,
            converted = stats.converted,
            downloads = stats.downloads,
            cache_hits = stats.cache_hits,
            scans     = stats.scans,
            pump_ms   = stats.pump_ms,
            catalogs  = util.count(data.catalog) + util.count(data.data_catalog),
            flavor    = flavor or "?",
            active    = active and active.name or nil,
        }
    end

    --- Every entry, for the inspector.
    function M.entries()
        local out = {}
        for key, e in pairs(entries) do
            if e.key == key then out[#out + 1] = e end
        end
        table.sort(out, function(a, b) return a.key < b.key end)
        return out
    end

    return M
end

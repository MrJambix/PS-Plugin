-- Jambix AIO / react / custom -- your own reactions, and switches on the
-- built-in ones (1.76.0).
--
-- The user, 2026-10-05: a Reactions tab of its own, "Default Reactions and
-- then Create new Reaction for Class", with conditions, spells off the
-- spellbook, and where it applies -- open world, open world PvP,
-- battlegrounds, arenas, every dungeon and raid by name. Then: "capability
-- to write it in Code (lua) or by the functions... the functions and code
-- talk to each other".
--
-- WHAT A REACTION IS. A name, conditions (all of them, or any), actions
-- (the first that can go is the one sent), how important it is, how long to
-- wait between uses, and where it applies. Each condition and each action is
-- a GUI row or Lua code. Stored per class in scripts_data (the "reactions"
-- store), so every character of the class shares them.
--
-- ONE FUNCTION SET. Lua code reads `me`, `target`, `pet`, `group`, `fight`
-- and `where`, and calls check(), ready(), buff(), debuff(), cast()... A GUI
-- row is one of those reads (custom_data.lua names the expression each
-- stands for), so a row turns into Lua with one click, and Lua calls any row
-- by its key with check(key, op, value). The class's Library is Lua shared
-- by every reaction: a function made there is callable from any code and is
-- offered in the GUI as "My Lua function".
--
-- HOW IT RUNS. Each reaction is compiled into an engine rule ("My: <name>")
-- and weighed with the built-in ones: same scoring, same validation, same
-- cast arbiter. Code runs in a sandbox of its own (no core, no io), with a
-- watchdog on endless loops where the loader has the debug library.
--
-- THE BUILT-IN REACTIONS keep their code. Each can be switched off, or held
-- to some places, per class (engine.filter). Since 1.78.0 each comes set up
-- for the open world and for dungeons (a few pet reactions stay out of
-- dungeons and raids, custom_data's DEFAULT_PLACES), and the window has a
-- column for each. The Reactions page's master switch stops every reaction
-- but the Hardcore page's own (bail-out, the hearthstone), which keep their
-- own switches.
--
-- STARTER PACKS (1.78.0, packs.lua): ready-made reactions of your own for
-- dungeons and for the open world, for every class.

-- The globals that compile user code, read before the factory's `load`
-- parameter (the plugin's module loader) hides the global of that name.
local G_load, G_loadstring, G_setfenv, G_debug, G_unpack = load, loadstring, setfenv, debug, unpack

return function(R, P, lib, engine, load)
    local ctx, log = P.ctx, P.log
    local units, book = P.units, P.spellbook
    local D = load("modules/react/custom_data")
    local world = lib.world

    local M = { D = D }
    local huge, floor = math.huge, math.floor

    local function clock() return core.time() end

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function copy(v)
        if type(v) ~= "table" then return v end
        local out = {}
        for k, x in pairs(v) do out[k] = copy(x) end
        return out
    end
    M.copy = copy

    local function norm(s)
        s = tostring(s or ""):lower():gsub("\226\128\153", "'")
        s = s:gsub("^the ", "")
        return (s:gsub("[^%w]", ""))
    end

    -- ==========================================================================
    -- STORAGE
    -- ==========================================================================

    local store = ctx and ctx.store and ctx.store("reactions") or nil
    local data = store and store.data or {}
    if type(data.classes) ~= "table" then data.classes = {} end
    if type(data.seen) ~= "table" then data.seen = {} end

    local function touch()
        if store and store.touch then pcall(store.touch, store) end
    end

    local function class_key()
        local rot = P.rotation
        local ok, c = pcall(function() return rot and rot.detect_class and rot.detect_class() end)
        if ok and type(c) == "string" and c ~= "" then return c end
        return nil
    end
    M.class = class_key

    local ENV_KEYS = { "world", "world_pvp", "bg", "arena", "dungeon", "raid" }
    local PICK_OF = { bg = "bg_pick", arena = "arena_pick", dungeon = "dungeon_pick", raid = "raid_pick" }
    M.PICK_OF = PICK_OF

    local function fresh_env()
        return { world = true, world_pvp = true, bg = true, arena = true, dungeon = true, raid = true,
                 dungeon_pick = "Any", raid_pick = "Any", bg_pick = "Any", arena_pick = "Any" }
    end
    M.fresh_env = fresh_env

    --- Fills in what an older or hand-made reaction lacks.
    local function normalise(r, id)
        r.id = tonumber(r.id) or id
        r.name = type(r.name) == "string" and r.name or ("Reaction " .. tostring(r.id))
        r.on = r.on ~= false
        r.match = r.match == "any" and "any" or "all"
        if not D.IMPORTANCE_BY_KEY[r.importance or ""] then r.importance = "defensive" end
        r.priority = tonumber(r.priority) or D.IMPORTANCE_BY_KEY[r.importance].priority
        r.wait = tonumber(r.wait) or 0
        r.combat_only = r.combat_only ~= false
        r.off_gcd = r.off_gcd == true
        -- 1.79.0: at most so many a fight (0: no limit); an alert or a sound
        -- when it goes.
        r.per_fight = math.max(0, math.floor(tonumber(r.per_fight) or 0))
        r.notify_alert = r.notify_alert == true
        r.notify_sound = r.notify_sound == true
        if type(r.conds) ~= "table" then r.conds = {} end
        if type(r.actions) ~= "table" then r.actions = {} end
        local env = type(r.env) == "table" and r.env or {}
        local base = fresh_env()
        for k, v in pairs(base) do if env[k] == nil then env[k] = v end end
        r.env = env
        local top = 0
        for _, list in ipairs({ r.conds, r.actions }) do
            for _, row in ipairs(list) do top = math.max(top, tonumber(row.uid) or 0) end
        end
        for _, list in ipairs({ r.conds, r.actions }) do
            for _, row in ipairs(list) do
                if not tonumber(row.uid) then top = top + 1; row.uid = top end
                row.mode = row.mode == "lua" and "lua" or "gui"
                if row.for_s ~= nil then row.for_s = math.max(0, tonumber(row.for_s) or 0) end
            end
        end
        r.next_uid = math.max(tonumber(r.next_uid) or 0, top + 1)
        return r
    end
    M.normalise = normalise

    local normalised = {}       -- class -> true once its saved reactions were filled in

    local function bucket(cls)
        cls = cls or class_key()
        if not cls then return nil end
        local b = data.classes[cls]
        if type(b) ~= "table" then
            b = {}
            data.classes[cls] = b
        end
        if type(b.custom) ~= "table" then b.custom = {} end
        if type(b.defaults) ~= "table" then b.defaults = {} end
        if type(b.library) ~= "string" then b.library = D.LIBRARY_EXAMPLE end
        if not normalised[cls] then
            for i, r in ipairs(b.custom) do normalise(r, i) end
            b.normalised = nil
            normalised[cls] = true
        end
        local top = 0
        for _, r in ipairs(b.custom) do top = math.max(top, r.id or 0) end
        b.next_id = math.max(tonumber(b.next_id) or 1, top + 1)
        return b
    end
    M.bucket = bucket

    -- ==========================================================================
    -- WHERE YOU ARE
    -- ==========================================================================

    local KIND_OF = { party = "dungeon", raid = "raid", pvp = "bg", arena = "arena", scenario = "dungeon" }
    local LIST_OF = { dungeon = D.DUNGEONS, raid = D.RAIDS, bg = D.BATTLEGROUNDS, arena = D.ARENAS }
    local inst = { at = -huge, itype = "none", name = "", id = 0, kind = nil }

    local function remember(kind, name)
        local list = LIST_OF[kind]
        if not list or name == "" then return end
        local key = norm(name)
        for _, e in ipairs(list) do
            if norm(e.name) == key then return end
            for _, a in ipairs(e.aliases or {}) do if norm(a) == key then return end end
        end
        if type(data.seen[kind]) ~= "table" then data.seen[kind] = {} end
        if not data.seen[kind][name] then
            data.seen[kind][name] = true
            touch()
            log.fmt("info", "reactions: learned the %s %s (offered in the Reactions window from now on)", kind, name)
        end
    end

    local function instance_now()
        local now = clock()
        if (now - inst.at) < 1.0 then return inst end
        inst.at = now
        local w = ctx and ctx.world
        local itype = w and try(w.instance_type) or "none"
        itype = type(itype) == "string" and itype:lower() or "none"
        inst.itype = itype
        local name = w and try(w.instance_name) or ""
        inst.name = type(name) == "string" and name or ""
        inst.id = tonumber(w and try(w.instance_id)) or 0
        inst.kind = KIND_OF[itype] or ((itype ~= "none" and itype ~= "") and "dungeon" or nil)
        if inst.kind then remember(inst.kind, inst.name) end
        return inst
    end

    local function latest_W()
        local W = world and world.W
        if W and W.player and W.player.unit and math.abs(clock() - (W.now or -huge)) <= 1.5 then return W end
        return nil
    end
    M.latest_W = latest_W

    --- Where you are: world, world_pvp, bg, arena, dungeon or raid, and the
    --- instance's name.
    ---@param W? table
    ---@return string kind
    ---@return string name
    ---@return integer id
    function M.where(W)
        if W and W.bench then return W.bench.where or "world", W.bench.where_name or "", 0 end
        local i = instance_now()
        local kind = i.kind
        if not kind then
            W = W or latest_W()
            kind = (W and W.env and W.env.pvp) and "world_pvp" or "world"
        end
        return kind, i.name, i.id
    end

    local function entry_of(list, pick)
        for _, e in ipairs(list or {}) do
            if e.name == pick then return e end
        end
        return nil
    end

    --- Is the instance `name` (id) the one picked?
    function M.place_matches(pick, kind, name, id)
        if type(pick) ~= "string" or pick == "" or pick == "Any" then return true end
        local e = entry_of(LIST_OF[kind], pick)
        local here = norm(name)
        if e then
            if here ~= "" then
                if norm(e.name) == here then return true end
                for _, a in ipairs(e.aliases or {}) do if norm(a) == here then return true end end
                return false
            end
            return (id or 0) ~= 0 and e.id == id
        end
        return here ~= "" and norm(pick) == here
    end

    --- Does this environment (a reaction's, or a built-in's) allow acting here?
    local function env_ok(env, W)
        if type(env) ~= "table" then return true end
        local kind, name, id = M.where(W)
        if env[kind] == false then return false end
        local pk = PICK_OF[kind]
        if pk then return M.place_matches(env[pk], kind, name, id) end
        return true
    end
    M.env_ok = env_ok

    --- "Any" and every instance of a kind, the learned ones after the list.
    function M.places(kind)
        instance_now()          -- the one you stand in is learned first
        local out = { "Any" }
        local seen = {}
        for _, e in ipairs(LIST_OF[kind] or {}) do
            out[#out + 1] = e.name
            seen[e.name] = true
        end
        local learned = {}
        for name in pairs(type(data.seen[kind]) == "table" and data.seen[kind] or {}) do
            if not seen[name] then learned[#learned + 1] = name end
        end
        table.sort(learned)
        for _, n in ipairs(learned) do out[#out + 1] = n end
        return out
    end

    function M.place_info(kind, name)
        return entry_of(LIST_OF[kind], name)
    end

    local WHERE_LABEL = {}
    for _, w in ipairs(D.WHERE) do WHERE_LABEL[w.key] = w.label end

    --- "Dungeon: The Deadmines", for the window.
    function M.where_text()
        local kind, name = M.where()
        local label = WHERE_LABEL[kind] or kind
        if name ~= "" and kind ~= "world" and kind ~= "world_pvp" then return label .. ": " .. name end
        return label
    end

    --- One line for an environment: "Everywhere", "Dungeons only (The
    --- Deadmines)", "Not in: Arenas, Raids".
    function M.env_text(env)
        if type(env) ~= "table" then return "Everywhere" end
        local on, off, narrowed = {}, {}, {}
        for _, e in ipairs(D.ENV) do
            local label = (e.label:gsub(" %(PvP%)", ""))
            local pk = PICK_OF[e.key]
            if env[e.key] == false then
                off[#off + 1] = label
            elseif pk and env[pk] and env[pk] ~= "Any" then
                on[#on + 1] = env[pk]
                narrowed[#narrowed + 1] = label .. ": " .. env[pk] .. " only"
            else
                on[#on + 1] = label
            end
        end
        if #off == 0 and #narrowed == 0 then return "Everywhere" end
        if #on == 0 then return "Nowhere (every place is off)" end
        if #on <= 3 then return "Only: " .. table.concat(on, ", ") end
        local parts = {}
        if #off > 0 then parts[#parts + 1] = "not in " .. table.concat(off, ", ") end
        for _, n in ipairs(narrowed) do parts[#parts + 1] = n end
        return "Everywhere; " .. table.concat(parts, "; ")
    end

    -- ==========================================================================
    -- THE FUNCTION SET: what the GUI rows and the Lua code both read
    -- ==========================================================================

    local cur_W = nil           -- the engine's picture, while a reaction is being asked
    local collect = nil         -- an action's queue, while action code runs
    local aura_cache, aura_at = {}, nil
    local ITEM_KIND = {}        -- "healthstone", "potion"...: use() takes any other word as an item's name
    for _, it in ipairs(D.ITEMS) do ITEM_KIND[it.key] = true end

    local function W_() return cur_W end

    local function pct(x) return (tonumber(x) or 0) * 100 end
    local function finite(x, cap) x = tonumber(x) or 0; if x == huge or x > cap then return cap end return x end

    -- --- reads that are worked out, not taken from the picture (1.79.0) -----
    --
    -- Each answers from the test bench's situation when the picture is one
    -- (W.bench), so the bench and the fight read the same names.

    local combat_since = nil    -- when this fight started (after_decide keeps it)

    local function combat_time(W)
        if W.bench then return tonumber(W.bench.combat_time) or 0 end
        if not W.player.in_combat or not combat_since then return 0 end
        return math.max(0, (W.now or clock()) - combat_since)
    end

    local group_cache = { at = nil, lowest = 100, hurt = 0 }
    local function group_health(W)
        if W.bench then return tonumber(W.bench.lowest) or 100, tonumber(W.bench.hurt) or 0 end
        if group_cache.at == W.now then return group_cache.lowest, group_cache.hurt end
        group_cache.at = W.now
        local lowest, hurt = 100, 0
        local g = ctx and ctx.group
        if W.group.in_group and g then
            local unit = g.lowest_health and try(g.lowest_health)
            local hf = unit and units.health_fraction and try(units.health_fraction, unit)
            if type(hf) == "number" then lowest = hf * 100 end
            hurt = tonumber(g.count_below and try(g.count_below, 0.5)) or 0
        end
        group_cache.lowest, group_cache.hurt = lowest, hurt
        return lowest, hurt
    end

    --- Hostiles within `yd` of you (any, not only the fight's); `players`
    --- counts enemy players within 40 yd.
    local function enemies_within(W, yd, players)
        if W.bench then
            if players then return tonumber(W.bench.players) or 0 end
            return tonumber(yd <= 8 and W.bench.within8 or W.bench.within30) or 0
        end
        local n = 0
        local rows = W.enemies.list or {}
        for i = 1, W.enemies.count or 0 do
            local r = rows[i]
            if r and not r.dead and (r.hp or 1) > 0 and (r.dist or huge) <= yd then
                if not players then
                    n = n + 1
                else
                    local f = world and world.facts and r.obj and world.facts(r.obj, r.guid) or nil
                    if f and f.player then n = n + 1 end
                end
            end
        end
        return n
    end

    local ME = {
        hp = function(W) return pct(W.player.hp) end,
        falling = function(W) return math.max(0, -(W.player.hp_rate or 0) * 100) end,
        ttl = function(W) return finite(W.player.ttl, 999) end,
        power = function(W) return W.player.power or 0 end,
        power_pct = function(W) return pct(W.player.power_pct) end,
        power_kind = function(W) return W.player.power_kind or "MANA" end,
        combo = function(W) return (W.s and tonumber(W.s.combo)) or 0 end,
        level = function(W) return W.player.level or 0 end,
        in_combat = function(W) return W.player.in_combat == true end,
        moving = function(W) return W.player.moving == true end,
        casting = function(W) return W.player.busy == true end,
        channelling = function(W) return W.player.channelling == true end,
        attacking = function(W) return W.player.auto_attacking == true or W.player.shooting == true end,
        controlled = function(W) return W.player.control ~= nil end,
        healthstone = function(W) return W.player.healthstone == true end,
        potion = function(W) return W.player.potion == true end,
        mana_potion = function(W) return W.player.mana_potion == true end,
        mana_gem = function(W) return W.player.mana_gem == true end,
        combat_time = combat_time,
        -- 1.81.0: PvP (react/pvp.lua). What controls you, by mechanic ("" for
        -- nothing), and whether a worn control-breaking trinket is ready.
        control_kind = function(W)
            local V = W.pvp
            local c = V and (V.control or V.root or V.snare)
            if c then return c.mech or "" end
            if W.bench then return W.player.control and "stun" or "" end
            return ""
        end,
        -- PvP intelligence, Stage 3: a protection of yours up that covers
        -- something (Deterrence, Evasion, a bubble, a shield) for 1.5 s or more.
        protected = function(W)
            local C = W.intel and W.intel.cds
            local pr = C and C.protection
            if not pr then return false end
            return (pr.physical >= 0.8 or pr.spell >= 0.8 or pr.melee >= 0.8) and (pr.left or 0) >= 1.5
        end,
        -- Stage 4: inside your minimum ranged distance; a safe escape.
        dead_zone = function(W)
            local I = W.intel
            local zone = I and I.active and I.env and I.env.target and I.env.target.zone or nil
            return zone == "melee" or zone == "dead_zone"
        end,
        safe_escape = function(W)
            local I = W.intel
            if not (I and I.active) then return false end
            local me = I.me
            if (me.escapes_ready or 0) == 0 then return false end
            if me.control and me.control.helpless then return false end
            if (I.melee_attackers or 0) == 0 then return true end
            -- Someone in melee: safe only once it is slowed or held (the move
            -- advice then says to step out).
            return I.pos ~= nil and I.pos.advice == "increase"
        end,
        pvp_trinket = function()
            local pvp, hc = lib.pvp, P.hardcore
            if not (pvp and pvp.trinkets and hc and hc.named_ready) then return false end
            for _, t in ipairs(pvp.trinkets()) do
                if t.breaks and hc.named_ready(t.name) then return true end
            end
            return false
        end,
    }
    local TARGET = {
        exists = function(W) return W.target.unit ~= nil end,
        name = function(W)
            if W.bench then return W.target.unit and (W.bench.t_name or "") or "" end
            return W.target.unit and (try(units.name, W.target.unit) or "") or ""
        end,
        fleeing = function(W) return W.target.unit ~= nil and W.target.activity == "fleeing" end,
        on_tank = function(W)
            return W.target.target_guid ~= nil and W.target.target_guid == W.group.tank_guid
        end,
        on_healer = function(W)
            return W.target.target_guid ~= nil and W.target.target_guid == W.group.healer_guid
        end,
        on_group = function(W) return W.target.targets_group == true end,
        hp = function(W) return W.target.unit and pct(W.target.hp) or 0 end,
        distance = function(W) return finite(W.target.distance, 999) end,
        ttd = function(W) return finite(W.target.ttd, 999) end,
        casting = function(W) return W.target.casting == true end,
        cast_name = function(W) return W.target.casting and (W.target.cast.name or "") or "" end,
        cast_left = function(W) return W.target.casting and (W.target.cast.remaining or 0) or 0 end,
        interruptible = function(W) return W.target.casting == true and W.target.cast.interruptible == true end,
        on_me = function(W) return W.target.targets_me == true end,
        on_pet = function(W) return W.target.targets_pet == true end,
        elite = function(W) return W.target.elite == true end,
        boss = function(W) return W.target.boss == true end,
        rare = function(W) return W.target.rare == true end,
        player = function(W) return W.target.player == true end,
        level_diff = function(W) return W.target.level_diff or 0 end,
        creature = function(W) return D.CREATURE_BY_ID[W.target.creature or 0] or "" end,
        controlled = function(W) return W.target.controlled == true end,
        threat = function(W) return tonumber(W.target.threat_pct) or 0 end,
        runs = function(W) return W.target.runs == true end,
        others = function(W) return W.target.others_fight == true end,
        evading = function(W) return W.target.evading == true end,
        -- 1.81.0: a player target, from its auras (react/pvp.lua).
        immune = function(W) local st = W.pvp and W.pvp.target return st ~= nil and st.immune ~= nil end,
        bursting = function(W) local st = W.pvp and W.pvp.target return st ~= nil and st.burst ~= nil end,
        trinket_down = function(W) local st = W.pvp and W.pvp.target return st ~= nil and st.trinket_down == true end,
        -- PvP intelligence (react/intel, Stage 2): the target as a player in
        -- the picture. Absent (the bench, the layer off): false.
        mobility = function(W)
            local I = W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            if not f or not I.threat then return false end
            local now = I.now or 0
            local recent = f.recent or {}
            for k = #recent, 1, -1 do
                local r = recent[k]
                if (now - r.at) > 3.0 then break end
                if I.mobility_names and I.mobility_names[r.name] then return true end
            end
            return false
        end,
        defensive = function(W)
            local I = W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            local st = f and f.st or nil
            if not st then return false end
            if st.immune or st.avoid then return true end
            for i = 1, #(st.purge or {}) do
                if I.protection_names and I.protection_names[st.purge[i].name] then return true end
            end
            return false
        end,
        -- Seconds left on the control on the target (0: none), for "about to
        -- expire": the control plan's row (Stage 6), the picture's under it.
        cc_left = function(W)
            local I = W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            local c = f and ((f.cc and f.cc.held) or f.control) or nil
            return c and (tonumber(c.left) or 0) or 0
        end,
        -- The control plan (react/intel/ccplan.lua): what keeping the control
        -- on the target is worth, what the next control gets, whose it is.
        cc_value = function(W)
            local I = W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            return f and f.cc and f.cc.value and f.cc.value.kind or "none"
        end,
        dr_next = function(W)
            local I = W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            return f and f.cc and f.cc.next_level or "full"
        end,
        cc_ours = function(W)
            local I = W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            local h = f and f.cc and f.cc.held or nil
            return h ~= nil and h.ours ~= "no"
        end,
        -- Opponent prediction (react/intel/predict.lua): the target's surest
        -- pattern this session ("none" when nothing is sure), and how sure (%).
        pattern = function(W)
            local I = W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            local best, p = "none", 0
            for key, e in pairs(f and f.predict or {}) do
                if e.sure and not e.adapting and (e.p or 0) > p then best, p = key, e.p end
            end
            return best
        end,
        -- The surest pattern's rate (%), and the evidence behind it (%): two
        -- chances read 50, however high the rate.
        pattern_conf = function(W)
            local I = W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            local p = 0
            for _, e in pairs(f and f.predict or {}) do
                if (e.p or 0) > p then p = e.p end
            end
            return math.floor(p * 100 + 0.5)
        end,
        pattern_reliability = function(W)
            local I = W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            local p, rel = 0, 0
            for _, e in pairs(f and f.predict or {}) do
                if (e.p or 0) > p then p, rel = e.p, e.reliability or 0 end
            end
            return math.floor(rel * 100 + 0.5)
        end,
        -- The kill window (react/intel/killwindow.lua, Stage 9): its verdict
        -- on the target ("NO_KILL_OPPORTUNITY" with none), and how sure (%).
        kill_verdict = function(W)
            local k = W.intel and W.intel.kill and W.intel.kill.target or nil
            return (k and k.guid == W.target.guid and k.v) or "NO_KILL_OPPORTUNITY"
        end,
        kill_conf = function(W)
            local k = W.intel and W.intel.kill and W.intel.kill.target or nil
            return (k and k.guid == W.target.guid) and math.floor((k.conf or 0) * 100 + 0.5) or 0
        end,
    }
    local PET = {
        exists = function(W) return W.pet.alive == true end,
        hp = function(W) return W.pet.alive and pct(W.pet.hp) or 0 end,
        attackers = function(W) return W.pet.attackers or 0 end,
        -- PvP intelligence: the pet is on a player held by a control damage
        -- breaks -- the control plan's word (Stage 6), the picture's under it.
        breaks_cc = function(W)
            local I = W.intel
            if I and I.cc and I.cc.pet then return I.cc.pet.recall == true end
            return I ~= nil and I.pet ~= nil and I.pet.on_controlled == true
        end,
        tanking = function(W) return W.pet.tanking == true end,
    }
    local GROUP = {
        in_group = function(W) return W.group.in_group == true end,
        in_raid = function(W) return W.group.in_raid == true end,
        members = function(W) return W.group.members or 0 end,
        dead = function(W) return W.group.dead or 0 end,
        tank_alive = function(W) return W.group.tank_alive == true end,
        healer_alive = function(W) return W.group.healer_alive == true end,
        healer_controlled = function(W) return W.group.healer_controlled == true end,
        lowest = function(W) return (group_health(W)) end,
        hurt = function(W) local _, n = group_health(W) return n end,
    }
    local FIGHT = {
        mode = function(W) return W.mode or "NORMAL" end,
        danger = function(W) return W.env.danger or 0 end,
        engaged = function(W) return W.enemies.engaged or 0 end,
        on_me = function(W) return W.enemies.on_me or 0 end,
        melee_on_me = function(W) return W.enemies.melee_on_me or 0 end,
        nearby = function(W) return W.enemies.nearby or 0 end,
        casting = function(W) return W.enemies.casting_n or 0 end,
        elites = function(W) return W.enemies.elites or 0 end,
        boss = function(W) return W.env.boss == true end,
        pvp = function(W) return W.env.pvp == true end,
        -- PvP intelligence (react/intel/threat.lua, Stage 2). Absent: calm.
        threat = function(W) local T = W.intel and W.intel.threat return T and T.level or "INFORMATIONAL" end,
        threat_score = function(W) local T = W.intel and W.intel.threat return T and math.floor((T.score or 0) + 0.5) or 0 end,
        incoming_cast = function(W) local T = W.intel and W.intel.threat return T ~= nil and T.incoming_cast == true end,
        -- Stage 4: the tactical state and the move.
        tactic = function(W) local X = W.intel and W.intel.tactic return X and X.state or "NONE" end,
        advice = function(W) local Pm = W.intel and W.intel.pos return Pm and Pm.advice or "none" end,
        kill_window = function(W) local X = W.intel and W.intel.tactic return X ~= nil and X.state == "KILL_WINDOW" end,
        -- Bait detection (react/intel/bait.lua): the bait on the target, or "none".
        bait = function(W)
            local B = W.intel and W.intel.bait
            return B and B.target and B.target.kind or "none"
        end,
        within8 = function(W) return enemies_within(W, 8) end,
        within30 = function(W) return enemies_within(W, 30) end,
        players = function(W) return enemies_within(W, 40, true) end,
        -- Teamfights (react/intel/team.lua, Stage 10). Absent: none of them.
        team_focus_me = function(W) local T = W.intel and W.intel.team return T ~= nil and T.focus ~= nil and T.focus.on_me == true end,
        team_peel = function(W) local T = W.intel and W.intel.team return T ~= nil and T.peel ~= nil end,
        team_interrupt = function(W) local T = W.intel and W.intel.team return T ~= nil and T.interrupt ~= nil end,
        team_switch = function(W) local T = W.intel and W.intel.team return T ~= nil and T.switch ~= nil end,
        healer_free = function(W) local T = W.intel and W.intel.team return T ~= nil and T.healer ~= nil and T.healer.free == true end,
        overextended = function(W) local T = W.intel and W.intel.team return T ~= nil and T.overextended ~= nil end,
        disengage = function(W) local T = W.intel and W.intel.team return T ~= nil and T.disengage ~= nil end,
        ally_cc_target = function(W) local T = W.intel and W.intel.team return T ~= nil and T.overlap ~= nil end,
    }
    local WHERE = {
        kind = function(W) return (M.where(W)) end,
        name = function(W) local _, n = M.where(W) return n end,
    }

    local function proxy(fields, label)
        return setmetatable({}, {
            __index = function(_, k)
                local f = fields[k]
                if not f then return nil end
                local W = cur_W
                if not W then error("no fight picture yet (the rotation is not running)", 2) end
                return f(W)
            end,
            __newindex = function() error(label .. " is read-only", 2) end,
        })
    end

    local API = {
        me = proxy(ME, "me"), target = proxy(TARGET, "target"), pet = proxy(PET, "pet"),
        group = proxy(GROUP, "group"), fight = proxy(FIGHT, "fight"), where = proxy(WHERE, "where"),
    }

    --- An aura by name on the player (the engine's index) or the target: its
    --- row, or nil. On the test bench, from the situation's lists, whose rows
    --- carry `left` and `stacks` themselves.
    local function aura_row(unit, name, mine, W)
        if type(name) ~= "string" or name == "" or not unit then return nil end
        if W.bench then
            local list = (unit == W.player.unit) and W.bench.buffs or W.bench.debuffs
            local row = type(list) == "table" and list[name:lower()] or nil
            if row and mine and row.mine == false then return nil end
            return row
        end
        if aura_at ~= W.now then aura_cache, aura_at = {}, W.now end
        local key = tostring(unit) .. "\1" .. name .. (mine and "\1m" or "")
        local hit = aura_cache[key]
        if hit ~= nil then return hit or nil end
        local want = name:lower()
        local found = false
        local index = units.aura_index and try(units.aura_index, unit) or nil
        if type(index) == "table" then
            for _, aura in pairs(index) do
                local n = type(aura) == "table" and aura.buff_name or nil
                if type(n) == "string" and n:lower() == want then
                    if not mine then found = aura break end
                    local caster = aura.caster
                    local guid = caster and try(caster.get_guid, caster) or nil
                    if guid == nil or guid == W.player.guid then found = aura break end
                end
            end
        end
        aura_cache[key] = found
        return found or nil
    end

    local function aura_named(unit, name, mine, W) return aura_row(unit, name, mine, W) ~= nil end

    --- Seconds left on an aura row: 0 when there is none, 999 when it never
    --- runs out. expire_time is engine time in milliseconds (JCore's units).
    local function aura_left(row, W)
        if not row then return 0 end
        if row.left ~= nil then return tonumber(row.left) or 0 end
        local e = tonumber(row.expire_time)
        if not e or e <= 0 then return 999 end
        local now_ms = (core.game_time and core.game_time()) or ((W.now or clock()) * 1000)
        return math.max(0, (e - now_ms) / 1000)
    end

    local function aura_stacks(row)
        if not row then return 0 end
        return math.max(1, tonumber(row.stacks or row.count) or 1)
    end

    local function resolve_target(word, W)
        word = type(word) == "string" and word:lower() or "target"
        if word == "target" or word == "enemy" then return W.target.unit, "enemy" end
        if word == "self" or word == "me" or word == "player" then return W.player.unit, "self" end
        if word == "pet" then return W.pet.alive and W.pet.unit or nil, "pet" end
        if word == "tank" then return W.group.tank, "ally" end
        if word == "healer" then return W.group.healer, "ally" end
        if word == "caster" then
            local best, best_score = nil, -huge
            for i = 1, W.enemies.casting_n or 0 do
                local c = W.enemies.casting[i]
                if c and c.unit and not (c.row and c.row.control) then
                    local score = (c.interruptible and 100 or 0) + (c.engaged and 50 or 0) + (c.current and 20 or 0)
                        - (c.dist or 40)
                    if score > best_score then best, best_score = c.unit, score end
                end
            end
            return best, "enemy"
        end
        if word == "attacker" then
            local best, best_d = nil, huge
            local rows = W.enemies.list or {}
            for i = 1, W.enemies.count or 0 do
                local r = rows[i]
                if r and r.obj and r.targeting_me and not r.control and not r.dead and r.guid ~= W.target.guid
                    and (r.dist or huge) < best_d then
                    best, best_d = r.obj, r.dist or huge
                end
            end
            return best, "enemy"
        end
        -- 1.79.0: for "Switch my target", and cast() as well.
        if word == "tank_target" then
            local tank = W.group.tank
            if not tank then return nil, "enemy" end
            if W.bench then return W.bench.tank_target and W.target.unit or nil, "enemy" end
            local t = try(tank.get_target, tank)
            if t and units.guid and units.guid(t) == W.player.guid then t = nil end
            return t, "enemy"
        end
        local rows = W.enemies.list or {}
        if word == "healer_attacker" then
            local hg = W.group.healer_guid
            if not hg then return nil, "enemy" end
            for i = 1, W.enemies.count or 0 do
                local r = rows[i]
                if r and r.obj and not r.dead and r.target_guid == hg then return r.obj, "enemy" end
            end
            return nil, "enemy"
        end
        if word == "lowest" or word == "nearest" then
            local best, best_v = nil, huge
            for i = 1, W.enemies.count or 0 do
                local r = rows[i]
                if r and r.obj and r.engaged and not r.dead and not r.control and (r.hp or 1) > 0 then
                    local v = word == "lowest" and (r.hp or 1) or (r.dist or huge)
                    if v < best_v then best, best_v = r.obj, v end
                end
            end
            return best, "enemy"
        end
        return W.target.unit, "enemy"
    end
    M.resolve_target = resolve_target

    --- Is this key held? The client's answer, or the test bench's.
    local function key_held(vk, W)
        vk = tonumber(vk)
        if not vk or vk <= 0 then return false end
        if W and W.bench then return W.bench.key == true end
        local inp = ctx and ctx.input
        if inp and inp.is_key_pressed then return try(inp.is_key_pressed, vk) == true end
        local raw = core.input and core.input.is_key_pressed
        return raw and try(raw, vk) == true or false
    end

    local eval_gui         -- below; check() calls it
    local env_for          -- below; the Lua env of the class
    local log_seen = {}

    local FUNCS = {
        check = function(key, op, value)
            local W = cur_W
            if not W then error("no fight picture yet", 2) end
            local ok = eval_gui({ key = key, op = op, value = value }, W)
            return ok
        end,
        known = function(name) return book.known(tostring(name)) end,
        ready = function(name) return book.known(tostring(name)) and book.ready(tostring(name)) end,
        cooldown = function(name)
            local cd = book.cooldown and book.cooldown(tostring(name)) or huge
            return finite(cd, 999)
        end,
        buff = function(name)
            local W = cur_W
            if not W then return false end
            local names = W.player.aura_names
            if names and names[name] then return true end
            return aura_named(W.player.unit, name, false, W)
        end,
        debuff = function(name, mine)
            local W = cur_W
            if not W or not W.target.unit then return false end
            return aura_named(W.target.unit, name, mine == true, W)
        end,
        -- 1.79.0: seconds left and stacks; a key; an item carried.
        buff_left = function(name)
            local W = cur_W
            if not W then return 0 end
            return aura_left(aura_row(W.player.unit, tostring(name or ""), false, W), W)
        end,
        buff_stacks = function(name)
            local W = cur_W
            if not W then return 0 end
            return aura_stacks(aura_row(W.player.unit, tostring(name or ""), false, W))
        end,
        debuff_left = function(name, mine)
            local W = cur_W
            if not W or not W.target.unit then return 0 end
            return aura_left(aura_row(W.target.unit, tostring(name or ""), mine ~= false, W), W)
        end,
        debuff_stacks = function(name, mine)
            local W = cur_W
            if not W or not W.target.unit then return 0 end
            return aura_stacks(aura_row(W.target.unit, tostring(name or ""), mine == true, W))
        end,
        key = function(vk) return key_held(vk, cur_W) end,
        -- PvP intelligence, Stage 3 (react/intel/cooldowns.lua): the target's
        -- ledger. Never seen, or a cooldown the tables do not carry: not
        -- "ready" -- enemy_cd_ready_in answers 999 then.
        enemy_cd_seen = function(name)
            local W = cur_W
            local I = W and W.intel
            local cds = P.react and P.react.intel and P.react.intel.cooldowns
            if not (I and cds and W.target.guid) then return false end
            return cds.seen(I, W.target.guid, tostring(name or "")) ~= nil
        end,
        enemy_cd_ready_in = function(name)
            local W = cur_W
            local I = W and W.intel
            local cds = P.react and P.react.intel and P.react.intel.cooldowns
            if not (I and cds and W.target.guid) then return 999 end
            local left = cds.ready_in(I, W.target.guid, tostring(name or ""))
            if left == nil then return 999 end
            return left
        end,
        -- Opponent prediction (react/intel/predict.lua): how sure the layer
        -- is of a pattern of the target's, 0 to 1 (0: nothing seen).
        prediction_confidence = function(key)
            local W = cur_W
            local I = W and W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            local e = f and f.predict and f.predict[tostring(key or "")] or nil
            return e and e.p or 0
        end,
        -- The evidence behind that rate, 0 to 1 (two chances: 0.5).
        prediction_reliability = function(key)
            local W = cur_W
            local I = W and W.intel
            local f = I and I.foes and W.target.guid and I.foes[W.target.guid] or nil
            local e = f and f.predict and f.predict[tostring(key or "")] or nil
            return e and e.reliability or 0
        end,
        has_item = function(name)
            name = tostring(name or "")
            local W = cur_W
            if W and W.bench then return type(W.bench.items) == "table" and W.bench.items[name:lower()] == true end
            local hc = P.hardcore
            return hc ~= nil and hc.named ~= nil and hc.named(name) ~= nil
        end,
        -- Instant (1.79.0): they never end the action list, and go at most
        -- once a few seconds while the conditions hold (custom.lua's
        -- `instant`). Outside an action they do nothing.
        alert = function(text, color, sound)
            if not collect then return false end
            collect.instants = collect.instants or {}
            table.insert(collect.instants, { kind = "alert", text = tostring(text or "!"), color = color,
                sound = sound ~= false })
            return true
        end,
        set_target = function(who)
            if not collect then return false end
            collect.instants = collect.instants or {}
            table.insert(collect.instants, { kind = "target", who = tostring(who or "attacker") })
            return true
        end,
        stop_cast = function()
            if not collect then return false end
            collect.instants = collect.instants or {}
            table.insert(collect.instants, { kind = "stop_cast" })
            return true
        end,
        situation = function(key) local W = cur_W return W ~= nil and W.sit[key] == true end,
        place = function(name)
            local kind, here, id = M.where(cur_W)
            for _, k in ipairs({ "dungeon", "raid", "bg", "arena" }) do
                if entry_of(LIST_OF[k], name) then return kind == k and M.place_matches(name, k, here, id) end
            end
            return here ~= "" and norm(name) == norm(here)
        end,
        now = function() return cur_W and cur_W.now or clock() end,
        -- actions: queue the first one that can go
        cast = function(spell, who)
            if not collect or collect.action then return false end
            spell = tostring(spell or "")
            local W = cur_W
            if spell == "" or not W or not book.known(spell) or not book.ready(spell) then return false end
            local unit, tk = resolve_target(who, W)
            if not unit then return false end
            collect.action = { kind = "spell", name = spell, target = unit, target_kind = tk }
            return true
        end,
        use = function(kind)
            if not collect or collect.action then return false end
            local W = cur_W
            local hc = P.hardcore
            kind = tostring(kind or "")
            if not ITEM_KIND[kind] then
                -- Any item by its name (1.79.0): a trinket, a Free Action Potion.
                if not (hc and hc.named and hc.named_ready) then return false end
                local id, real = hc.named(kind)
                if not id or not hc.named_ready(kind) then return false end
                collect.action = { kind = "named_item", item = real, name = real }
                return true
            end
            local id, name = nil, nil
            if hc and hc.item then id, name = hc.item(kind) end
            if not id or (W and W.player[kind] == false) then return false end
            collect.action = { kind = "item", item = kind, name = name or kind }
            return true
        end,
        pet_cast = function(spell, who)
            if not collect or collect.action then return false end
            local W = cur_W
            spell = tostring(spell or "")
            if not W or not W.pet.alive or not (P.pet and P.pet.knows and P.pet.knows(spell)) then return false end
            local unit, tk = resolve_target(who or "target", W)
            collect.action = { kind = "pet_spell", name = spell, target = unit, target_kind = unit and tk or "none" }
            return true
        end,
        pet_attack = function(who)
            if not collect or collect.action then return false end
            local W = cur_W
            if not W or not W.pet.alive then return false end
            local unit = resolve_target(who or "target", W)
            if not unit then return false end
            collect.action = { kind = "pet_send", name = "Pet: attack", target = unit, target_kind = "enemy" }
            return true
        end,
        hold = function(why)
            if not collect or collect.action then return false end
            collect.action = { kind = "hold", name = "Hold", why = why and tostring(why) or nil }
            return true
        end,
    }

    -- ==========================================================================
    -- LUA: compile, sandbox, run
    -- ==========================================================================

    local raw_load, raw_loadstring, raw_setfenv = G_load, G_loadstring, G_setfenv

    local function compile(src, name, env)
        if type(raw_load) == "function" then
            local ok, fn, err = pcall(raw_load, src, name, "t", env)
            if ok then
                if fn then return fn end
                return nil, err
            end
        end
        if type(raw_loadstring) == "function" and type(raw_setfenv) == "function" then
            local fn, err = raw_loadstring(src, name)
            if not fn then return nil, err end
            raw_setfenv(fn, env)
            return fn
        end
        return nil, "this loader does not run Lua code (no load)"
    end

    local lua_ok = nil
    --- Can code run at all on this loader? Asked once.
    function M.lua_available()
        if lua_ok == nil then
            local fn = compile("return 1", "=probe", {})
            lua_ok = fn ~= nil and select(2, pcall(fn)) == 1
            if not lua_ok then
                log.once("warn", "reactions_no_lua", "Reactions: this loader cannot run Lua code; Lua rows are skipped")
            end
        end
        return lua_ok
    end

    local dbg = G_debug
    local WATCHDOG = "took too long (an endless loop?)"
    local function watchdog() error(WATCHDOG, 2) end
    local unpack_ = rawget(table, "unpack") or G_unpack
    local function pack(...) return { n = select("#", ...), ... } end

    --- The pcall user code gets: the same, except that the watchdog's stop
    --- goes through it. Otherwise "while true do pcall(loop) end" would
    --- catch the stop every 200k instructions and never end.
    local function user_pcall(f, ...)
        local res = pack(pcall(f, ...))
        if res[1] == false and type(res[2]) == "string" and res[2]:find(WATCHDOG, 1, true) then
            error(res[2], 0)
        end
        return unpack_(res, 1, res.n)
    end

    --- Runs user code: protected, and stopped after 200k instructions where
    --- the debug library allows a hook (the loader's own hook is left alone).
    local function run(fn, ...)
        local hooked = false
        if dbg and dbg.sethook and dbg.gethook and dbg.gethook() == nil then
            hooked = pcall(dbg.sethook, watchdog, "", 200000)
        end
        local ok, a, b, c = pcall(fn, ...)
        if hooked then pcall(dbg.sethook) end
        return ok, a, b, c
    end

    local function shallow(t)
        local out = {}
        for k, v in pairs(t) do out[k] = v end
        return out
    end

    local BASE_NAMES = {}
    local programs = {}         -- class -> { env, library_err, library_fns, cache }

    --- A fresh sandbox for one class: the function set, safe globals, and
    --- the Library run into it.
    local function build_program(cls, library)
        local env = {}
        for k, v in pairs(API) do env[k] = v end
        for k, v in pairs(FUNCS) do env[k] = v end
        env.math, env.string, env.table = shallow(math), shallow(string), shallow(table)
        env.pairs, env.ipairs, env.next, env.select, env.type = pairs, ipairs, next, select, type
        env.tostring, env.tonumber, env.pcall, env.error, env.assert = tostring, tonumber, user_pcall, error, assert
        env.unpack = unpack_
        env.vars = {}
        env.log = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            local text = table.concat(parts, " ")
            local now = clock()
            if (now - (log_seen[text] or -huge)) >= 1.0 then
                log_seen[text] = now
                log.fmt("info", "reaction lua (%s): %s", cls, text)
            end
        end
        env.print = env.log
        env._G = env
        for k in pairs(env) do BASE_NAMES[k] = true end

        local prog = { env = env, cache = {}, fns = {}, library_err = nil, library_line = nil }
        if type(library) == "string" and library:find("%S") then
            local fn, err = compile(library, "=Library", env)
            if not fn then
                prog.library_err = tostring(err)
            else
                local saved = cur_W
                cur_W = cur_W or latest_W()
                local ok, rerr = run(fn)
                cur_W = saved
                if not ok then prog.library_err = tostring(rerr) end
            end
            if prog.library_err then prog.library_line = tonumber(prog.library_err:match(":(%d+):")) end
        end
        for k, v in pairs(env) do
            if not BASE_NAMES[k] and type(v) == "function" then prog.fns[#prog.fns + 1] = k end
        end
        table.sort(prog.fns)
        return prog
    end

    function env_for(cls)
        cls = cls or class_key() or "?"
        local prog = programs[cls]
        if not prog then
            local b = bucket(cls ~= "?" and cls or nil)
            prog = build_program(cls, b and b.library or "")
            programs[cls] = prog
        end
        return prog
    end
    M.program = env_for

    --- Compiles a condition (an expression, or statements that return) or
    --- an action (statements, or an expression naming a spell), cached by
    --- its text.
    ---@return function|nil fn
    ---@return string|nil err
    ---@return integer|nil line
    local function compiled(code, what, label)
        local prog = env_for()
        local key = what .. "\1" .. code
        local hit = prog.cache[key]
        if hit then return hit.fn, hit.err, hit.line end
        local name = "=" .. (label or what)
        local fn, err
        if what == "cond" then
            fn = compile("return " .. code, name, prog.env)
            if not fn then fn, err = compile(code, name, prog.env) end
        else
            fn, err = compile(code, name, prog.env)
            if not fn then
                local fn2 = compile("return " .. code, name, prog.env)
                if fn2 then fn, err = fn2, nil end
            end
        end
        local line = err and tonumber(tostring(err):match(":(%d+):")) or nil
        hit = { fn = fn, err = err and tostring(err) or nil, line = line }
        prog.cache[key] = hit
        return fn, hit.err, line
    end
    M.compiled = compiled

    --- Throws away every class's sandbox: the Library changed.
    local function reset_programs()
        programs = {}
    end

    -- ==========================================================================
    -- GUI ROWS
    -- ==========================================================================

    local function op_holds(v, op, want)
        v, want = tonumber(v), tonumber(want)
        if v == nil or want == nil then return false end
        if op == "<" then return v < want end
        if op == "<=" then return v <= want end
        if op == ">" then return v > want end
        if op == ">=" then return v >= want end
        if op == "==" then return math.abs(v - want) < 1e-6 end
        return false
    end

    local function read_path(code)
        local a, b = code:match("^(%a+)%.([%w_]+)$")
        local t = a and API[a]
        if not t then return nil end
        return t[b]
    end

    local TEXT_READ = {
        me_buff = function(v) return FUNCS.buff(v) end,
        spell_ready = function(v) return FUNCS.ready(v) end,
        spell_known = function(v) return FUNCS.known(v) end,
        t_cast_name = function(v) return norm(API.target.cast_name) == norm(v) end,
        t_creature = function(v) return API.target.creature == v end,
        t_aura = function(v) return FUNCS.debuff(v) end,
        t_my_aura = function(v) return FUNCS.debuff(v, true) end,
        f_mode = function(v) return API.fight.mode == v end,
        f_threat = function(v) return API.fight.threat == v end,
        f_tactic = function(v) return API.fight.tactic == v end,
        f_advice = function(v) return API.fight.advice == v end,
        t_cd_seen = function(v) return FUNCS.enemy_cd_seen(v) end,
        t_cc_value = function(v) return API.target.cc_value == v end,
        t_dr_next = function(v) return API.target.dr_next == v end,
        t_pattern = function(v) return API.target.pattern == v end,
        t_kill_verdict = function(v) return API.target.kill_verdict == v end,
        f_bait = function(v) return API.fight.bait == v end,
        f_situation = function(v) return FUNCS.situation(v) end,
        w_kind = function(v) return API.where.kind == v end,
        w_name = function(v) return FUNCS.place(v) end,
        lua_fn = function(v)
            local fn = env_for().env[v]
            if type(fn) ~= "function" then error("no function " .. tostring(v) .. " in the Library", 0) end
            local ok, r = run(fn)
            if not ok then error(r, 0) end
            return r and true or false
        end,
        t_name = function(v) return norm(API.target.name) == norm(v) end,
        me_has_item = function(v) return FUNCS.has_item(v) end,
    }

    --- A name and a number (1.79.0): what the name reads as, compared with
    --- the row's `num`.
    local TEXT_NUM_READ = {
        me_buff_left = function(v) return FUNCS.buff_left(v) end,
        me_buff_stacks = function(v) return FUNCS.buff_stacks(v) end,
        spell_cd = function(v) return FUNCS.cooldown(v) end,
        t_debuff_left = function(v) return FUNCS.debuff_left(v, true) end,
        t_debuff_stacks = function(v) return FUNCS.debuff_stacks(v) end,
        t_cd_ready_in = function(v) return FUNCS.enemy_cd_ready_in(v) end,
    }

    local function show_value(def, v)
        if type(v) == "boolean" then return v and "yes" or "no" end
        if type(v) == "number" then
            if v >= 999 then return "never" end
            local s = (math.abs(v - floor(v)) < 0.05) and tostring(floor(v + 0.5)) or string.format("%.1f", v)
            return s .. (def and def.suffix or "")
        end
        return tostring(v)
    end

    --- A GUI condition against the picture: holds?, what it read (for the
    --- window), and why it could not be read.
    ---@return boolean ok
    ---@return string|nil shown
    ---@return string|nil err
    function eval_gui(cond, W)
        local def = D.CONDITION_BY_KEY[cond.key or ""]
        if not def then return false, nil, "unknown condition " .. tostring(cond.key) end
        if def.group == "Target" and def.key ~= "t_exists" and not W.target.unit then return false, "no target" end
        if def.group == "Pet" and def.key ~= "pet_exists" and not W.pet.alive then return false, "no pet" end
        local saved = cur_W
        cur_W = W
        local ok, v = pcall(function()
            if def.type == "number" or def.type == "bool" then return read_path(def.code) end
            if def.type == "key" then
                if (tonumber(cond.value) or 0) <= 0 then error("no key picked", 0) end
                return key_held(cond.value, W)
            end
            local value = cond.value
            if value == nil or value == "" then error("nothing picked", 0) end
            if def.type == "text_number" then return TEXT_NUM_READ[def.key](value) end
            return TEXT_READ[def.key](value)
        end)
        cur_W = saved
        if not ok then return false, nil, tostring(v) end
        local holds
        if def.type == "number" then
            local want = tonumber(cond.value)
            if want == nil then want = def.default end
            holds = op_holds(v, cond.op or def.op or "<", want)
        elseif def.type == "text_number" then
            local want = tonumber(cond.num)
            if want == nil then want = def.default_num end
            holds = op_holds(v, cond.op or def.op or "<", want)
        else
            holds = (v and true or false) == (cond.op ~= "not")
        end
        return holds, show_value(def, v), nil
    end
    M.eval_gui = eval_gui

    local OP_CODE = {}
    for _, o in ipairs(D.OPS.number) do OP_CODE[o.key] = o.code end

    local function num(v)
        v = tonumber(v) or 0
        if math.abs(v - floor(v)) < 1e-9 then return tostring(floor(v)) end
        return string.format("%.2f", v):gsub("0+$", "")
    end

    --- The Lua a GUI condition stands for: "me.hp < 40", 'not buff("Prowl")'.
    function M.cond_code(cond)
        if cond.mode == "lua" then return cond.code or "" end
        local def = D.CONDITION_BY_KEY[cond.key or ""]
        if not def then return "false -- unknown condition" end
        if def.type == "number" then
            local want = cond.value
            if want == nil then want = def.default end
            return string.format("%s %s %s", def.code, OP_CODE[cond.op or def.op or "<"] or "<", num(want))
        end
        if def.type == "text_number" then
            local want = cond.num
            if want == nil then want = def.default_num end
            return string.format("%s %s %s", def.code:format(tostring(cond.value or "")),
                OP_CODE[cond.op or def.op or "<"] or "<", num(want))
        end
        if def.type == "key" then
            local expr = string.format("key(0x%02X)", math.floor(tonumber(cond.value) or 0))
            return cond.op == "not" and ("not " .. expr) or expr
        end
        local expr = def.code
        if def.type ~= "bool" then
            local v = cond.value
            if v == nil then v = def.default end
            expr = def.code:format(tostring(v or ""))
        end
        if cond.op == "not" then
            if expr:find("[ =]") then return "not (" .. expr .. ")" end
            return "not " .. expr
        end
        return expr
    end

    --- The Lua a GUI action stands for.
    function M.action_code(a)
        if a.mode == "lua" then return a.code or "" end
        local t = a.target and a.target ~= "target" and string.format(", %q", a.target) or ""
        if a.kind == "spell" then return string.format("cast(%q%s)", a.spell or "", t) end
        if a.kind == "item" then return string.format("use(%q)", a.item or "healthstone") end
        if a.kind == "pet_spell" then return string.format("pet_cast(%q%s)", a.spell or "", t) end
        if a.kind == "pet_attack" then return string.format("pet_attack(%q)", a.target or "target") end
        if a.kind == "lua_fn" then return tostring(a.fn or "my_function") .. "()" end
        if a.kind == "hold" then return "hold()" end
        if a.kind == "named_item" then return string.format("use(%q)", a.name or "") end
        if a.kind == "alert" then
            return string.format("alert(%q, %q%s)", a.text or "", a.color or "red", a.sound == false and ", false" or "")
        end
        if a.kind == "target" then return string.format("set_target(%q)", a.who or "attacker") end
        if a.kind == "stop_cast" then return "stop_cast()" end
        return "-- ?"
    end

    --- The whole reaction as one Lua function: what it does, in code.
    function M.reaction_code(r)
        local lines = { string.format("-- %s", r.name or "?") }
        local parts = {}
        for i, c in ipairs(r.conds or {}) do
            local code = M.cond_code(c)
            if c.mode == "lua" then
                -- An expression stands for its value (custom.lua compiles
                -- it with a return in front); statements return their own.
                if not code:find("%f[%w_]return%f[^%w_]") then code = "return " .. code end
                lines[#lines + 1] = string.format("local function condition%d()", i)
                for l in (code .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = "    " .. l end
                lines[#lines + 1] = "end"
                code = string.format("condition%d()", i)
            end
            if (tonumber(c.for_s) or 0) > 0 then
                code = code .. string.format("  --[[ for at least %ss ]]", num(c.for_s))
            end
            parts[#parts + 1] = code
        end
        if (tonumber(r.per_fight) or 0) > 0 then
            lines[#lines + 1] = string.format("-- at most %d time%s a fight", r.per_fight, r.per_fight == 1 and "" or "s")
        end
        local joiner = r.match == "any" and "\n    or " or "\n    and "
        lines[#lines + 1] = "if " .. (#parts > 0 and table.concat(parts, joiner) or "true") .. " then"
        local lane_seen = false
        for _, a in ipairs(r.actions or {}) do
            local code = M.action_code(a)
            local kd = a.mode ~= "lua" and D.ACTION_KIND_BY_KEY[a.kind or "spell"] or nil
            if kd and kd.instant then
                lines[#lines + 1] = "    -- at once, whatever else goes:"
            elseif lane_seen then
                lines[#lines + 1] = "    -- else, if that could not go:"
            else
                lane_seen = true
            end
            for l in (code .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = "    " .. l end
        end
        lines[#lines + 1] = "end"
        return table.concat(lines, "\n")
    end

    --- A condition in words, for "why not": "My health % below 40%".
    function M.cond_text(c)
        if c.mode == "lua" then return "the Lua condition" end
        local def = D.CONDITION_BY_KEY[c.key or ""]
        if not def then return "an unknown condition" end
        local oplabel = ""
        for _, o in ipairs(D.OPS[def.type] or {}) do if o.key == c.op then oplabel = o.label end end
        local s
        if def.type == "number" then
            s = string.format("%s %s %s%s", def.label, oplabel, num(c.value == nil and def.default or c.value), def.suffix or "")
        elseif def.type == "text_number" then
            s = string.format("%s %s %s %s%s", def.label, tostring(c.value or "?"), oplabel,
                num(c.num == nil and def.default_num or c.num), def.suffix or "")
        elseif def.type == "key" then
            s = string.format("key 0x%02X %s", math.floor(tonumber(c.value) or 0), c.op == "not" and "not held" or "held")
        elseif def.type == "bool" then
            s = (c.op == "not" and "not: " or "") .. def.label
        else
            s = string.format("%s%s %s", c.op == "not" and "not: " or "", def.label, tostring(c.value or ""))
        end
        if (tonumber(c.for_s) or 0) > 0 then s = s .. string.format(" (for %ss)", num(c.for_s)) end
        return s
    end

    -- ==========================================================================
    -- REACTIONS INTO ENGINE RULES
    -- ==========================================================================

    local runtime = {}          -- reaction id -> live state, for the window
    local added = {}            -- engine rule names we added
    local active_class = nil
    local active_bucket = nil

    --- A reaction's live state. Besides the lights: `since` (when each
    --- condition began to hold), `instants` (when each alert or target switch
    --- last went), `fight_n` / `total_n` (fires this fight and this session),
    --- `history` (the latest fires, newest first) and `outcome` (what the
    --- engine made of it on its latest tick).
    local function rt_of(id)
        local rt = runtime[id]
        if not rt then
            rt = { conds = {}, actions = {}, errors = 0, since = {}, instants = {}, fight_n = 0, total_n = 0,
                   history = {} }
            runtime[id] = rt
        end
        return rt
    end
    M.runtime = function(id) return runtime[id] end
    M.runtime_of = rt_of

    -- Always on since 2026-10-11 (the user: "reactions should automatically
    -- activate in PvP when PvP is detected", not an option; the Reactions
    -- page's switch is gone and a saved react_active changes nothing).
    local function master_on()
        return true
    end
    M.master_on = master_on

    --- Every condition of a reaction (all, or any), each one's reading kept.
    local function conditions_pass(r, W, rt, label)
        local conds = r.conds or {}
        if #conds == 0 then return true end
        local any = r.match == "any"
        local result = not any
        for i, c in ipairs(conds) do
            local ok, shown, err
            if c.mode == "lua" then
                local fn, cerr = compiled(c.code or "", "cond", label .. " / condition " .. i)
                if not fn then
                    ok, err = false, cerr
                else
                    local saved = cur_W
                    cur_W = W
                    local good, v = run(fn)
                    cur_W = saved
                    if good then ok, shown = v and true or false, v == nil and "nil" or tostring(v)
                    else ok, err = false, tostring(v) end
                end
            else
                ok, shown, err = eval_gui(c, W)
            end
            -- MUST HOLD FOR A WHILE (1.79.0), counted from when it began to.
            -- A gap of more than half a second between asks starts it over.
            local need = tonumber(c.for_s) or 0
            local waiting = nil
            rt.since = rt.since or {}
            if need > 0 and ok then
                if W.bench then
                    shown = string.format("%s, once it has held %gs", shown or "?", need)
                else
                    local s = rt.since[c.uid]
                    if not s or (W.now - s.seen) > 0.5 then s = { at = W.now }; rt.since[c.uid] = s end
                    s.seen = W.now
                    local held = W.now - s.at
                    if held < need then
                        ok = false
                        waiting = need - held
                        shown = string.format("%s, for %.1fs of %gs", shown or "?", held, need)
                    end
                end
            elseif rt.since[c.uid] then
                rt.since[c.uid] = nil
            end
            local slot = rt.conds[c.uid] or {}
            slot.ok, slot.shown, slot.err, slot.at, slot.waiting = ok, shown, err, W.now, waiting
            rt.conds[c.uid] = slot
            if err then rt.errors = rt.errors + 1; rt.last_err = err end
            if any and ok then result = true end
            if not any and not ok then result = false end
        end
        return result
    end
    M.conditions_pass = conditions_pass

    local SWITCH_LABEL = {}
    for _, t in ipairs(D.SWITCH_TARGETS) do SWITCH_LABEL[t.key] = t.label:lower() end

    --- An instant action row (1.79.0): what it would do now, or nil and why.
    local function instant_spec(a, W)
        local kind = a.kind
        if kind == "alert" then
            local text = tostring(a.text or "")
            if not text:find("%S") then return nil, "no text to show" end
            return { instant = true, kind = "alert", text = text, color = a.color, sound = a.sound ~= false,
                     name = "Alert: " .. text }
        elseif kind == "target" then
            local who = a.who or "attacker"
            local unit = resolve_target(who, W)
            if not unit then return nil, "no " .. (SWITCH_LABEL[who] or who) end
            if unit == W.target.unit then return nil, "already your target" end
            return { instant = true, kind = "target", unit = unit, who = who, name = "Target: " .. (SWITCH_LABEL[who] or who) }
        elseif kind == "stop_cast" then
            if not W.player.busy then return nil, "you are not casting" end
            return { instant = true, kind = "stop_cast", name = "Stop casting" }
        end
        return nil, "unknown action " .. tostring(kind)
    end

    --- What Lua queued with alert(), set_target() or stop_cast(), as specs.
    local function lua_instants(list, W)
        if not list then return nil end
        local out = {}
        for _, q in ipairs(list) do
            local spec = instant_spec({ kind = q.kind, text = q.text, color = q.color, sound = q.sound, who = q.who }, W)
            if spec then out[#out + 1] = spec end
        end
        return out
    end

    --- What one action row would send now, or nil and why not. A fourth
    --- result: the instant actions its Lua queued on the way.
    local function action_spec(r, a, W, label)
        if a.mode == "lua" then
            local fn, err = compiled(a.code or "", "act", label)
            if not fn then return nil, err end
            local saved_W, saved_c = cur_W, collect
            cur_W, collect = W, {}
            local good, v1, v2 = run(fn)
            local got, queued = collect.action, collect.instants
            cur_W, collect = saved_W, saved_c
            if not good then return nil, tostring(v1), true end
            if not got and type(v1) == "string" and v1 ~= "" then
                if book.known(v1) and book.ready(v1) then
                    local unit, tk = resolve_target(v2, W)
                    if unit then got = { kind = "spell", name = v1, target = unit, target_kind = tk } end
                end
            end
            local inst = lua_instants(queued, W)
            if not got then
                return nil, (inst and #inst > 0) and "only instant actions" or "the code queued nothing", nil, inst
            end
            return got, nil, nil, inst
        end
        local kd = D.ACTION_KIND_BY_KEY[a.kind or "spell"]
        if kd and kd.instant then return instant_spec(a, W) end
        local kind = a.kind or "spell"
        if kind == "spell" then
            local name = a.spell or ""
            if name == "" then return nil, "no spell picked" end
            if not book.known(name) then return nil, name .. " is not learned" end
            if not book.ready(name) then return nil, name .. " is not ready" end
            local unit, tk = resolve_target(a.target, W)
            if not unit then return nil, "no " .. tostring(a.target or "target") end
            return { kind = "spell", name = name, target = unit, target_kind = tk }
        elseif kind == "item" then
            local hc = P.hardcore
            local id, name = nil, nil
            if hc and hc.item then id, name = hc.item(a.item or "healthstone") end
            if not id then return nil, "none in the bags" end
            if W.player[a.item or ""] == false then return nil, "not ready (cooldown)" end
            return { kind = "item", item = a.item, name = name or a.item }
        elseif kind == "named_item" then
            local name = tostring(a.name or "")
            if not name:find("%S") then return nil, "no item picked" end
            if W.bench then
                if type(W.bench.items) == "table" and W.bench.items[name:lower()] then
                    return { kind = "named_item", item = name, name = name }
                end
                return nil, name .. " is not carried (in this test)"
            end
            local hc = P.hardcore
            if not (hc and hc.named and hc.named_ready) then return nil, "items by name need the Hardcore module" end
            local id, real = hc.named(name)
            if not id then return nil, name .. " is not carried" end
            local ready, why = hc.named_ready(name)
            if not ready then return nil, real .. ": " .. tostring(why or "not usable") end
            return { kind = "named_item", item = real, name = real }
        elseif kind == "pet_spell" then
            local name = a.spell or ""
            if not W.pet.alive then return nil, "no pet" end
            if name == "" then return nil, "no pet ability picked" end
            if not (P.pet and P.pet.knows and P.pet.knows(name)) then return nil, "the pet does not know " .. name end
            local unit, tk = resolve_target(a.target or "target", W)
            return { kind = "pet_spell", name = name, target = unit, target_kind = unit and tk or "none" }
        elseif kind == "pet_attack" then
            if not W.pet.alive then return nil, "no pet" end
            local unit = resolve_target(a.target or "target", W)
            if not unit then return nil, "no " .. tostring(a.target or "target") end
            return { kind = "pet_send", name = "Pet: attack", target = unit, target_kind = "enemy" }
        elseif kind == "lua_fn" then
            local fn = env_for().env[a.fn or ""]
            if type(fn) ~= "function" then return nil, "no function " .. tostring(a.fn) .. " in the Library" end
            local saved_W, saved_c = cur_W, collect
            cur_W, collect = W, {}
            local good, v = run(fn)
            local got, queued = collect.action, collect.instants
            cur_W, collect = saved_W, saved_c
            if not good then return nil, tostring(v), true end
            local inst = lua_instants(queued, W)
            if not got then return nil, (a.fn or "?") .. "() queued nothing", nil, inst end
            return got, nil, nil, inst
        elseif kind == "hold" then
            return { kind = "hold", name = "Hold: " .. (r.name or "?"), why = r.name }
        end
        return nil, "unknown action " .. tostring(kind)
    end

    local function rule_name_of(r, taken)
        local base = "My: " .. ((r.name and r.name:find("%S")) and r.name or ("reaction " .. tostring(r.id)))
        if taken[base] then base = base .. " #" .. tostring(r.id) end
        taken[base] = true
        return base
    end

    -- ==========================================================================
    -- ALERTS, HISTORY, LIMITS (1.79.0)
    -- ==========================================================================

    local ALERT_SOUND = 8959    -- the raid warning, as the ESP's alerts use it
    local alerts = {}           -- on screen, newest first: { text, rgb, at, till }
    M.alerts = alerts

    local function play_sound()
        if type(core.play_sound_by_id) == "function" then pcall(core.play_sound_by_id, ALERT_SOUND) end
    end
    M.play_sound = play_sound

    --- A line at the top of the screen for a few seconds, and the sound.
    local function push_alert(text, color, sound)
        local c = D.ALERT_COLOR_BY_KEY[color or ""] or D.ALERT_COLOR_BY_KEY.red
        local now = clock()
        for i = #alerts, 1, -1 do if alerts[i].text == text then table.remove(alerts, i) end end
        table.insert(alerts, 1, { text = text, rgb = c.rgb, at = now, till = now + 3.5 })
        while #alerts > 4 do table.remove(alerts) end
        if sound then play_sound() end
        log.fmt("info", "reactions: alert: %s", text)
    end
    M.push_alert = push_alert

    local color_cache = {}
    --- One frame of the alerts (main.lua's render job).
    function M.render_alerts()
        if #alerts == 0 then return end
        local now = clock()
        for i = #alerts, 1, -1 do if alerts[i].till <= now then table.remove(alerts, i) end end
        local draw = P.draw
        if #alerts == 0 or not (draw and draw.text_bg and P.color) then return end
        local ok, w, h = pcall(draw.screen_size)
        if not ok or type(w) ~= "number" or w <= 0 then w, h = 1920, 1080 end
        for i, a in ipairs(alerts) do
            local left = a.till - now
            local alpha = left < 0.6 and math.max(0, math.floor(255 * left / 0.6)) or 255
            local key = a.rgb[1] .. "," .. a.rgb[2] .. "," .. a.rgb[3] .. "," .. alpha
            local col = color_cache[key]
            if not col then
                col = P.color(a.rgb[1], a.rgb[2], a.rgb[3], alpha)
                color_cache[key] = col
            end
            pcall(draw.text_bg, { x = w * 0.5, y = h * 0.26 + (i - 1) * 34 }, a.text, col,
                { size = i == 1 and 26 or 20, centered = true, layer = draw.LAYER and draw.LAYER.HUD })
        end
    end

    local HISTORY_MAX = 15

    local function unit_label(u, W)
        if not u then return nil end
        if W.bench then return u.label end
        if u == W.player.unit then return "you" end
        if u == W.pet.unit then return "your pet" end
        return (units.name and try(units.name, u)) or nil
    end

    --- A fire, kept: the count this fight and this session, and a line in
    --- the history with what its conditions read at the time.
    local function record_fire(r, rt, W, what, target)
        rt.fight_n = (rt.fight_n or 0) + 1
        rt.total_n = (rt.total_n or 0) + 1
        rt.last_fire = W.now
        local reads = {}
        for i, c in ipairs(r.conds or {}) do
            local slot = rt.conds[c.uid]
            if slot and slot.shown then reads[#reads + 1] = string.format("%d: %s", i, tostring(slot.shown)) end
        end
        table.insert(rt.history, 1, {
            at = W.now, what = what, on = unit_label(target, W), hp = math.floor(pct(W.player.hp) + 0.5),
            where = M.where_text(), reads = table.concat(reads, ", "),
        })
        while #rt.history > HISTORY_MAX do table.remove(rt.history) end
    end

    --- The latest fires of a reaction, newest first.
    function M.history(id)
        local rt = runtime[id]
        return rt and rt.history or {}
    end

    -- Instant actions go at most this often while their conditions keep
    -- holding (the reaction's own wait, when longer); again at once after
    -- the conditions stopped holding for half a second.
    local INSTANT_EVERY = { alert = 6, target = 1.5, stop_cast = 1 }

    local function do_instant(r, rt, W, spec, key)
        local st = rt.instants[key]
        local gap = math.max(tonumber(r.wait) or 0, INSTANT_EVERY[spec.kind] or 2)
        if st then
            local fresh = (W.now - st.seen) > 0.5
            if (W.now - st.at) < (fresh and 1.0 or gap) then st.seen = W.now return false end
        else
            st = {}
            rt.instants[key] = st
        end
        st.at, st.seen = W.now, W.now
        local done = false
        if spec.kind == "alert" then
            push_alert(spec.text, spec.color, spec.sound)
            done = true
        elseif spec.kind == "target" then
            local inp = ctx and ctx.input
            if inp and inp.set_target then done = try(inp.set_target, ctx.id or "jambix.aio", spec.unit) ~= false end
        elseif spec.kind == "stop_cast" then
            local inp = ctx and ctx.input
            if inp and inp.cancel_spells then try(inp.cancel_spells); done = true end
        end
        if done then
            record_fire(r, rt, W, spec.name, spec.unit)
            local def = M.rule_of(r.id)
            if def then def.fired_n, def.fired_at, def.fired_name = (def.fired_n or 0) + 1, W.now, spec.name end
        end
        return done
    end

    --- Has it used up its fires for this fight?
    local function over_limit(r)
        local limit = tonumber(r.per_fight) or 0
        if limit <= 0 then return false end
        local rt = runtime[r.id]
        return rt ~= nil and (rt.fight_n or 0) >= limit
    end

    local function make_rule(r, name)
        local imp = D.IMPORTANCE_BY_KEY[r.importance] or D.IMPORTANCE_BY_KEY.defensive
        local label = r.name or name
        local def = {
            name = name, custom = r.id, reaction = r,
            category = imp.category, priority = tonumber(r.priority) or imp.priority,
            lane = r.off_gcd and "fast" or "gcd",
            needs = r.combat_only and { "combat" } or nil,
            retry = { hold = math.max(0, tonumber(r.wait) or 0) },
            offensive = imp.offensive or nil,
            enabled = function(W)
                return master_on() and r.on ~= false and env_ok(r.env, W) and not over_limit(r)
            end,
        }
        def.propose = function(W, offer)
            local rt = rt_of(r.id)
            rt.asked_at = W.now
            local pass = conditions_pass(r, W, rt, label)
            rt.pass = pass
            if not pass then
                rt.note = nil
                return
            end
            -- Instant actions go at once, wherever they are in the list; the
            -- first spell, item or pet order that can go is offered.
            local why_not, chosen = {}, nil
            for i, a in ipairs(r.actions or {}) do
                local kd = a.mode ~= "lua" and D.ACTION_KIND_BY_KEY[a.kind or "spell"] or nil
                local slot = rt.actions[a.uid] or {}
                rt.actions[a.uid] = slot
                if chosen and not (kd and kd.instant) and a.mode ~= "lua" then
                    slot.note, slot.at, slot.err = "not needed: " .. chosen.name .. " comes first", W.now, nil
                else
                    local spec, why, raised, extra = action_spec(r, a, W, label .. " / action " .. i)
                    if raised then rt.errors = rt.errors + 1; rt.last_err = why end
                    for _, x in ipairs(extra or {}) do do_instant(r, rt, W, x, a.uid .. ":" .. x.kind .. ":" .. (x.text or x.who or "")) end
                    if spec and spec.instant then
                        do_instant(r, rt, W, spec, a.uid .. ":" .. spec.kind)
                        slot.note = "goes at once: " .. spec.name
                    elseif spec and not chosen then
                        chosen = spec
                        slot.note = "would send " .. spec.name
                    elseif spec then
                        slot.note = "not needed: " .. chosen.name .. " comes first"
                    else
                        slot.note = why
                        why_not[#why_not + 1] = tostring(why)
                    end
                    slot.at, slot.err = W.now, raised and why or nil
                end
            end
            if chosen then
                local item_like = chosen.kind == "item" or chosen.kind == "named_item"
                offer({
                    name = chosen.name, kind = chosen.kind, target = chosen.target,
                    target_kind = chosen.target_kind or (item_like and "self") or nil,
                    item = chosen.item, why = chosen.why or r.name,
                    lane = item_like and "fast" or nil,
                })
                rt.note = "offered " .. chosen.name
                return
            end
            rt.note = #why_not > 0 and ("nothing could go: " .. table.concat(why_not, "; ")) or nil
        end
        def.on_execute = function(W, c)
            local rt = rt_of(r.id)
            record_fire(r, rt, W, c.name, c.target)
            if r.notify_alert then
                push_alert(string.format("%s: %s", r.name or "Reaction", c.name), r.notify_color or "yellow", r.notify_sound)
            elseif r.notify_sound then
                play_sound()
            end
        end
        return def
    end

    --- Once a tick, after the engine decided (react/init.lua): the fight's
    --- clock, the per-fight counts, and what became of each of yours.
    function M.after_decide(W, d)
        local inc = W.player and W.player.in_combat == true
        if inc ~= (combat_since ~= nil) then
            combat_since = inc and W.now or nil
            -- A new fight, or the end of one: the counts start over. What
            -- went out on this very tick (the fight's opening move) counts
            -- for the fight it opened.
            for _, rt in pairs(runtime) do
                if not (inc and rt.last_fire and rt.last_fire >= W.now) then rt.fight_n = 0 end
            end
        end
        if not d or not d.cands then return end
        for _, c in ipairs(d.cands) do
            local id = c.rule and c.rule.custom
            if id then
                local rt = rt_of(id)
                local w = c.lane and d[c.lane] or nil
                rt.outcome = {
                    at = W.now, state = c.state, name = c.name, score = c.score, rejected = c.rejected,
                    winner = (w and w ~= c) and w.rule.name .. ": " .. w.name or nil, winner_score = w and w.score or nil,
                }
            end
        end
    end

    --- Puts the class's reactions into the engine, replacing what was there.
    local function rebuild()
        for name in pairs(added) do engine.remove_rule(name) end
        added = {}
        local b = active_bucket
        if not b then return end
        local taken = {}
        for _, r in ipairs(b.custom) do
            local name = rule_name_of(r, taken)
            local ok, err = pcall(engine.add_rule, make_rule(r, name))
            if ok then added[name] = true
            else lib.journal("error", string.format("your reaction %s could not be added: %s", tostring(r.name), tostring(err))) end
        end
    end
    M.rebuild = rebuild

    --- Once a tick (react/init.lua): the class's reactions in the engine.
    function M.sync()
        local cls = class_key()
        if cls == active_class then return end
        active_class = cls
        active_bucket = cls and bucket(cls) or nil
        rebuild()
        if cls then
            local n = active_bucket and #active_bucket.custom or 0
            log.fmt("info", "reactions: %d of your own for %s", n, cls)
        end
    end

    -- ==========================================================================
    -- THE BUILT-IN REACTIONS: where each acts (1.78.0)
    -- ==========================================================================
    --
    -- Everywhere, unless the plugin's own choice says otherwise (custom_data's
    -- DEFAULT_PLACES: a few pet reactions stay out of dungeons and raids), or
    -- yours does. Yours is kept per class as defaults[name] = { off, env },
    -- and only where it differs from the plugin's, so a reset just drops it.
    -- `off` is nowhere at all (the 1.76.0 switch), whatever env says.

    local EVERYWHERE = fresh_env()
    local NOWHERE = fresh_env()
    for _, k in ipairs(ENV_KEYS) do NOWHERE[k] = false end

    local SHIPPED = {}          -- name -> env, built once (the engine asks every tick)
    for name, s in pairs(D.DEFAULT_PLACES or {}) do
        local env = fresh_env()
        for k, v in pairs(s.env or {}) do env[k] = v end
        SHIPPED[name] = env
    end

    --- Do two environments let a reaction act in the same places? nil is
    --- everywhere.
    local function same_env(a, b)
        a, b = a or EVERYWHERE, b or EVERYWHERE
        for _, k in ipairs(ENV_KEYS) do
            if (a[k] ~= false) ~= (b[k] ~= false) then return false end
        end
        for kind, pk in pairs(PICK_OF) do
            if a[kind] ~= false and (a[pk] or "Any") ~= (b[pk] or "Any") then return false end
        end
        return true
    end
    M.same_env = same_env

    --- Where a built-in reaction acts: yours, else the plugin's, else
    --- everywhere (nil). Not to be changed: the window edits a copy.
    local function placed(name, d)
        if type(d) == "table" then
            if d.off then return NOWHERE end
            if type(d.env) == "table" then return d.env end
        end
        return SHIPPED[name]
    end

    -- The built-in reactions' switches, asked by the engine for every rule.
    engine.filter = function(def, W)
        if def.custom then return true end
        if not master_on() then return D.OWN_SWITCH[def.name] ~= nil end
        local b = active_bucket
        local env = placed(def.name, b and b.defaults[def.name])
        if env == NOWHERE then return false end
        if env and not env_ok(env, W) then return false end
        return true
    end

    -- ==========================================================================
    -- WHAT THE WINDOW ASKS AND CHANGES
    -- ==========================================================================

    --- The built-in reactions, in the engine's order, for the window: the
    --- ones this class can have (a hunter has no succubus to seduce with).
    --- `env` is where each acts (nil: everywhere); `world` and `dungeon` are
    --- the window's two columns; `here` is where you stand now.
    function M.defaults()
        local out = {}
        local b = active_bucket
        local cls = active_class
        for _, def in ipairs(engine.rules()) do
            local only = D.DEFAULT_CLASS[def.name]
            local pet_rule = def.category == "pet" or def.name:find("^Pet:") ~= nil
            local fits = (only == nil or only == cls) and (not pet_rule or D.PET_CLASSES[cls or ""] == true)
            if not def.custom and fits then
                local d = b and b.defaults[def.name] or nil
                local env = placed(def.name, d)
                local shipped = D.DEFAULT_PLACES and D.DEFAULT_PLACES[def.name]
                out[#out + 1] = {
                    name = def.name, category = def.category, priority = def.priority,
                    info = D.DEFAULT_INFO[def.name], own = D.OWN_SWITCH[def.name],
                    on = env ~= NOWHERE, env = env,
                    world = env == nil or env.world ~= false, dungeon = env == nil or env.dungeon ~= false,
                    here = env ~= NOWHERE and (env == nil or env_ok(env)),
                    mine = type(d) == "table", shipped_why = shipped and shipped.why or nil,
                    shipped_env = SHIPPED[def.name],
                    fired_n = def.fired_n or 0, fired_at = def.fired_at,
                }
            end
        end
        return out
    end

    local function save_bucket()
        touch()
    end

    --- Keeps where a built-in reaction acts: nothing when it is the
    --- plugin's own choice, `off` when it is nowhere.
    local function keep_places(b, name, env)
        local d = type(b.defaults[name]) == "table" and b.defaults[name] or {}
        d.off, d.env = nil, nil
        if not same_env(env, SHIPPED[name]) then
            if same_env(env, NOWHERE) then d.off = true else d.env = copy(env) end
        end
        b.defaults[name] = next(d) and d or nil
        save_bucket()
    end

    --- Switched off is nowhere; switched back on is where it was before.
    function M.set_default_on(name, on)
        local b = active_bucket
        if not b then return end
        local d = type(b.defaults[name]) == "table" and b.defaults[name] or {}
        d.off = (not on) or nil
        b.defaults[name] = next(d) and d or nil
        save_bucket()
    end

    --- Replaces where a built-in reaction acts (switched off included).
    --- nil puts it back to the plugin's own choice.
    function M.set_default_env(name, env)
        local b = active_bucket
        if not b then return end
        keep_places(b, name, env or SHIPPED[name] or EVERYWHERE)
    end

    --- One of the window's columns: a built-in reaction on or off in the
    --- open world ("world") or in dungeons ("dungeon"), the rest of where it
    --- acts kept. Switched off everywhere, it comes on in that place alone.
    function M.set_default_place(name, key, on)
        local b = active_bucket
        if not b then return end
        local env = copy(placed(name, b.defaults[name]) or EVERYWHERE)
        env[key] = on and true or false
        keep_places(b, name, env)
    end

    --- Puts the built-in reactions back to the plugin's own choice: in one
    --- place (a column's key), or everywhere (nil). Returns how many changed.
    ---@param key? string
    ---@return integer
    function M.reset_defaults(key)
        local b = active_bucket
        if not b then return 0 end
        local names = {}
        for name in pairs(b.defaults) do names[#names + 1] = name end
        local n = 0
        for _, name in ipairs(names) do
            local before = placed(name, b.defaults[name])
            if key == nil then
                b.defaults[name] = nil
            else
                local env = copy(before or EVERYWHERE)
                local base = SHIPPED[name] or EVERYWHERE
                env[key] = base[key]
                if PICK_OF[key] then env[PICK_OF[key]] = base[PICK_OF[key]] end
                keep_places(b, name, env)
            end
            if not same_env(before, placed(name, b.defaults[name])) then n = n + 1 end
        end
        save_bucket()
        return n
    end

    function M.list()
        return active_bucket and active_bucket.custom or {}
    end

    function M.get(id)
        for i, r in ipairs(M.list()) do
            if r.id == id then return r, i end
        end
        return nil
    end

    --- The engine's rule for a reaction (its fired count lives there).
    function M.rule_of(id)
        for _, def in ipairs(engine.rules()) do
            if def.custom == id then return def end
        end
        return nil
    end

    --- A new reaction from a template, not saved yet.
    function M.from_template(i)
        local t = D.TEMPLATES[i] or D.TEMPLATES[1]
        local r = copy(t.reaction)
        r.id = nil
        r.env = fresh_env()
        normalise(r, 0)
        r.id = nil
        return r
    end

    --- A working copy of a saved reaction.
    function M.draft_of(id)
        local r = M.get(id)
        return r and copy(r) or nil
    end

    function M.new_uid(r)
        r.next_uid = (tonumber(r.next_uid) or 1)
        local uid = r.next_uid
        r.next_uid = uid + 1
        return uid
    end

    --- What stops a draft from doing anything, as lines for the window.
    function M.problems(r)
        local out = {}
        if #(r.actions or {}) == 0 then out[#out + 1] = "It has no action: add one under Do this." end
        for i, a in ipairs(r.actions or {}) do
            if a.mode == "lua" then
                local _, err = compiled(a.code or "", "act", (r.name or "?") .. " / action " .. i)
                if err then out[#out + 1] = "Action " .. i .. ": " .. err end
            elseif (a.kind == "spell" or a.kind == "pet_spell") and (a.spell or "") == "" then
                out[#out + 1] = "Action " .. i .. ": pick a spell."
            elseif a.kind == "spell" and not book.known(a.spell) then
                out[#out + 1] = "Action " .. i .. ": " .. a.spell .. " is not in your spellbook."
            elseif a.kind == "named_item" and not tostring(a.name or ""):find("%S") then
                out[#out + 1] = "Action " .. i .. ": pick an item."
            elseif a.kind == "alert" and not tostring(a.text or ""):find("%S") then
                out[#out + 1] = "Action " .. i .. ": the alert has no text."
            end
        end
        for i, c in ipairs(r.conds or {}) do
            if c.mode == "lua" then
                local _, err = compiled(c.code or "", "cond", (r.name or "?") .. " / condition " .. i)
                if err then out[#out + 1] = "Condition " .. i .. ": " .. err end
            else
                local def = D.CONDITION_BY_KEY[c.key or ""]
                if def and (def.type == "text" or def.type == "choice" or def.type == "text_number")
                    and (c.value == nil or c.value == "") then
                    out[#out + 1] = "Condition " .. i .. ": pick a " .. ((def.pick == "spell" and "spell")
                        or (def.pick == "item" and "item") or (def.pick == "name" and "name") or "value") .. "."
                elseif def and def.type == "key" and (tonumber(c.value) or 0) <= 0 then
                    out[#out + 1] = "Condition " .. i .. ": pick the key it waits for."
                end
            end
        end
        local instant_only = #(r.actions or {}) > 0
        for _, a in ipairs(r.actions or {}) do
            local kd = a.mode ~= "lua" and D.ACTION_KIND_BY_KEY[a.kind or "spell"] or nil
            if not (kd and kd.instant) then instant_only = false end
        end
        if instant_only and #(r.conds or {}) == 0 then
            out[#out + 1] = "Only instant actions and no conditions: it would go all the time."
        end
        if (r.conds and #r.conds == 0) then
            out[#out + 1] = "No conditions: it acts whenever its action is ready" ..
                (r.combat_only and " in combat." or ".")
        end
        if not M.lua_available() then
            for _, list in ipairs({ r.conds or {}, r.actions or {} }) do
                for _, row in ipairs(list) do
                    if row.mode == "lua" then
                        out[#out + 1] = "This loader cannot run Lua code: Lua rows never pass."
                        return out
                    end
                end
            end
        end
        return out
    end

    --- Saves a draft (new or edited) and puts it in the engine.
    ---@return integer|nil id
    function M.save(r)
        local b = active_bucket
        if not b then return nil end
        r = copy(r)
        if not r.id then
            r.id = b.next_id
            b.next_id = b.next_id + 1
        end
        normalise(r, r.id)
        local _, at = M.get(r.id)
        if at then b.custom[at] = r else b.custom[#b.custom + 1] = r end
        runtime[r.id] = nil
        rebuild()
        save_bucket()
        return r.id
    end

    function M.delete(id)
        local b = active_bucket
        local _, at = M.get(id)
        if not b or not at then return end
        table.remove(b.custom, at)
        runtime[id] = nil
        rebuild()
        save_bucket()
    end

    function M.duplicate(id)
        local r = M.get(id)
        if not r then return nil end
        local d = copy(r)
        d.id = nil
        d.name = (r.name or "Reaction") .. " (copy)"
        for _, list in ipairs({ d.conds, d.actions }) do
            for _, row in ipairs(list) do row.file = nil end
        end
        return M.save(d)
    end

    function M.set_on(id, on)
        local r = M.get(id)
        if not r then return end
        r.on = on and true or false
        save_bucket()
    end

    --- Moves a reaction up or down the list (ties in score go to the first).
    function M.move(id, delta)
        local b = active_bucket
        local _, at = M.get(id)
        if not b or not at then return end
        local to = math.max(1, math.min(#b.custom, at + delta))
        if to == at then return end
        local r = table.remove(b.custom, at)
        table.insert(b.custom, to, r)
        rebuild()
        save_bucket()
    end

    function M.library()
        local b = active_bucket
        return b and b.library or ""
    end

    --- Replaces the class's Library and rebuilds its sandbox.
    ---@return string|nil err
    ---@return integer|nil line
    function M.set_library(text)
        local b = active_bucket
        if not b then return "no class yet" end
        b.library = tostring(text or "")
        reset_programs()
        save_bucket()
        local prog = env_for(active_class)
        return prog.library_err, prog.library_line
    end

    function M.library_state()
        local prog = env_for(active_class)
        return { err = prog.library_err, line = prog.library_line, fns = prog.fns }
    end

    --- The choices a "choice" condition offers: labels and the values saved.
    function M.choices(kind)
        if kind == "creatures" then return D.CREATURES, D.CREATURES end
        if kind == "modes" then return D.MODES, D.MODES end
        if kind == "threats" then return D.THREATS, D.THREATS end
        if kind == "tactics" then return D.TACTICAL_STATES, D.TACTICAL_STATES end
        if kind == "advice" then return D.ADVICE, D.ADVICE end
        if kind == "cc_values" then return D.CC_VALUES, D.CC_VALUES end
        if kind == "dr" then return D.DR_LEVELS, D.DR_LEVELS end
        if kind == "patterns" then return D.PATTERNS, D.PATTERNS end
        if kind == "baits" then return D.BAITS, D.BAITS end
        if kind == "kill_verdicts" then return D.KILL_VERDICTS, D.KILL_VERDICTS end
        if kind == "controls" then return D.CONTROLS, D.CONTROLS end
        if kind == "situations" then
            local labels, values = {}, {}
            for i, s in ipairs(D.SITUATIONS) do labels[i], values[i] = s.label, s.key end
            return labels, values
        end
        if kind == "where" then
            local labels, values = {}, {}
            for i, w in ipairs(D.WHERE) do labels[i], values[i] = w.label, w.key end
            return labels, values
        end
        if kind == "library" then
            local fns = env_for(active_class).fns
            return fns, fns
        end
        return {}, {}
    end

    --- Your spellbook, sorted, for the spell pickers.
    function M.spells(filter)
        local names = book.names and book.names() or {}
        if type(filter) ~= "string" or filter == "" then return names end
        local want = filter:lower()
        local out = {}
        for _, n in ipairs(names) do
            if n:lower():find(want, 1, true) then out[#out + 1] = n end
        end
        return out
    end

    function M.pet_spells()
        local out = {}
        for _, n in ipairs(D.PET_SPELLS) do
            if P.pet and P.pet.knows and P.pet.knows(n) then out[#out + 1] = n end
        end
        return out
    end

    --- The catalogue's word on a spell's target: "self", "pet" or nil.
    function M.spell_target(name)
        local catalog = P.catalog
        local row = catalog and catalog.ability and catalog.ability(name) or nil
        local r = row and row.range
        if r == "self" then return "self" end
        if r == "pet" then return "pet" end
        return nil
    end

    --- The draft's conditions against the latest picture, without acting:
    --- the window's live lights. nil when there is no picture (the rotation
    --- is not running).
    function M.preview(r)
        local W = latest_W()
        if not W then return nil end
        local rt = { conds = {}, actions = {}, errors = 0, since = {} }
        local pass = conditions_pass(r, W, rt, (r.name or "draft"))
        rt.pass = pass
        rt.where_ok = env_ok(r.env, W)
        return rt
    end

    -- ==========================================================================
    -- WHY NOT? (1.79.0)
    -- ==========================================================================
    --
    -- One sentence on what a reaction is doing right now, or what stops it:
    -- the first thing in the way, in the order the engine meets them. The
    -- tone says how to colour it: "ok" going or ready, "wait" held up, "off"
    -- not here or switched off, "err" broken, "idle" nothing to judge yet.

    local OUTCOME = {
        selected = "Going out now: %s.",
        deferred = "Ready (%s): waits for a moment the rotation has nothing to press (its priority is under 40).",
        ["below the rotation"] = "Ready (%s), but its priority is under the rotation's 40.",
        ["not checked"] = "Ready (%s): more important things were checked first this moment.",
    }

    ---@param r table a saved reaction (or a draft)
    ---@return string text
    ---@return string tone
    function M.why(r)
        if not master_on() then return "Reactions are switched off (the Reactions page).", "off" end
        if r.on == false then return "Switched off.", "off" end
        if not r.id then return "Not saved yet: save it, and it joins the fight.", "idle" end
        local W = latest_W()
        if not env_ok(r.env, W) then
            return string.format("Not here: it acts %s; you are in %s.", (M.env_text(r.env):gsub("^Only: ", "only in ")),
                M.where_text()), "off"
        end
        local rt = runtime[r.id]
        if over_limit(r) then
            return string.format("Used %d of its %d this fight.", rt and rt.fight_n or 0, r.per_fight), "off"
        end
        if not W then return "Waits for the rotation: it reads the fight while the rotation runs.", "idle" end
        if r.combat_only ~= false and not W.player.in_combat then return "Waits for a fight (only in combat).", "idle" end
        local now = W.now or clock()
        if not rt or not rt.asked_at or (now - rt.asked_at) > 1.5 then
            local def = M.rule_of(r.id)
            local wait = tonumber(r.wait) or 0
            if def and def.fired_at and wait > 0 and (now - def.fired_at) < wait then
                return string.format("Went out %s; waits %.1fs more before the next.", tostring(def.fired_name or "?"),
                    wait - (now - def.fired_at)), "wait"
            end
            return "Not asked this moment (the engine looks at it a few times a second).", "idle"
        end
        if rt.last_fire and (now - rt.last_fire) < 1.5 then
            local h = rt.history[1]
            return string.format("Just went out: %s%s.", h and h.what or "?", (h and h.on) and (" on " .. h.on) or ""), "ok"
        end
        if not rt.pass then
            local any = r.match == "any"
            for i, c in ipairs(r.conds or {}) do
                local slot = rt.conds[c.uid]
                if slot and slot.err then
                    return string.format("Condition %d cannot be read: %s", i, slot.err), "err"
                end
                if slot and not slot.ok and not any then
                    if slot.waiting then
                        return string.format("Condition %d holds, but must hold %.1fs more: %s.", i, slot.waiting,
                            M.cond_text(c)), "wait"
                    end
                    return string.format("Condition %d does not hold: %s (it reads %s).", i, M.cond_text(c),
                        tostring(slot.shown or "nothing")), "wait"
                end
            end
            return "None of its conditions hold.", "wait"
        end
        local o = rt.outcome
        if o and (now - o.at) < 1.0 then
            local f = OUTCOME[o.state]
            if f then return string.format(f, o.name), o.state == "selected" and "ok" or "wait" end
            if o.state == "outscored" then
                return string.format("Ready (%s), but %s came first (%d to %d).", o.name, o.winner or "something else",
                    floor((o.winner_score or 0) + 0.5), floor((o.score or 0) + 0.5)), "wait"
            end
            if o.state == "rejected" or o.state == "waiting" then
                return string.format("Ready, but %s: %s.", o.name, tostring(o.rejected or "refused")), "wait"
            end
            if type(o.state) == "string" and o.state:find("^answered by") then
                return string.format("Ready, but %s already took care of it.", (o.state:gsub("^answered by ", ""))), "wait"
            end
        end
        if rt.note and rt.note:find("^nothing could go") then
            return "Its conditions hold, but " .. rt.note .. ".", "wait"
        end
        return "Its conditions hold.", "ok"
    end

    -- ==========================================================================
    -- THE TEST BENCH (1.79.0)
    -- ==========================================================================
    --
    -- A reaction tried against a situation you set: your health, mobs on you,
    -- the target, the pet, the group, where you are. Nothing is cast: the
    -- picture is made up, and the reaction says what it would do. Spells and
    -- items are checked against your real spellbook and bags.

    local function bench_unit(label) return { label = label, bench = true } end

    --- The engine's picture, made up from a situation (custom_data's
    --- BENCH_PRESETS have the fields).
    local function bench_world(s)
        s = s or {}
        local me, tg, pet = bench_unit("you"), bench_unit("your target"), bench_unit("your pet")
        local tank, healer = bench_unit("the tank"), bench_unit("the healer")
        local function lower_set(text, left, stacks)
            local out = {}
            for name in tostring(text or ""):gmatch("[^,]+") do
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                if name ~= "" then out[name:lower()] = { left = left, stacks = stacks } end
            end
            return out
        end
        local buffs = lower_set(s.buffs, tonumber(s.buff_left) or 30, tonumber(s.buff_stacks) or 1)
        local debuffs = lower_set(s.debuffs, tonumber(s.debuff_left) or 10, tonumber(s.debuff_stacks) or 1)
        local items = {}
        for name in tostring(s.items or ""):gmatch("[^,]+") do
            name = name:gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then items[name:lower()] = true end
        end
        local aura_names = {}
        for name in tostring(s.buffs or ""):gmatch("[^,]+") do
            aura_names[(name:gsub("^%s+", ""):gsub("%s+$", ""))] = true
        end
        local hp = (tonumber(s.hp) or 100) / 100
        local on_me = tonumber(s.on_me) or 0
        local in_group = s.in_group == true
        local W = {
            bench = {
                combat_time = s.combat_time, lowest = s.lowest, hurt = s.hurt, within8 = s.within8 or s.melee_on_me,
                within30 = s.within30 or s.engaged, players = s.players, key = s.key == true, t_name = s.t_name,
                where = s.where or "world", where_name = s.where_name, buffs = buffs, debuffs = debuffs,
                items = items, tank_target = s.tank_target ~= false,
            },
            now = clock(), mode = s.mode or (hp < 0.25 and "EMERGENCY") or (hp < 0.45 and "DEFENSIVE") or "NORMAL",
            env = { danger = tonumber(s.danger) or 0, boss = s.boss == true, pvp = s.pvp == true },
            s = { combo = tonumber(s.combo) or 0 },
            player = {
                unit = me, guid = "bench-me", hp = hp, hp_rate = -(tonumber(s.falling) or 0) / 100,
                ttl = tonumber(s.ttl) or 999, power = tonumber(s.power_raw) or tonumber(s.power) or 100,
                power_pct = (tonumber(s.power) or 100) / 100, power_kind = "MANA", level = tonumber(s.level) or 60,
                in_combat = s.in_combat == true, moving = s.moving == true, busy = s.casting == true,
                control = s.controlled and {} or nil, healthstone = s.healthstone == true, potion = s.potion == true,
                mana_potion = s.mana_potion == true, aura_names = aura_names,
            },
            target = { unit = nil, cast = {} },
            pet = { alive = s.pet == true, unit = s.pet and pet or nil, hp = (tonumber(s.pet_hp) or 100) / 100,
                    attackers = tonumber(s.pet_attackers) or 0, tanking = s.pet_tanking == true },
            group = {
                in_group = in_group, in_raid = s.in_raid == true, members = in_group and (tonumber(s.members) or 4) or 0,
                dead = tonumber(s.dead) or 0, tank_alive = in_group and s.tank_alive ~= false,
                healer_alive = in_group and s.healer_alive ~= false,
                tank = (in_group and s.tank_alive ~= false) and tank or nil,
                healer = (in_group and s.healer_alive ~= false) and healer or nil,
                healer_controlled = s.healer_controlled == true, tank_guid = "bench-tank", healer_guid = "bench-healer",
            },
            enemies = { engaged = tonumber(s.engaged) or 0, on_me = on_me, melee_on_me = tonumber(s.melee_on_me) or 0,
                        nearby = tonumber(s.nearby) or tonumber(s.engaged) or 0, casting_n = 0, casting = {},
                        elites = tonumber(s.elites) or 0, controlled = 0, list = {}, count = 0 },
            sit = {},
        }
        -- The PvP intelligence picture (react/intel), made up the same way:
        -- what its conditions read, from the situation's own fields.
        do
            local I = {
                bench = true, active = s.pvp == true, off = false, now = W.now,
                players = tonumber(s.players) or 0, attackers = on_me,
                melee_attackers = tonumber(s.melee_on_me) or 0,
                me = { escapes_ready = (s.me_safe_escape or s.escapes_ready) and 1 or 0,
                       control = (s.controlled and s.control_helpless) and { helpless = true } or nil },
                env = { target = { guid = s.target and "bench-target" or nil,
                                   zone = s.me_dead_zone and "dead_zone" or (s.target and "ranged" or nil) } },
                foes = {}, mobility_names = { Charge = true, Intercept = true, Blink = true, Sprint = true, Dash = true },
                protection_names = { ["Power Word: Shield"] = true, ["Ice Barrier"] = true },
                threat = { level = s.pvp_threat or "INFORMATIONAL", score = tonumber(s.pvp_threat_score) or 0,
                           incoming_cast = s.pvp_incoming_cast == true },
                tactic = { state = s.pvp_tactic or (s.pvp and "IDLE" or "NONE") },
                pos = { advice = s.pvp_advice or (s.me_safe_escape and "increase") or (s.pvp and "hold" or "none") },
                cds = { protection = { names = {}, left = 0, physical = 0, spell = 0, melee = 0 } },
                pet = { on_controlled = s.pet_breaks_cc == true },
                -- The control plan (Stage 6): the pet's recall, the target's row below.
                cc = { hold = nil, doomed = nil, target = nil, held_n = 0, ours_n = 0,
                       pet = { recall = s.pet_breaks_cc == true, why = "" }, unknown = {} },
                -- The kill window (Stage 9): the verdict the situation says.
                kill = { target = (s.t_kill_verdict and s.t_kill_verdict ~= "NO_KILL_OPPORTUNITY") and
                             { guid = "bench-target", v = s.t_kill_verdict, conf = (tonumber(s.t_kill_conf) or 70) / 100,
                               why = "the bench's", actions = {}, reasons = {} } or nil,
                         by_guid = {}, best = nil, line = "" },
                -- The teamfight (Stage 10): the reads the situation says.
                team = { active = s.pvp_focus_me or s.pvp_peel or s.pvp_team_interrupt or s.pvp_switch or s.pvp_healer_free
                             or s.pvp_overextended or s.pvp_disengage or s.pvp_ally_cc or false,
                         focus = s.pvp_focus_me and { on_me = true, attackers = 2, name = "you", why = "the bench's" } or nil,
                         peel = s.pvp_peel and { name = "an enemy", ally = "an ally", action = "Scatter Shot", why = "the bench's" } or nil,
                         interrupt = s.pvp_team_interrupt and { name = "an enemy", spell = "Flash Heal", kind = "heal", tool = "Scatter Shot",
                                                                why = "the bench's" } or nil,
                         switch = s.pvp_switch and { name = "another", why = "the bench's" } or nil,
                         healer = s.pvp_healer_free and { name = "their healer", free = true, why = "the bench's" } or nil,
                         overextended = s.pvp_overextended and { why = "the bench's" } or nil,
                         disengage = s.pvp_disengage and { why = "the bench's" } or nil,
                         overlap = s.pvp_ally_cc and { guid = "bench-target", name = "your target", why = "the bench's" } or nil,
                         casts = {}, line = "" },
                -- The bait (Stage 8): the one the situation says.
                bait = { target = (s.pvp_bait and s.pvp_bait ~= "none") and
                             { kind = s.pvp_bait, guid = "bench-target", v = s.pvp_bait .. " bait", conf = 0.7, why = "the bench's" } or nil,
                         list = {}, hold_burst = s.pvp_bait == "defensive" and "Rapid Fire" or nil, hold_why = "" },
            }
            if s.me_protected then
                I.cds.protection.names[1] = "Deterrence"
                I.cds.protection.physical, I.cds.protection.melee, I.cds.protection.left = 0.85, 0.85, 8
            end
            if s.target then
                local foe = { guid = "bench-target", name = s.t_name or "your target", recent = {}, cds = {},
                              st = { avoid = s.t_defensive and "physical" or nil, purge = {} },
                              control = (tonumber(s.t_cc_left) or 0) > 0 and { kind = "control", left = tonumber(s.t_cc_left), breaks = true } or nil }
                -- The control plan's row for the target (Stage 6).
                local left = tonumber(s.t_cc_left) or 0
                foe.cc = {
                    held = left > 0 and { name = "a control", kind = "incapacitate", left = left, breaks = true,
                                          category = "incapacitate", ours = s.t_cc_ours == true and "yes" or "no",
                                          ours_conf = 1 } or nil,
                    value = { kind = s.t_cc_value or "none", why = "", conf = 1 },
                    next_level = s.t_dr_next or "full", dr = {}, dots = {}, breakers = {}, pet_on = s.pet_breaks_cc == true,
                }
                I.cc.target = foe.cc
                if foe.cc.held then I.cc.held_n = 1 end
                -- The predictor's row for the target (Stage 7): one pattern, as sure as the situation says.
                foe.predict = {}
                local pat = s.t_pattern
                if pat and pat ~= "none" then
                    local conf = (tonumber(s.t_pattern_conf) or 70) / 100
                    local rel = (tonumber(s.t_pattern_rel) or 50) / 100
                    foe.predict[pat] = { category = pat, v = pat:gsub("_", " "), p = conf, conf = conf,
                                         reliability = rel, label = rel < 0.6 and "low" or rel < 0.75 and "moderate" or "high",
                                         samples = 2, n = 2, sure = conf >= 0.6, adapting = false, basis = "recent", data = "ok",
                                         why = "the bench's", response = "", fallback = "" }
                end
                if s.t_mobility then foe.recent[1] = { name = "Charge", at = W.now, kind = "cast" } end
                local ready = tonumber(s.t_cd_ready)
                for name in tostring(s.t_cd_seen or ""):gmatch("[^,]+") do
                    name = name:gsub("^%s+", ""):gsub("%s+$", "")
                    if name ~= "" then
                        foe.cds[name] = { name = name, state = (ready and ready > 0) and "down" or "ready",
                                          ready_in = ready or 0, conf_now = 1 }
                    end
                end
                I.foes["bench-target"] = foe
                I.cds.target = foe.cds
            end
            W.intel = I
        end
        if s.target then
            local T = W.target
            T.unit, T.guid = tg, "bench-target"
            T.hp = (tonumber(s.t_hp) or 100) / 100
            T.distance = tonumber(s.t_distance) or 5
            T.ttd = tonumber(s.t_ttd) or 30
            T.casting = s.t_casting == true
            T.cast = { name = s.t_cast_name or "", remaining = tonumber(s.t_cast_left) or 1.5,
                       interruptible = s.t_interruptible ~= false, danger = 50 }
            T.targets_me, T.targets_pet = s.t_on_me == true, s.t_on_pet == true
            T.elite, T.boss, T.rare, T.player = s.t_elite == true, s.t_boss == true, s.t_rare == true, s.t_player == true
            T.level_diff = tonumber(s.t_level_diff) or 0
            T.controlled, T.runs, T.others_fight = s.t_controlled == true, s.t_runs == true, s.t_others == true
            T.threat_pct = tonumber(s.t_threat) or 0
            T.activity = s.t_fleeing and "fleeing" or "attacking"
            T.target_guid = (s.t_on_tank and "bench-tank") or (s.t_on_healer and "bench-healer")
                or (s.t_on_me and "bench-me") or nil
            T.targets_group = s.t_on_tank == true or s.t_on_healer == true
            local list = W.enemies.list
            list[#list + 1] = { obj = tg, guid = "bench-target", dist = T.distance, hp = T.hp, engaged = true,
                                targeting_me = T.targets_me, target_guid = T.target_guid }
            if T.casting then
                W.enemies.casting[1] = { unit = tg, interruptible = T.cast.interruptible, engaged = true, current = true,
                                         dist = T.distance }
                W.enemies.casting_n = 1
            end
        end
        -- Every other mob on you is one more row, near you.
        local extra = on_me - ((s.target and s.t_on_me) and 1 or 0)
        for i = 1, math.max(0, extra) do
            local add = bench_unit("a mob attacking you")
            W.enemies.list[#W.enemies.list + 1] = { obj = add, guid = "bench-add" .. i, dist = 4, hp = 0.9,
                engaged = true, targeting_me = true, target_guid = "bench-me" }
        end
        if s.healer_attacked then
            W.enemies.list[#W.enemies.list + 1] = { obj = bench_unit("the mob on the healer"), guid = "bench-hx",
                dist = 15, hp = 0.8, engaged = true, target_guid = "bench-healer" }
        end
        W.enemies.count = #W.enemies.list
        if (tonumber(s.casters) or 0) > W.enemies.casting_n then W.enemies.casting_n = tonumber(s.casters) end
        local sit = W.sit
        sit.hp_low, sit.hp_critical = hp < 0.35, hp < 0.2
        sit.outnumbered, sit.aoe, sit.adds = on_me >= 3, W.enemies.engaged >= 3, W.enemies.engaged >= 2
        sit.pet_low = W.pet.alive and W.pet.hp < 0.4
        sit.pet_critical = W.pet.alive and W.pet.hp < 0.2
        sit.mana_low = W.player.power_pct < 0.2
        return W
    end
    M.bench_world = bench_world

    local function said(spec)
        if not spec then return nil end
        local on = spec.target and spec.target.label or (spec.unit and spec.unit.label)
        return spec.name .. (on and on ~= "" and (" on " .. on) or "")
    end

    --- A reaction against a made-up situation: whether it would act there,
    --- each condition's reading, and what each action would do.
    ---@return table { pass, where_ok, combat_ok, conds = {uid -> slot}, actions = {uid -> {ok, note}}, sends, verdict, tone }
    function M.bench(r, s)
        local W = bench_world(s)
        local rt = { conds = {}, actions = {}, errors = 0, since = {}, instants = {} }
        local pass = conditions_pass(r, W, rt, (r.name or "draft") .. " (test)")
        local out = { pass = pass, conds = rt.conds, actions = {}, where_ok = env_ok(r.env, W),
                      combat_ok = not (r.combat_only ~= false and not W.player.in_combat) }
        local first, instants = nil, {}
        for i, a in ipairs(r.actions or {}) do
            local spec, why, raised, extra = action_spec(r, a, W, (r.name or "draft") .. " (test) / action " .. i)
            local note, ok
            if spec and spec.instant then
                note, ok = "goes at once: " .. said(spec), true
                instants[#instants + 1] = said(spec)
            elseif spec and not first then
                first = spec
                note, ok = "would send " .. said(spec), true
            elseif spec then
                note, ok = "not needed: " .. said(first) .. " comes first", true
            else
                note, ok = tostring(why or "cannot go"), false
            end
            for _, x in ipairs(extra or {}) do instants[#instants + 1] = said(x) end
            out.actions[a.uid] = { ok = ok, note = note, err = raised and why or nil }
        end
        out.sends = said(first)
        out.instants = instants
        if not out.where_ok then
            out.verdict, out.tone = "Not here: its Where leaves this place out.", "off"
        elseif not out.combat_ok then
            out.verdict, out.tone = "Not out of combat: it is set to act only in combat.", "off"
        elseif not pass then
            out.verdict, out.tone = "Its conditions do not hold here: nothing goes.", "wait"
        elseif first or #instants > 0 then
            local parts = {}
            if #instants > 0 then parts[#parts + 1] = table.concat(instants, ", ") end
            if first then parts[#parts + 1] = said(first) end
            out.verdict, out.tone = "It would act: " .. table.concat(parts, ", then ") .. ".", "ok"
        else
            out.verdict, out.tone = "Its conditions hold, but no action could go here.", "wait"
        end
        return out
    end

    --- The bench's situations: the ready-made ones (custom_data's
    --- BENCH_PRESETS), then your recorded fights' moments, newest first
    --- (PvP intelligence, Stage 13: react/intel/replay.lua). Rebuilt when asked.
    function M.presets()
        local out = {}
        for i, p in ipairs(D.BENCH_PRESETS) do out[i] = p end
        local I = P.react and P.react.intel or nil
        local R = I and I.replay or nil
        if R and R.situations then
            local ok, list = pcall(R.situations)
            if ok and type(list) == "table" then
                for i = 1, #list do out[#out + 1] = list[i] end
            end
        end
        return out
    end

    --- A reaction replayed over your recorded fights (Stage 13), or nil
    --- without the intelligence layer.
    function M.replay(r)
        local I = P.react and P.react.intel or nil
        local R = I and I.replay or nil
        if not (R and R.run) then return nil end
        return R.run(r)
    end

    --- The fight as it is now, as a test-bench situation (the Try it step's
    --- "From the fight now"). nil while the rotation is not running.
    function M.situation_now()
        local W = latest_W()
        if not W then return nil end
        local T = W.target
        local names = {}
        for n in pairs(W.player.aura_names or {}) do if type(n) == "string" then names[#names + 1] = n end end
        table.sort(names)
        local lowest, hurt = group_health(W)
        local kind, place_name = M.where(W)
        local function r(x) return floor((tonumber(x) or 0) + 0.5) end
        return {
            in_combat = W.player.in_combat == true, hp = r(pct(W.player.hp)), power = r(pct(W.player.power_pct)),
            moving = W.player.moving == true, casting = W.player.busy == true,
            falling = r(math.max(0, -(W.player.hp_rate or 0) * 100)), combat_time = r(combat_time(W)),
            on_me = W.enemies.on_me or 0, melee_on_me = W.enemies.melee_on_me or 0, engaged = W.enemies.engaged or 0,
            casters = W.enemies.casting_n or 0, elites = W.enemies.elites or 0, boss = W.env.boss == true,
            pvp = W.env.pvp == true, within8 = enemies_within(W, 8), within30 = enemies_within(W, 30),
            players = enemies_within(W, 40, true),
            target = T.unit ~= nil, t_hp = r(pct(T.hp)), t_distance = r(finite(T.distance, 99)),
            t_casting = T.casting == true, t_interruptible = T.casting == true and T.cast.interruptible == true,
            t_cast_name = T.casting and (T.cast.name or "") or "", t_cast_left = T.casting and (T.cast.remaining or 0) or 0,
            t_on_me = T.targets_me == true, t_on_pet = T.targets_pet == true, t_elite = T.elite == true,
            t_boss = T.boss == true, t_player = T.player == true, t_fleeing = T.activity == "fleeing",
            t_on_tank = TARGET.on_tank(W), t_on_healer = TARGET.on_healer(W), t_name = TARGET.name(W),
            pet = W.pet.alive == true, pet_hp = r(pct(W.pet.hp)), pet_attackers = W.pet.attackers or 0,
            in_group = W.group.in_group == true, in_raid = W.group.in_raid == true,
            tank_alive = W.group.tank_alive == true, healer_alive = W.group.healer_alive == true,
            dead = W.group.dead or 0, lowest = r(lowest), hurt = hurt,
            where = kind, where_name = place_name, buffs = table.concat(names, ", "),
            -- The PvP intelligence picture (react/intel), as it is now.
            pvp_threat = FIGHT.threat(W), pvp_threat_score = FIGHT.threat_score(W),
            pvp_incoming_cast = FIGHT.incoming_cast(W), pvp_tactic = FIGHT.tactic(W), pvp_advice = FIGHT.advice(W),
            pvp_bait = FIGHT.bait(W),
            pvp_focus_me = FIGHT.team_focus_me(W), pvp_peel = FIGHT.team_peel(W), pvp_team_interrupt = FIGHT.team_interrupt(W),
            pvp_switch = FIGHT.team_switch(W), pvp_healer_free = FIGHT.healer_free(W), pvp_overextended = FIGHT.overextended(W),
            pvp_disengage = FIGHT.disengage(W), pvp_ally_cc = FIGHT.ally_cc_target(W),
            t_mobility = T.unit ~= nil and TARGET.mobility(W) or false, t_defensive = T.unit ~= nil and TARGET.defensive(W) or false,
            t_cd_seen = (function()
                local I = W.intel
                local f = I and I.foes and T.guid and I.foes[T.guid] or nil
                if not (f and f.cds) then return "" end
                local list = {}
                for n in pairs(f.cds) do list[#list + 1] = n end
                table.sort(list)
                return table.concat(list, ", ")
            end)(),
            t_cc_left = T.unit ~= nil and TARGET.cc_left(W) or 0,
            t_cc_value = T.unit ~= nil and TARGET.cc_value(W) or "none",
            t_dr_next = T.unit ~= nil and TARGET.dr_next(W) or "full",
            t_cc_ours = T.unit ~= nil and TARGET.cc_ours(W) or false,
            t_pattern = T.unit ~= nil and TARGET.pattern(W) or "none",
            t_pattern_conf = T.unit ~= nil and TARGET.pattern_conf(W) or 0,
            t_pattern_rel = T.unit ~= nil and TARGET.pattern_reliability(W) or 0,
            t_kill_verdict = T.unit ~= nil and TARGET.kill_verdict(W) or "NO_KILL_OPPORTUNITY",
            t_kill_conf = T.unit ~= nil and TARGET.kill_conf(W) or 0,
            me_protected = ME.protected(W), me_dead_zone = ME.dead_zone(W), me_safe_escape = ME.safe_escape(W),
            pet_breaks_cc = PET.breaks_cc(W),
        }
    end

    --- Every item you carry or wear, by name, for the item pickers.
    function M.carried()
        local hc = P.hardcore
        return (hc and hc.carried) and hc.carried() or {}
    end

    -- ==========================================================================
    -- LUA IN A FILE: edit with VS Code or Notepad++
    -- ==========================================================================
    --
    -- The loader can only write under scripts_data, and cannot open a
    -- program. So a Lua row (or the Library) is written to a file there and
    -- read back every two seconds; save it in any editor and it is loaded.

    local FOLDER = "jambix_aio/reactions"

    local function write_file(path, text)
        if type(core.write_data_file) ~= "function" then return false end
        local cls = path:match("^" .. FOLDER .. "/([^/]+)/")
        pcall(core.create_data_folder, "jambix_aio")
        pcall(core.create_data_folder, FOLDER)
        if cls then pcall(core.create_data_folder, FOLDER .. "/" .. cls) end
        pcall(core.create_data_file, path)
        return (pcall(core.write_data_file, path, text))
    end

    local function read_file(path)
        if type(core.read_data_file) ~= "function" then return nil end
        local ok, text = pcall(core.read_data_file, path)
        if ok and type(text) == "string" then return (text:gsub("\r\n", "\n")) end
        return nil
    end

    function M.full_path(path) return "scripts_data/" .. tostring(path) end

    --- Links a saved reaction's Lua row to a file. Returns the path.
    function M.link_row(id, uid)
        local r = M.get(id)
        if not r or not active_class then return nil end
        for _, list in ipairs({ r.conds, r.actions }) do
            for _, row in ipairs(list) do
                if row.uid == uid and row.mode == "lua" then
                    local path = string.format("%s/%s/%d-%d.lua", FOLDER, active_class, id, uid)
                    if not write_file(path, row.code or "") then return nil end
                    row.file = path
                    save_bucket()
                    return path
                end
            end
        end
        return nil
    end

    function M.unlink_row(id, uid)
        local r = M.get(id)
        if not r then return end
        for _, list in ipairs({ r.conds, r.actions }) do
            for _, row in ipairs(list) do
                if row.uid == uid then row.file = nil end
            end
        end
        save_bucket()
    end

    function M.link_library()
        local b = active_bucket
        if not b or not active_class then return nil end
        local path = string.format("%s/%s/library.lua", FOLDER, active_class)
        if not write_file(path, b.library or "") then return nil end
        b.library_file = path
        save_bucket()
        return path
    end

    function M.unlink_library()
        local b = active_bucket
        if b then b.library_file = nil; save_bucket() end
    end

    function M.library_file()
        return active_bucket and active_bucket.library_file or nil
    end

    M.reloaded = {}             -- path -> time, for the window's notice

    local function poll_files()
        local b = active_bucket
        if not b then return end
        local changed = false
        if b.library_file then
            local text = read_file(b.library_file)
            if text and text ~= "" and text ~= b.library then
                b.library = text
                reset_programs()
                changed = true
                M.reloaded[b.library_file] = clock()
                log.fmt("info", "reactions: the Library was reloaded from %s", M.full_path(b.library_file))
            end
        end
        for _, r in ipairs(b.custom) do
            for _, list in ipairs({ r.conds, r.actions }) do
                for _, row in ipairs(list) do
                    if row.file and row.mode == "lua" then
                        local text = read_file(row.file)
                        if text and text ~= "" and text ~= row.code then
                            row.code = text
                            changed = true
                            M.reloaded[row.file] = clock()
                            log.fmt("info", "reactions: %s reloaded from %s", tostring(r.name), M.full_path(row.file))
                        end
                    end
                end
            end
        end
        if changed then
            rebuild()
            save_bucket()
            if M.on_reload then pcall(M.on_reload) end
        end
    end
    M.poll_files = poll_files
    if ctx and ctx.every then ctx.every(2.0, poll_files) end

    -- Reactions in from GitHub and out to files (1.77.2): share.lua, with
    -- what it needs from here. Without it the window has no Import view.
    do
        local ok, share = pcall(function()
            return load("modules/react/share")(M, P, D, {
                bucket = bucket, normalise = normalise, copy = copy, touch = save_bucket,
                reset_programs = reset_programs,
            })
        end)
        if ok then M.share = share
        else lib.journal("error", "importing reactions failed to load: " .. tostring(share)) end
    end

    -- The starter packs for dungeons and the open world (1.78.0): packs.lua.
    -- Without it My reactions has no packs.
    do
        local ok, packs = pcall(function()
            return load("modules/react/packs")(M, P, D, { copy = copy })
        end)
        if ok then M.packs = packs
        else lib.journal("error", "the starter packs failed to load: " .. tostring(packs)) end
    end

    return M
end

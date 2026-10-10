-- Jambix AIO / pvpx -- PvP extras: diminishing returns, flag carriers, your stealth (1.89.0).
--
-- The user, 2026-10-09, choosing what the world marks should do next:
-- "PvP extras" -- DR timers, battleground and flag-carrier beacons, your
-- stealth-detection ring.
--
--   DIMINISHING  each enemy player's crowd control, whoever put it on (the
--   RETURNS      returns are shared), by category: a small ring under the
--                player for each category running, filling as the 18 s
--                after the last one ends run out, coloured by what the next
--                one would get: amber half, red a quarter, grey immune. A
--                category with nothing running has no ring: the next one
--                is full. Other modules ask M.dr(guid): the reactions can
--                keep a Polymorph for a target it would not be wasted on.
--   FLAG         in a battleground, a tall beacon on each player carrying a
--   CARRIERS     flag: red an enemy, blue your side.
--   YOUR STEALTH while you are in Stealth, Prowl or Shadowmeld, a ring under
--                each enemy player within 30 yd at the distance it would
--                notice you: red, and a warning, once you are inside it.
--
-- THE CATEGORIES ARE CLASSIC ERA'S, NOT THE MECHANICS. The Era client has
-- no field for them (its SpellCategories has no DiminishType; Forever's
-- does), so they are DRList-1.0's Classic Era list, the one the DR addons
-- use, each id's name checked against the Era 1.15.9 client. pvp.lua's
-- mechanics do not line up with them:
--   * Kidney Shot has a category of its own; the other stuns you aim
--     (Cheap Shot, Hammer of Justice, Bash, Charge...) share one, and the
--     stuns that proc (Mace Stun Effect, Impact, Blackout...) another;
--   * Polymorph, Sap, Gouge, Scatter Shot, the Freezing Trap, Wyvern Sting,
--     Hibernate and Repentance share one;
--   * Seduction and Scare Beast are fears;
--   * Blind, Death Coil, Frostbite, the silences and the disarms have none.
-- The window is 18 s from the end of the last one (Era resets somewhere
-- between 15 and 20 s; DRList waits 20). One that lands where this said
-- immune means the server had already reset: it starts a new chain. Death
-- clears them.
--
-- Beacons are on carriers only: who holds a base or a graveyard has no
-- read here (the API has no world state or map points of interest).
--
-- How close you can sneak: an enemy at your level and facing you notices
-- you at 9 yd (a setting), a yard further for each level it has over you
-- and a yard closer for each under (the vanilla rule, as the emulators
-- write it); behind it, a third of that (Blizzard's servers notice a
-- stealther behind only up close, the emulators never). Your Stealth's
-- rank, talents and the human Perception are not read: the setting is
-- yours to lower or raise.
--
-- What is read: the enemy players within 40 yd (nothing in PvE), the
-- nearest ten's auras five times a second each; your own, five times a
-- second, for the stealth; in a battleground, every player's twice a
-- second, eight a frame at most. Auras come through the units service's
-- index (built once a sweep, shared with pvp.lua's reads).

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min, abs, pi, huge = math.floor, math.max, math.min, math.abs, math.pi, math.huge
    local atan2 = math.atan2 or math.atan   -- Lua 5.3's math.atan takes (y, x)

    local M = {}

    local REACH = 40             -- yards: pvp.lua's, an enemy player this close is in the fight
    local READ_EVERY = 0.2       -- seconds between aura reads per player
    local TRACK = 10             -- players whose crowd control is followed, nearest first
    local SHOW = 6               -- players with DR rings, nearest first
    local DR_RINGS = 3           -- DR rings per player, at most
    local GAP = 0.45             -- yards between rings without the world layer (as pvpmarks)
    local FLAG_EVERY = 0.5       -- seconds between flag reads per player
    local FLAG_READS = 8         -- flag reads a frame, at most
    local BG_EVERY = 1.0         -- seconds between "is this a battleground" reads
    local NEAR = 30              -- yards: enemies this close get a stealth ring
    local STEALTH_RINGS = 10     -- stealth rings, nearest first
    local PER_LEVEL = 1          -- yards per level between you
    local BEHIND = 1 / 3         -- behind an enemy, this much of its reach
    local FACE_EVERY = 0.2       -- seconds between facing reads per enemy
    local LEVEL_EVERY = 5        -- seconds between level reads per unit

    local function clock() return core.time() end
    local function game_ms()
        local ok, v = pcall(core.game_time)
        return ok and tonumber(v) or 0
    end
    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end

    -- By how many have landed in the window: what the next one gets.
    local C = {
        dr = { color(245, 180, 60), color(235, 75, 60), color(150, 150, 160) },
        dr_bg = { color(245, 180, 60, 60), color(235, 75, 60, 60), color(150, 150, 160, 60) },
        flag_enemy = color(240, 60, 50), flag_enemy_top = color(240, 60, 50, 25),
        flag_friend = color(70, 140, 255), flag_friend_top = color(70, 140, 255, 25),
        unseen = color(250, 215, 120, 190), unseen_bg = color(250, 215, 120, 30),
        seen = color(240, 60, 50), seen_bg = color(240, 60, 50, 60),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function pvp() return P.react and P.react.pvp end

    local function guid_of(obj)
        if not obj then return nil end
        return (units.guid and ask(units.guid, obj)) or ask(obj.get_guid, obj)
    end

    local names = {}             -- spell id -> name
    local function spell_name(id)
        id = tonumber(id)
        if not id then return nil end
        local n = names[id]
        if n then return n end
        local spells = ctx and ctx.spells
        n = spells and ask(spells.name, id)
        if type(n) ~= "string" or n == "" then
            local book = core.spell_book
            n = book and ask(book.get_spell_name, id)
        end
        if type(n) ~= "string" or n == "" then return nil end
        names[id] = n
        return n
    end

    local EMPTY = {}
    --- A unit's auras: the units service's index (once a sweep), else the list.
    local function auras_of(obj)
        if not obj then return EMPTY end
        if units.aura_index then
            local index = ask(units.aura_index, obj)
            if type(index) == "table" then return index end
        end
        local list = ask(obj.get_auras, obj)
        return type(list) == "table" and list or EMPTY
    end

    -- ==========================================================================
    -- DIMINISHING RETURNS
    -- ==========================================================================
    --
    -- DRList-1.0's Classic Era + Season of Discovery list: the debuffs' spell
    -- ids, and their names in the Era client for a rank not listed.

    local IDS = {
        stun = { 5211, 6798, 8983, 9005, 9823, 9827, 24394, 428739, 853, 5588, 5589, 10308, 1833, 12809,
                 20253, 20614, 20615, 7922, 20549, 4068, 19769, 13808, 4069, 12543, 4064, 12421, 19784,
                 4067, 4066, 4065, 13237, 835, 12562 },
        random_stun = { 16922, 19410, 12355, 20170, 15269, 18093, 12798, 5530, 15283, 56, 21152 },
        kidney_shot = { 408, 8643, 400009 },
        incapacitate = { 2637, 18657, 18658, 3355, 14308, 14309, 19503, 19386, 24132, 24133, 118, 12824,
                 12825, 12826, 28271, 28272, 20066, 1776, 1777, 8629, 11285, 11286, 6770, 2070, 11297,
                 1090, 700, 13327, 26108 },
        fear = { 1513, 14326, 14327, 8122, 8124, 10888, 10890, 5782, 6213, 6215, 5484, 17928, 6358, 5246, 5134 },
        root = { 339, 1062, 5195, 5196, 9852, 9853, 19975, 19974, 19973, 19972, 19971, 19970, 19306,
                 20909, 20910, 122, 865, 6131, 10230 },
        random_root = { 19229, 23694, 27868 },
        mind_control = { 605, 10911, 10912, 13181 },
        frost_shock = { 8056, 8058, 10472, 10473 },
    }
    local NAMES = {
        stun = { "Bash", "Pounce", "Intimidation", "Deep Freeze", "Hammer of Justice", "Cheap Shot",
                 "Concussion Blow", "Intercept Stun", "Charge Stun", "War Stomp", "Iron Grenade",
                 "Thorium Grenade", "M73 Frag Grenade", "Big Iron Bomb", "Hi-Explosive Bomb",
                 "Rough Copper Bomb", "Mithril Frag Bomb", "Dark Iron Bomb", "Big Bronze Bomb",
                 "Small Bronze Bomb", "Large Copper Bomb", "Goblin Mortar", "Tidal Charm", "The Big One" },
        random_stun = { "Starfire Stun", "Improved Concussive Shot", "Impact", "Stun", "Blackout", "Pyroclasm",
                 "Revenge Stun", "Mace Stun Effect", "Stunning Blow", "Earthshaker" },
        kidney_shot = { "Kidney Shot", "Between the Eyes" },
        incapacitate = { "Hibernate", "Freezing Trap Effect", "Scatter Shot", "Wyvern Sting", "Polymorph",
                 "Polymorph: Pig", "Polymorph: Turtle", "Repentance", "Gouge", "Sap", "Sleep",
                 "Reckless Charge", "Glimpse of Madness" },
        fear = { "Scare Beast", "Psychic Scream", "Fear", "Howl of Terror", "Seduction", "Intimidating Shout",
                 "Flash Bomb" },
        root = { "Entangling Roots", "Counterattack", "Frost Nova" },
        random_root = { "Improved Wing Clip", "Improved Hamstring", "Freeze" },
        mind_control = { "Mind Control", "Gnomish Mind Control Cap" },
        frost_shock = { "Frost Shock" },
    }
    --- The categories, for a readout.
    M.CATEGORIES = {
        stun = "Stun", random_stun = "Proc stun", kidney_shot = "Kidney Shot", incapacitate = "Incapacitate",
        fear = "Fear", root = "Root", random_root = "Proc root", mind_control = "Mind Control",
        frost_shock = "Frost Shock",
    }
    local BY_ID, BY_NAME = {}, {}
    for cat, list in pairs(IDS) do for i = 1, #list do BY_ID[list[i]] = cat end end
    for cat, list in pairs(NAMES) do for i = 1, #list do BY_NAME[list[i]] = cat end end

    local LEVELS = { [0] = "full", "half", "quarter", "immune" }
    local MULT = { [0] = 1, 0.5, 0.25, 0 }

    --- The DR category of a spell (its id or name), or a category's own key;
    --- nil for one with none.
    ---@param spell integer|string
    ---@return string|nil
    function M.category(spell)
        if type(spell) == "number" then return BY_ID[spell] or BY_NAME[spell_name(spell) or ""] end
        if type(spell) ~= "string" then return nil end
        if M.CATEGORIES[spell] then return spell end
        return BY_NAME[spell]
    end

    local function category_of(a)
        local id = tonumber(a.buff_id)
        local cat = id and BY_ID[id]
        if cat then return cat end
        local name = a.buff_name
        if type(name) ~= "string" or name == "" then name = spell_name(id) end
        return name and BY_NAME[name] or nil
    end

    local function reset_time()
        return max(1, tonumber(opt("pvpx_dr_reset", 18)) or 18)
    end

    -- guid -> { at, seen, cats = { [category] = c } }
    -- c = { count, on, till, ended, auras = { [id] = expire ms }, mark = { [id] = read } }
    local tracked = {}
    local tracked_at = -1e9
    local serial = 0
    local landed = {}

    --- A control of this category has just landed.
    local function land(c, now, reset)
        if not c.on and c.ended and now - c.ended >= reset then c.count = 0 end
        c.count = c.count + 1
        -- Landed where this said immune: the server had reset already.
        if c.count > 3 then c.count = 1 end
    end

    --- Where a category stands: how many have landed (0: nothing running),
    --- how much of the window has run (0 while one is still on), seconds
    --- until it resets, and whether one is on.
    local function state_of(c, now, reset)
        if not c or c.count <= 0 then return 0, 0, 0, false end
        if c.on and now <= (c.till or now) then
            return c.count, 0, (c.till or now) - now + reset, true
        end
        local ended = (c.on and c.till) or c.ended or now
        local gone = now - ended
        if gone >= reset then return 0, 0, 0, false end
        return c.count, max(0, gone) / reset, reset - max(0, gone), false
    end

    local function read_dr(t, obj, now)
        serial = serial + 1
        for k in pairs(landed) do landed[k] = nil end
        local ms = game_ms()
        local reset = reset_time()
        for _, a in pairs(auras_of(obj)) do
            if type(a) == "table" then
                local cat = category_of(a)
                if cat then
                    local key = tonumber(a.buff_id) or a.buff_name or cat
                    local exp = tonumber(a.expire_time) or 0
                    local c = t.cats[cat]
                    if not c then
                        c = { count = 0, on = false, auras = {}, mark = {} }
                        t.cats[cat] = c
                    end
                    -- New, or put on again (its end moved): one more landed.
                    local prev = c.auras[key]
                    if (prev == nil or abs(exp - prev) > 500) and not landed[cat] then
                        landed[cat] = true
                        land(c, now, reset)
                    end
                    c.auras[key], c.mark[key] = exp, serial
                    local till = exp > 0 and now + max(0, (exp - ms) / 1000) or now
                    if c.read ~= serial then
                        c.read, c.till = serial, till
                    else
                        c.till = max(c.till, till)
                    end
                    c.on = true
                end
            end
        end
        for cat, c in pairs(t.cats) do
            for key, s in pairs(c.mark) do
                if s ~= serial then c.mark[key], c.auras[key] = nil, nil end
            end
            if c.on and c.read ~= serial then
                -- Gone: broken, or run out. The window starts.
                c.on = false
                c.ended = min(now, c.till or now)
            end
            if not c.on and (c.count <= 0 or not c.ended or now - c.ended >= reset) then t.cats[cat] = nil end
        end
    end

    -- --- the enemy players ----------------------------------------------------------

    local function is_player(r)
        local snap = units.snapshot and ask(units.snapshot, r.obj)
        if type(snap) == "table" and snap.is_player ~= nil then return snap.is_player == true end
        local p = pvp()
        if p and type(p.is_player) == "function" then return ask(p.is_player, r.obj, r.guid) == true end
        return ask(r.obj.is_player, r.obj) == true
    end

    local function is_dead(r)
        if r.dead then return true end
        local snap = units.snapshot and ask(units.snapshot, r.obj)
        if type(snap) == "table" and snap.dead ~= nil then return snap.dead == true end
        return units.is_dead and ask(units.is_dead, r.obj) == true or false
    end

    local function by_dist(a, b) return (tonumber(a.dist) or 0) < (tonumber(b.dist) or 0) end

    local plist, pn = {}, 0      -- this frame's enemy players within REACH, alive, nearest first

    local function gather(rows)
        pn = 0
        if type(rows) ~= "table" then
            for i = #plist, 1, -1 do plist[i] = nil end
            return
        end
        for i = 1, #rows do
            local r = rows[i]
            if type(r) == "table" and r.obj and r.guid and (tonumber(r.dist) or REACH + 1) <= REACH
                and is_player(r) then
                if is_dead(r) then
                    tracked[r.guid] = nil            -- death clears them
                else
                    pn = pn + 1
                    plist[pn] = r
                end
            end
        end
        for i = #plist, pn + 1, -1 do plist[i] = nil end
        if pn > 1 then table.sort(plist, by_dist) end
    end

    local stats = { players = 0, looked = 0, dr = 0, bg = false, carriers = 0, stealthed = false,
                    stealth = 0, inside = 0 }

    --- Reads the nearest players' control (five times a second each).
    local function track(now, rows)
        tracked_at = now
        if rows == nil then rows = ctx and ctx.enemies and ask(ctx.enemies.all) end
        gather(rows)
        stats.players = pn
        for i = 1, min(pn, TRACK) do
            local r = plist[i]
            local t = tracked[r.guid]
            if not t then
                t = { at = -1e9, cats = {} }
                tracked[r.guid] = t
            end
            t.seen = now
            if now - t.at >= READ_EVERY then
                t.at = now
                read_dr(t, r.obj, now)
                stats.looked = stats.looked + 1
            end
        end
    end

    --- How the next crowd control would land on an enemy player.
    ---
    ---   M.dr(guid_or_unit, category_or_spell) -> mult (1, 0.5, 0.25 or 0),
    ---       level ("full", "half", "quarter", "immune"), seconds until it
    ---       resets (0 for full). A spell with no category: 1, "full", 0.
    ---   M.dr(guid_or_unit) -> { [category] = { level, mult, count, on,
    ---       reset_in } } for every category running, or nil for none.
    ---
    --- Kept up to date while the marks draw; asked with them off, it reads
    --- the nearest players itself (five times a second at most).
    function M.dr(who, what)
        local now = clock()
        if now - tracked_at >= READ_EVERY then track(now) end
        local guid = who
        if type(who) == "table" or type(who) == "userdata" then guid = guid_of(who) end
        local t = guid ~= nil and tracked[guid] or nil
        local reset = reset_time()
        if what ~= nil then
            local cat = M.category(what)
            local c = cat and t and t.cats[cat]
            if not c then return 1, "full", 0 end
            local count, _, left = state_of(c, now, reset)
            return MULT[count], LEVELS[count], left
        end
        if not t then return nil end
        local out = nil
        for cat, c in pairs(t.cats) do
            local count, _, left, on = state_of(c, now, reset)
            if count > 0 then
                out = out or {}
                out[cat] = { level = LEVELS[count], mult = MULT[count], count = count, on = on, reset_in = left }
            end
        end
        return out
    end

    local rings = {}             -- one player's running categories, reused
    local function by_count(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.cat < b.cat
    end
    local slots = {}             -- reused ring records
    for i = 1, 16 do slots[i] = {} end

    local function render_dr(draw, now, layer)
        local reset = reset_time()
        local lanes = draw.LANES
        local own_lane = type(lanes) == "table" and lanes.dr ~= nil
        for i = 1, min(pn, SHOW) do
            local r = plist[i]
            local t = tracked[r.guid]
            if t then
                local n = 0
                for cat, c in pairs(t.cats) do
                    local count, frac = state_of(c, now, reset)
                    if count > 0 and n < #slots then
                        n = n + 1
                        local s = slots[n]
                        s.cat, s.count, s.frac = cat, count, frac
                        rings[n] = s
                    end
                end
                for k = #rings, n + 1, -1 do rings[k] = nil end
                if n > 0 then
                    if n > 1 then table.sort(rings, by_count) end
                    local pos = units.position and ask(units.position, r.obj)
                    if pos then
                        local reach = tonumber(units.combat_reach and ask(units.combat_reach, r.obj)) or 1.5
                        local base = min(4, max(0.9, reach + 0.3)) + 0.6
                        for k = 1, min(DR_RINGS, n) do
                            local s = rings[k]
                            local lane, index = "cc", 3 + k
                            if own_lane then lane, index = "dr", k end
                            draw.ring_3d(pos, base + (3 + k) * GAP, s.frac, C.dr[s.count], {
                                to = C.dr[s.count], bg = C.dr_bg[s.count], inner = 0.88, outer = 1.0,
                                layer = layer, unit = r.obj, lane = lane, index = index,
                                prio = "info", module = "dr" })
                            stats.dr = stats.dr + 1
                        end
                    end
                end
            end
        end
    end

    -- ==========================================================================
    -- BATTLEGROUNDS: THE FLAG CARRIERS
    -- ==========================================================================
    --
    -- Where: JCore's world service (the client's instance type, "pvp"), else
    -- the client itself, else the battleground's name or map id (the
    -- reactions' custom_data list). The flags: Warsong Gulch's two (Era's
    -- 23333 Warsong Flag, the Horde's, carried by the Alliance; 23335
    -- Silverwing Flag), by id and by name as pvp.lua knows them.

    local FLAG_IDS = { [23333] = true, [23335] = true }
    local FLAG_NAMES = { ["Warsong Flag"] = true, ["Silverwing Flag"] = true }
    local BG_NAMES = { ["Warsong Gulch"] = true, ["Arathi Basin"] = true, ["Alterac Valley"] = true }
    local BG_IDS = { [489] = true, [529] = true, [30] = true }

    local bg = { at = -1e9, on = false }
    local function lower(s) return type(s) == "string" and s:lower() or nil end

    local function in_battleground(now)
        if now - bg.at < BG_EVERY then return bg.on end
        bg.at = now
        local w = ctx and ctx.world
        local yes = false
        if w then
            if type(w.in_battleground) == "function" then yes = ask(w.in_battleground) == true end
            if not yes and type(w.instance_type) == "function" then yes = lower(ask(w.instance_type)) == "pvp" end
        end
        if not yes and type(core.get_instance_type) == "function" then
            yes = lower(ask(core.get_instance_type)) == "pvp"
        end
        if not yes then
            local name = (w and ask(w.instance_name)) or ask(core.get_instance_name)
            yes = type(name) == "string" and BG_NAMES[name] == true
        end
        if not yes and w then
            local id = tonumber(ask(w.instance_id))
            yes = id ~= nil and BG_IDS[id] == true
        end
        bg.on = yes
        return yes
    end

    local function carries_flag(obj)
        for _, a in pairs(auras_of(obj)) do
            if type(a) == "table" and (FLAG_IDS[tonumber(a.buff_id) or 0] or FLAG_NAMES[a.buff_name]) then
                return true
            end
        end
        return false
    end

    local carriers = {}          -- guid -> { obj, enemy, has, next_at, seen }
    local my_guid = nil

    local function flag_check(draw, layer, now, obj, guid, enemy, reads)
        local cr = carriers[guid]
        if not cr then
            cr = { next_at = -1e9 }
            carriers[guid] = cr
        end
        cr.obj, cr.seen, cr.enemy = obj, now, enemy
        if now >= cr.next_at and reads < FLAG_READS then
            reads = reads + 1
            cr.next_at = now + FLAG_EVERY
            cr.has = carries_flag(obj)
        end
        if cr.has then
            local pos = units.position and ask(units.position, obj)
            if pos then
                draw.beacon_3d(pos, enemy and C.flag_enemy or C.flag_friend, {
                    to = enemy and C.flag_enemy_top or C.flag_friend_top, height = 22, radius = 0.55,
                    fill = 0.55, layer = layer, unit = obj, prio = "warn", module = "bg" })
                stats.carriers = stats.carriers + 1
            end
        end
        return reads
    end

    local function render_bg(draw, now, layer, rows)
        if not in_battleground(now) then
            if next(carriers) then carriers = {} end
            return
        end
        stats.bg = true
        my_guid = my_guid or guid_of(ask(units.player))
        local reads = 0
        local list = units.players and ask(units.players)
        if type(list) == "table" then
            -- Everyone the client sees: yours and theirs.
            for i = 1, #list do
                local obj = list[i]
                local row = units.snapshot and ask(units.snapshot, obj)
                if type(row) ~= "table" then row = nil end
                local guid = (row and row.guid) or guid_of(obj)
                if guid and guid ~= my_guid and not (row and (row.is_self or row.dead)) then
                    local enemy
                    if row and row.is_enemy ~= nil then
                        enemy = row.is_enemy == true
                    else
                        enemy = ctx and ctx.enemies and ask(ctx.enemies.get, obj) ~= nil or false
                    end
                    reads = flag_check(draw, layer, now, obj, guid, enemy, reads)
                end
            end
        elseif type(rows) == "table" then
            -- No player list: the enemies only.
            for i = 1, #rows do
                local r = rows[i]
                if type(r) == "table" and r.obj and r.guid and not is_dead(r) and is_player(r) then
                    reads = flag_check(draw, layer, now, r.obj, r.guid, true, reads)
                end
            end
        end
    end

    -- ==========================================================================
    -- YOUR STEALTH
    -- ==========================================================================

    local STEALTH_IDS = { [1784] = true, [1785] = true, [1786] = true, [1787] = true, [5215] = true,
                          [6783] = true, [9913] = true, [20580] = true, [11327] = true, [11329] = true }
    local STEALTH_NAMES = { ["Stealth"] = true, ["Prowl"] = true, ["Shadowmeld"] = true, ["Vanish"] = true }

    local hidden = { at = -1e9, on = false }
    local function stealthed(now)
        if now - hidden.at < READ_EVERY then return hidden.on end
        hidden.at = now
        local on = false
        local me = ask(units.player)
        if me then
            for _, a in pairs(auras_of(me)) do
                if type(a) == "table" and (STEALTH_IDS[tonumber(a.buff_id) or 0] or STEALTH_NAMES[a.buff_name]) then
                    on = true
                    break
                end
            end
        end
        hidden.on = on
        return on
    end

    local info = {}              -- guid -> { level, level_at, rot, rot_at, seen }
    local function info_of(guid, now)
        local f = info[guid]
        if not f then
            f = { level_at = -1e9, rot_at = -1e9 }
            info[guid] = f
        end
        f.seen = now
        return f
    end
    local function level_of(obj, f, now)
        if now - f.level_at >= LEVEL_EVERY then
            f.level_at = now
            local lv = tonumber(ask(obj.get_level, obj))
            f.level = (lv and lv > 0) and lv or nil
        end
        return f.level
    end

    --- How close it notices you, from where you stand.
    local function notice_at(base, my_level, r, f, pos, mine, now)
        local d = base
        local lv = level_of(r.obj, f, now)
        if lv and my_level then d = d + (lv - my_level) * PER_LEVEL end
        if now - f.rot_at >= FACE_EVERY then
            f.rot_at = now
            -- get_direction first (it answers on Forever), else get_rotation; a
            -- zero vector or a rotation of exactly 0 is "not answered" (as tracks.lua).
            local a = nil
            local d = ask(r.obj.get_direction, r.obj)
            if type(d) == "table" or type(d) == "userdata" then
                local ok, x, y = pcall(function() return d.x, d.y end)
                if ok and type(x) == "number" and type(y) == "number" and (x ~= 0 or y ~= 0) then a = atan2(y, x) end
            end
            if not a then
                local rot = tonumber(ask(r.obj.get_rotation, r.obj))
                if rot and rot == rot and rot ~= 0 then a = rot end
            end
            f.rot = a
        end
        if f.rot then
            local dx, dy = mine.x - pos.x, mine.y - pos.y
            if dx ~= 0 or dy ~= 0 then
                local delta = atan2(dy, dx) - f.rot
                while delta > pi do delta = delta - 2 * pi end
                while delta < -pi do delta = delta + 2 * pi end
                if abs(delta) > pi / 2 then d = d * BEHIND end
            end
        end
        return max(1, min(NEAR, d))
    end

    local slist, sn = {}, 0
    local me_info = { level_at = -1e9, rot_at = -1e9 }

    local function render_stealth(draw, now, layer, rows)
        if not stealthed(now) then return end
        stats.stealthed = true
        if type(rows) ~= "table" then return end
        local me = ask(units.player)
        local mine = me and units.position and ask(units.position, me)
        if not mine then return end
        local my_level = level_of(me, me_info, now)
        local base = tonumber(opt("pvpx_stealth_base", 9)) or 9
        local mobs = opt("pvpx_stealth_mobs", false)
        sn = 0
        for i = 1, #rows do
            local r = rows[i]
            if type(r) == "table" and r.obj and r.guid and (tonumber(r.dist) or NEAR + 1) <= NEAR
                and not is_dead(r) and (mobs or is_player(r)) then
                sn = sn + 1
                slist[sn] = r
            end
        end
        for i = #slist, sn + 1, -1 do slist[i] = nil end
        if sn > 1 then table.sort(slist, by_dist) end
        for i = 1, min(sn, STEALTH_RINGS) do
            local r = slist[i]
            local pos = units.position and ask(units.position, r.obj)
            if pos then
                local d = notice_at(base, my_level, r, info_of(r.guid, now), pos, mine, now)
                local inside = (tonumber(r.dist) or huge) <= d
                draw.ring_3d(pos, d, 1, inside and C.seen or C.unseen, {
                    bg = inside and C.seen_bg or C.unseen_bg, inner = 0.93, outer = 1.0, layer = layer,
                    unit = r.obj, prio = inside and "warn" or "info", module = "stealth" })
                stats.stealth = stats.stealth + 1
                if inside then stats.inside = stats.inside + 1 end
            end
        end
    end

    -- ==========================================================================

    local swept_at = -1e9
    local function sweep(now)
        if now - swept_at <= 10 then return end
        swept_at = now
        local reset = reset_time()
        for guid, t in pairs(tracked) do
            if now - (t.seen or now) > 30 then
                local live = false
                for _, c in pairs(t.cats) do
                    if state_of(c, now, reset) > 0 then live = true break end
                end
                if not live then tracked[guid] = nil end
            end
        end
        for guid, f in pairs(info) do
            if now - (f.seen or now) > 30 then info[guid] = nil end
        end
        for guid, cr in pairs(carriers) do
            if now - (cr.seen or now) > 5 then carriers[guid] = nil end
        end
    end

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.players, stats.looked, stats.dr, stats.bg, stats.carriers = 0, 0, 0, false, 0
        stats.stealthed, stats.stealth, stats.inside = false, 0, 0
        -- Through the world layer (1.89.0): lanes, the budget, the look, the wall fade.
        local draw = P.worldmarks or P.draw
        if not draw then return end
        if not opt("pvpx_on", true) then return end
        local now = clock()
        local layer = ((ctx and ctx.LAYER) or {}).WORLD or 100
        local want_dr = opt("pvpx_dr", true) and draw.ring_3d
        local want_bg = opt("pvpx_bg", false) and draw.beacon_3d
        local want_stealth = opt("pvpx_stealth", true) and draw.ring_3d
        if not (want_dr or want_bg or want_stealth) then return end
        local rows = ctx and ctx.enemies and ask(ctx.enemies.all)
        if want_dr then
            track(now, rows)
            render_dr(draw, now, layer)
        end
        if want_bg then render_bg(draw, now, layer, rows) end
        if want_stealth then render_stealth(draw, now, layer, rows) end
        sweep(now)
    end

    function M.stats() return stats end

    return M
end

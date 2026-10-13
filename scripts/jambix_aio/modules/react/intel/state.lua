-- Jambix AIO / react / intel / state -- the PvP picture, with its sources
-- (PvP intelligence, Phase 2: see PVP_INTEL_PLAN.md).
--
-- ONE TABLE, THREE KINDS OF ENTRY
-- The reactions already read one picture of the fight (react/world.lua, W)
-- and one read of the other player (react/pvp.lua, W.pvp). This builds the
-- rest of what a PvP decision needs on top of those two, into W.intel, once
-- a tick, and keeps the three things apart that the brief says must never
-- be confused:
--
--   OBSERVED   a plain field: read from a documented call the client has
--              answered (a row's distance, a player's class, a cast on a bar)
--   INFERRED   a table { v, conf, why }: derived. A rule reads it through
--              M.sure(x, threshold) and gets nil below the threshold, so a
--              guess can never be consumed as a fact by accident.
--   UNKNOWN    an inferred entry with conf 0 and a why that says which call
--              would answer, or a name in S.unavailable (this client leaves
--              it out) or S.unknown (no client says it).
--
-- WHERE THE ANSWERS COME FROM
-- Nearly all of it is already in hand: W (the rotation's snapshot, JCore's
-- enemies rows), W.pvp (what controls us, each player's immunities and
-- bursts, its class and role) and the events the engine already receives.
-- The reads this module adds are rationed and listed with their budget:
--   * a player's facing: the nearest FACE_N, each every FACE_EVERY seconds
--   * line of sight to the target: geometry.sight, every LOS_EVERY seconds,
--     never the client's is_line_of_sight (it crashes Forever, build 70338)
--   * the group's members: every ALLY_EVERY seconds
--   * the instance type: every MODE_EVERY seconds
--   * our own position trail: every TRAIL_EVERY seconds, for a velocity
-- Events (init.lua feeds them): other units' UNIT_SPELLCAST_*, UNIT_AURA
-- "added" records and, on Era, the combat log's SPELL_CAST_SUCCESS, each
-- kept as a recent-ability row per player. Nothing here casts, and nothing
-- here is a decision.
--
-- The table is REUSED between ticks, like W: read it, do not keep it.

return function(P, lib)
    local ctx, units = P.ctx, P.units
    local book = P.spellbook
    local world, pvp = lib.world, lib.pvp

    local M = {}

    local huge, floor, sqrt, abs = math.huge, math.floor, math.sqrt, math.abs
    local atan2 = math.atan2 or math.atan     -- Lua 5.3's math.atan takes (y, x)
    local pi = math.pi

    -- --- the budgets ---------------------------------------------------------
    local REACH = 40            -- yards: an enemy player this close is in the fight (pvp.lua's HUNT)
    local TRACK = 10            -- players carried, nearest first
    local RECENT = 12           -- recent abilities kept per player
    local FACE_N = 4            -- players whose facing is read
    local FACE_EVERY = 0.25     -- seconds between facing reads per player
    local FACE_HALF = 60        -- degrees: "facing you"
    local LOS_EVERY = 0.5       -- seconds between sight rays to the target
    local ALLY_EVERY = 0.5      -- seconds between walks of the group
    local ALLIES = 10           -- allies carried, nearest first
    local MODE_EVERY = 1.0      -- seconds between instance reads
    local TRAIL_EVERY = 0.15    -- our own position trail (as enemies.lua samples theirs)
    local TRAIL = 8
    local TRAIL_MIN = 0.4       -- seconds of trail before a velocity is believed
    local GONE_AFTER = 5.0      -- seconds unseen before a player leaves the list
    local KEEP = 30.0           -- seconds a player's rows are kept once gone (its casts outlive a fight)
    local SWEEP_EVERY = 5.0
    local DUEL_WINDOW = 120.0   -- seconds after DUEL_REQUESTED in which one player on us is a duel
    local FLAGS = { ["Warsong Flag"] = true, ["Silverwing Flag"] = true }   -- pvp.lua's

    -- The catalogue roles that make an ability a defensive, an escape, a
    -- control, a slow or an interrupt (catalog/hunter.lua's vocabulary).
    local ROLE_SETS = {
        defensives = { "defensive" },
        escapes = { "escape" },
        controls = { "cc", "stun", "root", "disorient", "fear", "sleep", "trap" },
        slows = { "slow" },
        interrupts = { "interrupt", "silence" },
    }
    local SET_ORDER = { "defensives", "escapes", "controls", "slows", "interrupts" }

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        if ok then return value end
        return nil
    end

    local function game_ms()
        if type(core.game_time) ~= "function" then return nil end
        local ok, value = pcall(core.game_time)
        return ok and type(value) == "number" and value or nil
    end

    --- An inferred value: what, how sure (0..1), and from what.
    ---@param v any
    ---@param conf number
    ---@param why string
    ---@return table
    local function inferred(v, conf, why)
        return { v = v, conf = conf or 0, why = why or "" }
    end
    M.inferred = inferred

    --- The same, written into a table that is kept between ticks (the
    --- players' entries are rebuilt sixty times a second: no garbage).
    local function infer(holder, key, v, conf, why)
        local x = holder[key]
        if not x then
            x = { v = v, conf = conf or 0, why = why or "" }
            holder[key] = x
        else
            x.v, x.conf, x.why = v, conf or 0, why or ""
        end
        return x
    end

    --- The only way a rule should read an inferred entry: its value when the
    --- confidence clears the threshold, else nil (and the confidence, so the
    --- readout can say "0.4: not enough").
    ---@param x table|nil an inferred entry
    ---@param threshold? number default 0.6
    ---@return any value nil below the threshold
    ---@return number conf
    function M.sure(x, threshold)
        if type(x) ~= "table" then return nil, 0 end
        local conf = tonumber(x.conf) or 0
        if conf >= (threshold or 0.6) then return x.v, conf end
        return nil, conf
    end

    -- --- the table ---------------------------------------------------------------

    local S = {
        now = 0, ticks = 0, active = false, why = "not built yet", off = false,
        client = {},
        unavailable = {},        -- what this client leaves out (strings)
        unknown = {},            -- what no client says (strings)
        mode = { kind = "none", group = "solo", instance = "none", name = "", source = "observed", why = "" },
        me = { abilities = {}, buffs = {}, trail = {} },
        pet = {},
        foes = {}, foe_list = {}, foes_n = 0, players = 0, attackers = 0, melee_attackers = 0,
        allies = {}, ally_list = {}, allies_n = 0,
        env = { target = { los = {} }, objectives = { carriers = {} } },
        -- Every enemy event, kept or dropped and why (live 2026-10-12: three
        -- fights with no enemy ability recorded although the recorder shows
        -- Forever firing them for "target" and "softenemy"): unresolved by the
        -- token's kind, not a player, not attackable.
        events = { casts = 0, auras = 0, combat_log = 0, unresolved = 0, last = nil,
                   unresolved_by = {}, not_player = 0, not_hostile = 0 },
    }
    M.S = S

    -- What this client cannot tell us, said once in the table, so no rule
    -- reads an absence as "safe".
    local function describe_client()
        local c = lib.client or {}
        S.client.forever = c.forever == true
        S.client.combat_log = c.combat_log ~= false
        S.client.name = c.forever and "Forever" or "Classic"
        local u = {}
        if c.combat_log == false then
            u[#u + 1] = "combat log by source (damage, cast success, interrupts: the client sends it empty)"
        end
        if c.forever then
            u[#u + 1] = "threat (the client answers zeros)"
            u[#u + 1] = "a player's mana maximum (unreadable: counted from refusals only)"
        end
        S.unavailable = u
        S.unknown = {
            "an enemy's specialisation and talents (no classic API shows them)",
            "an enemy's cooldowns before one is seen (nothing is tracked until a cast or its aura is observed)",
            "terrain, obstacles and paths (this layer reads none; the walk map is the walker's)",
            "battleground objectives beyond flag carriers (no API for bases or graveyards)",
        }
    end
    describe_client()

    -- --- helpers --------------------------------------------------------------------

    local function is_player(unit, guid)
        if pvp and pvp.is_player then return pvp.is_player(unit, guid) == true end
        return try(unit.is_player, unit) == true
    end

    local function name_of(unit)
        local n = unit and units.name and try(units.name, unit) or nil
        if type(n) ~= "string" or n == "" then n = unit and try(unit.get_name, unit) or nil end
        return (type(n) == "string" and n ~= "") and n or "a player"
    end

    local function spell_name(id)
        if lib.spell_name then return lib.spell_name(id) end
        return world and world.spell_name and world.spell_name(id) or nil
    end

    local function push_recent(f, row)
        local list = f.recent
        list[#list + 1] = row
        while #list > RECENT do table.remove(list, 1) end
        f.recent_at = row.at
        S.events.last = row
    end

    -- --- the players ----------------------------------------------------------------

    local function new_foe(guid, unit, now)
        return {
            guid = guid, unit = unit, name = name_of(unit), first_at = now, at = now, seen = "rows",
            dist = huge, x = 0, y = 0, z = 0, hp = 1, dead = false, in_combat = false,
            target_guid = nil, targets_me = false, targets_pet = false, targets_ally = false,
            closing = 0, speed = 0, moving = false, motion_source = "trail",
            casting = nil, control = nil, class = nil, class_source = "unknown", form = nil,
            st = nil, facing_me = nil, facing_at = -huge, flag = false,
            recent = {}, recent_at = -huge,
            inferred = {},
        }
    end

    --- Who this player is, with how sure we are (react/pvp.lua's read, labelled).
    local function infer_identity(f, foe)
        local inf = f.inferred
        local cls = foe and foe.class or nil
        if not cls then
            infer(inf, "role", "unknown", 0, "get_class answered nothing for this player")
            infer(inf, "healer", false, 0, "class unknown; no heal seen")
            infer(inf, "mana", nil, 0, "class unknown")
            infer(inf, "stealth", nil, 0, "class unknown")
        else
            local role, conf, why = foe.role, 0.7, "from its class"
            if foe.healer then
                role, conf, why = "healer", 0.9, "seen casting a heal in the last 20 s"
            elseif cls == "HUNTER" then
                conf, why = 0.9, "a hunter fights at range"
            elseif cls == "WARRIOR" or cls == "ROGUE" then
                conf, why = 0.9, "a " .. cls:lower() .. " fights in melee"
            elseif cls == "DRUID" and foe.form then
                conf, why = 0.85, "its form (" .. tostring(foe.form) .. ")"
            elseif cls == "PALADIN" then
                conf, why = 0.6, "a paladin may heal or hit; no heal seen yet"
            elseif cls == "DRUID" or cls == "SHAMAN" or cls == "PRIEST" then
                conf, why = 0.6, "a " .. cls:lower() .. " may heal; no heal seen yet"
            end
            infer(inf, "role", role, conf, why)
            infer(inf, "healer", foe.healer == true, foe.healer and 0.9 or 0.5,
                foe.healer and "seen casting a heal in the last 20 s" or "no heal seen in 20 s")
            infer(inf, "mana", foe.mana, 0.8, foe.form and "from its class and form" or "from its class")
            infer(inf, "stealth", foe.stealth, 0.9, "from its class")
        end
        infer(inf, "spec", nil, 0, "talents are not visible to any classic API")
        infer(inf, "objective", "unknown", 0, "not modelled until Phase 6")
        infer(inf, "cooldowns", nil, 0, "not tracked until Stage 3; see recent for what was seen")
    end

    --- Is this player looking at us? One native (its rotation, or its
    --- direction on a client that answers that), for the nearest few, every
    --- FACE_EVERY seconds. A rotation of exactly 0 is "not known" (the
    --- README's assumption for Forever): nil, never false.
    local function read_facing(f, me_pos, now)
        if (now - f.facing_at) < FACE_EVERY then return end
        f.facing_at = now
        local unit = f.unit
        local rot = try(unit.get_rotation, unit)
        local dx, dy = (me_pos.x or 0) - f.x, (me_pos.y or 0) - f.y
        if dx == 0 and dy == 0 then f.facing_me = true return end
        local bearing = atan2(dy, dx)
        local heading = nil
        if type(rot) == "number" and rot ~= 0 and rot == rot then
            heading = rot
        else
            local dir = try(unit.get_direction, unit)
            if type(dir) == "table" and (dir.x ~= 0 or dir.y ~= 0) then heading = atan2(dir.y or 0, dir.x or 0) end
        end
        if not heading then f.facing_me = nil return end
        local delta = (bearing - heading) % (2 * pi)
        if delta > pi then delta = delta - 2 * pi end
        f.facing_me = abs(delta) <= math.rad(FACE_HALF)
    end

    local function fill_from_row(f, r, W, now)
        f.at, f.seen = now, "rows"
        f.unit = r.obj
        f.dist = r.dist or huge
        f.x, f.y, f.z = r.x or f.x, r.y or f.y, r.z or f.z
        f.hp = tonumber(r.hp) or f.hp
        f.dead = r.dead == true
        f.in_combat = r.in_combat == true
        f.target_guid = r.target_guid
        f.targets_me = r.targeting_me == true
        f.targets_pet = r.targeting_pet == true
        f.targets_ally = f.target_guid ~= nil and not f.targets_me and not f.targets_pet
            and world ~= nil and world.in_group ~= nil and world.in_group(f.target_guid)
        f.closing = tonumber(r.closing) or 0
        f.speed = tonumber(r.speed) or 0
        f.moving = r.moving == true
        f.time_to_reach = tonumber(r.time_to_reach) or huge
        -- The cast on its bar, as world.lua already named it this tick. The
        -- sub-table is kept and refilled (sixty ticks a second, ten players).
        f.casting = nil
        if r.casting then
            local cast = f.cast_row or {}
            f.cast_row = cast
            local found = false
            local list = W.enemies.casting or {}
            for i = 1, W.enemies.casting_n or 0 do
                local c = list[i]
                if c.guid == f.guid then
                    cast.id, cast.name, cast.left, cast.total = c.spell_id, c.name, c.remaining, c.total
                    cast.interruptible, cast.channel, cast.at_me = c.interruptible, c.channel, c.at_me
                    cast.danger, cast.kind = c.danger, c.kind
                    found = true
                    break
                end
            end
            if not found then
                cast.id, cast.name = r.casting.spell_id, spell_name(r.casting.spell_id) or ""
                cast.left, cast.total = r.casting.remaining or 0, nil
                cast.interruptible, cast.channel, cast.at_me = r.casting.interruptible == true, r.casting.channel == true, f.targets_me
                cast.danger, cast.kind = nil, nil
            end
            f.casting = cast
        end
        -- The control on it: Era's loss-of-control read, Forever's debuff
        -- read (enemies.lua), each saying what it can.
        local c = r.control
        if type(c) == "table" then
            local ctl = f.control_row or {}
            f.control_row = ctl
            ctl.kind = c.kind or c.mech or (c.type ~= nil and ("type " .. tostring(c.type)) or "control")
            ctl.name = c.name or spell_name(c.spell_id) or ""
            ctl.left = tonumber(c.remaining) or 0
            ctl.breaks, ctl.source = c.breaks, c.from or "client"
            f.control = ctl
        else
            f.control = nil
        end
        -- Who it is (react/pvp.lua, once a tick per player).
        local foe = pvp and pvp.foe and pvp.foe(r.obj, f.guid) or nil
        f.class = foe and foe.class or nil
        f.class_source = f.class and "get_class" or "unknown"
        f.form = foe and foe.form or nil
        f.st = pvp and pvp.state and pvp.state(r.obj, f.guid) or nil
        infer_identity(f, foe)
    end

    local function build_foes(W, now)
        local rows, n = W.enemies.list or {}, W.enemies.count or 0
        local cands, c = {}, 0
        for i = 1, n do
            local r = rows[i]
            if r and r.obj and r.guid and not r.dead and (r.dist or huge) <= REACH and is_player(r.obj, r.guid) then
                c = c + 1
                cands[c] = r
            end
        end
        S.players = c
        if c > 1 then table.sort(cands, function(a, b) return (a.dist or huge) < (b.dist or huge) end) end

        local list = S.foe_list
        for i = #list, 1, -1 do list[i] = nil end
        local attackers, melee = 0, 0
        local me_pos = S.me.pos
        for i = 1, math.min(c, TRACK) do
            local r = cands[i]
            local f = S.foes[r.guid]
            if not f then
                f = new_foe(r.guid, r.obj, now)
                S.foes[r.guid] = f
            end
            fill_from_row(f, r, W, now)
            if f.targets_me then
                attackers = attackers + 1
                if f.dist <= 8 then melee = melee + 1 end
            end
            if me_pos and i <= FACE_N then read_facing(f, me_pos, now) end
            list[#list + 1] = f
        end
        S.foes_n = #list
        S.attackers, S.melee_attackers = attackers, melee
    end

    -- --- us ---------------------------------------------------------------------------

    local trail = S.me.trail
    local trail_at = -huge

    local function sample_trail(pos, now)
        if not pos or (now - trail_at) < TRAIL_EVERY then return end
        trail_at = now
        trail[#trail + 1] = { t = now, x = pos.x or 0, y = pos.y or 0 }
        while #trail > TRAIL do table.remove(trail, 1) end
    end

    local function velocity(now)
        local n = #trail
        if n < 2 then return nil end
        local a, b = trail[1], trail[n]
        local dt = b.t - a.t
        if dt < TRAIL_MIN then return nil end
        local vx, vy = (b.x - a.x) / dt, (b.y - a.y) / dt
        return { vx = vx, vy = vy, speed = sqrt(vx * vx + vy * vy), span = dt, at = now }
    end

    local abilities_for = {}        -- set -> names, from the catalogue, rebuilt when the class changes
    local abilities_class = nil

    local function ability_names(class_module)
        local key = class_module and class_module.key or "?"
        if abilities_class == key then return abilities_for end
        abilities_class = key
        abilities_for = {}
        local catalog = P.catalog
        for _, set in ipairs(SET_ORDER) do
            local names, seen = {}, {}
            if catalog and catalog.with_role then
                for _, role in ipairs(ROLE_SETS[set]) do
                    local rows = try(catalog.with_role, role, false) or {}
                    for i = 1, #rows do
                        local name = rows[i].name
                        if name and not seen[name] then
                            seen[name] = true
                            names[#names + 1] = name
                        end
                    end
                end
            end
            -- The class module's own lists, where the catalogue has no row.
            local own = class_module and class_module[set] or nil
            if type(own) == "table" then
                for i = 1, #own do
                    if not seen[own[i]] then
                        seen[own[i]] = true
                        names[#names + 1] = own[i]
                    end
                end
            end
            abilities_for[set] = names
        end
        return abilities_for
    end

    local function build_me(W, now)
        local pl, me = W.player, S.me
        me.unit, me.guid = pl.unit, pl.guid
        me.hp, me.hp_rate, me.ttl, me.projected = pl.hp, pl.hp_rate, pl.ttl, pl.projected
        me.power, me.power_max, me.power_pct, me.power_kind = pl.power, pl.power_max, pl.power_pct, pl.power_kind
        me.power_counted = P.power_counted ~= nil and try(P.power_counted, pl.power_kind or "") == true
        me.in_combat, me.dead = pl.in_combat, pl.dead == true
        me.level = pl.level
        me.buffs = pl.aura_names or {}
        me.busy, me.gcd = pl.busy, pl.gcd
        if pl.casting_id then
            local cast = me.cast_row or {}
            me.cast_row = cast
            cast.id, cast.name = pl.casting_id, spell_name(pl.casting_id) or ""
            cast.left, cast.channel = pl.cast_remaining, pl.channelling == true
            me.cast = cast
        else
            me.cast = nil
        end
        me.auto_attacking, me.shooting = pl.auto_attacking, pl.shooting
        me.moving, me.still_for = pl.moving, pl.still_for

        -- What controls us: pvp.lua's read, each entry with where it came from.
        local V = W.pvp
        local function control_of(key, e)
            if not e then return nil end
            local t = me[key .. "_row"] or {}
            me[key .. "_row"] = t
            t.kind, t.name, t.left, t.breaks = e.mech, e.name, e.remaining or 0, e.breaks == true
            t.helpless, t.from_player, t.dispel = e.helpless == true, e.from_player, e.dispel
            t.source = e.source or "aura"
            return t
        end
        me.control = control_of("control", V and V.control)
        me.root = control_of("root", V and V.root)
        me.snare = control_of("snare", V and V.snare)
        me.controlled = me.control ~= nil
        me.flag = V ~= nil and V.flag == true

        -- Where we are and which way we move (the player's own reads are
        -- memoised per tick by JCore's player service).
        local cp = ctx and ctx.player
        me.pos = units.player_position and try(units.player_position) or nil
        me.rotation = cp and try(cp.rotation) or nil
        if me.rotation == 0 then me.rotation = nil end
        local speed = cp and try(cp.movement_speed) or nil
        me.speed = type(speed) == "number" and speed or nil
        sample_trail(me.pos, now)
        local v = velocity(now)
        if v then
            infer(me, "velocity", v, 0.8, "our position over the last half second")
        else
            infer(me, "velocity", nil, 0, "fewer than 0.4 s of positions")
        end

        -- What we are looking at.
        me.target_guid = W.target.guid
        me.target_player = W.target.player == true
        local focus = cp and cp.focus and try(cp.focus) or nil
        me.focus_guid = focus and units.guid(focus) or nil
        local over = cp and cp.mouseover and try(cp.mouseover) or nil
        me.mouseover_guid = over and units.guid(over) or nil

        -- Our abilities by what they are for: known, ready, cooldown left.
        local sets = ability_names(W.class)
        local abilities = me.abilities
        for _, set in ipairs(SET_ORDER) do
            local out = abilities[set] or {}
            abilities[set] = out
            local ready_n, known_n = 0, 0
            local names = sets[set] or {}
            for i = 1, #names do
                local name = names[i]
                local row = out[i] or {}
                out[i] = row
                row.name = name
                row.known = book.known(name) == true
                row.ready = row.known and book.ready(name) == true
                row.cooldown = row.known and book.cooldown and (try(book.cooldown, name) or 0) or nil
                if row.known then known_n = known_n + 1 end
                if row.ready then ready_n = ready_n + 1 end
            end
            for i = #names + 1, #out do out[i] = nil end
            me[set .. "_known"], me[set .. "_ready"] = known_n, ready_n
        end
    end

    -- --- the pet --------------------------------------------------------------------

    local function build_pet(W)
        local pet, out = W.pet, S.pet
        out.alive = pet.alive == true
        out.unit, out.guid = pet.unit, pet.guid
        out.hp, out.hp_rate = pet.hp, pet.hp_rate
        out.target_guid = pet.target_guid
        out.target_inferred = pet.target_inferred == true
        out.mode = pet.mode
        out.attackers = pet.attackers or 0
        out.pos = pet.unit and units.position and try(units.position, pet.unit) or nil
        out.dist = pet.unit and units.distance and try(units.distance, pet.unit) or nil
        -- Is its target a player held by control that damage breaks? Phase 8
        -- decides what to do; here it is only said.
        local f = out.target_guid and S.foes[out.target_guid] or nil
        out.on_player = f ~= nil
        out.on_controlled = f ~= nil and f.control ~= nil and f.control.breaks == true
    end

    -- --- the group --------------------------------------------------------------------

    local allies_at = -huge

    local function build_allies(W, now)
        local G = W.group
        S.in_group, S.in_raid = G.in_group == true, G.in_raid == true
        if (now - allies_at) < ALLY_EVERY then return end
        allies_at = now
        local g = ctx and ctx.group
        local list = S.ally_list
        for i = #list, 1, -1 do list[i] = nil end
        local seen = {}
        local objects = (G.in_group and g and try(g.objects)) or nil
        if type(objects) == "table" then
            for i = 1, math.min(#objects, 40) do
                local unit = objects[i]
                local guid = unit and units.guid(unit)
                if guid and guid ~= S.me.guid then
                    seen[guid] = true
                    local a = S.allies[guid]
                    if not a then
                        a = { guid = guid }
                        S.allies[guid] = a
                    end
                    a.unit, a.at = unit, now
                    a.name = name_of(unit)
                    a.dist = units.distance and try(units.distance, unit) or huge
                    a.hp = units.health_fraction and try(units.health_fraction, unit) or 1
                    a.dead = try(unit.is_dead, unit) == true
                    a.tank = g.is_tank ~= nil and try(g.is_tank, unit) == true
                    a.healer = g.is_healer ~= nil and try(g.is_healer, unit) == true
                    a.role = a.tank and "tank" or a.healer and "healer" or "damager"
                    -- Loss of control is a native per unit: only the two
                    -- world.lua already reads.
                    a.controlled = nil
                    if guid == G.healer_guid then a.controlled = G.healer_controlled == true end
                    list[#list + 1] = a
                end
            end
        end
        for guid in pairs(S.allies) do
            if not seen[guid] then S.allies[guid] = nil end
        end
        if #list > 1 then table.sort(list, function(a, b) return (a.dist or huge) < (b.dist or huge) end) end
        for i = #list, ALLIES + 1, -1 do list[i] = nil end
        S.allies_n = #list
        S.tank_guid, S.healer_guid = G.tank_guid, G.healer_guid
    end

    -- --- the ground --------------------------------------------------------------------

    local los_at = -huge
    local los_target = nil

    local function build_env(W, now)
        local env, class_module = S.env, W.class
        -- The class's ranges, from its catalogue when it has one.
        local data = P.catalog and P.catalog.current and try(P.catalog.current) or nil
        local ranges = data and data.ranges or nil
        if ranges then
            local ranged = ranges.ranged or {}
            env.min_ranged = type(ranged) == "table" and ranged.min or nil
            env.max_ranged = type(ranged) == "table" and ranged.max or nil
            env.melee = ranges.melee or 5
            env.dead_zone = ranges.dead_zone
            env.ranges_source = "catalogue"
        else
            env.min_ranged, env.max_ranged, env.melee, env.dead_zone = nil, nil, 5, nil
            env.ranges_source = "no catalogue: melee 5 assumed"
        end
        local H = P.rotation and P.rotation.helpers or nil
        env.melee_range = H and H.melee_range and (try(H.melee_range, W.target.unit) or env.melee) or env.melee

        -- The target: how far, which band, and whether we can see it.
        local tg, t = W.target, env.target
        t.guid, t.player, t.dist = tg.guid, tg.player == true, tg.distance
        if tg.unit and tg.distance ~= huge then
            t.gap = H and H.gap and (try(H.gap, tg.unit, tg.distance) or tg.distance) or tg.distance
            if t.gap <= (env.melee_range or 5) then
                t.zone = "melee"
            elseif env.min_ranged and t.gap < env.min_ranged then
                t.zone = "dead_zone"
            elseif env.max_ranged and t.gap <= env.max_ranged then
                t.zone = "ranged"
            elseif env.max_ranged then
                t.zone = "far"
            else
                t.zone = "ranged"
            end
        else
            t.gap, t.zone = nil, nil
        end
        local los = t.los
        if tg.unit and tg.guid then
            if tg.guid ~= los_target then
                los_target, los_at = tg.guid, -huge
                los.value, los.at, los.source = nil, nil, "not read yet"
            end
            local geometry = ctx and ctx.geometry
            if (now - los_at) >= LOS_EVERY then
                los_at = now
                if geometry and geometry.sight then
                    local ok, value = pcall(geometry.sight, W.player.unit, tg.unit)
                    -- Three answers, kept apart: true, false, and nil (unknown).
                    if ok and type(value) == "boolean" then los.value = value else los.value = nil end
                    los.at = now
                    los.source = ok and (value == nil and "geometry.sight: not calibrated" or "geometry.sight")
                        or "geometry.sight raised"
                else
                    los.value, los.at, los.source = nil, now, "no geometry service"
                end
            end
            los.age = los.at and (now - los.at) or nil
        else
            los_target = nil
            los.value, los.at, los.age, los.source = nil, nil, nil, "no target"
        end

        -- Around us.
        local en = W.enemies
        env.hostiles_near, env.hostiles_engaged, env.hostiles_on_me = en.nearby or 0, en.engaged or 0, en.on_me or 0
        env.hostile_players = S.players
        env.players_on_me = S.attackers
        env.players_in_melee = S.melee_attackers

        -- Objectives: flag carriers only (no API for bases). Read off the
        -- carried players' aura index, built once a tick anyway, in a
        -- battleground only.
        local carriers = env.objectives.carriers
        for i = #carriers, 1, -1 do carriers[i] = nil end
        if S.mode.kind == "bg" then
            for i = 1, #S.foe_list do
                local f = S.foe_list[i]
                f.flag = false
                local index = units.aura_index and try(units.aura_index, f.unit) or nil
                if type(index) == "table" then
                    for _, aura in pairs(index) do
                        if type(aura) == "table" and FLAGS[aura.buff_name or ""] then f.flag = true break end
                    end
                end
                if f.flag then carriers[#carriers + 1] = { guid = f.guid, name = f.name, enemy = true, dist = f.dist } end
            end
            if S.me.flag then carriers[#carriers + 1] = { guid = S.me.guid, name = "you", enemy = false, dist = 0 } end
        end
        env.objectives.source = S.mode.kind == "bg" and "flag auras" or "not a battleground"
    end

    -- --- where we are, and whether this is PvP --------------------------------------

    local mode_at = -huge
    local duel = { requested_at = -huge, finished_at = -huge }

    function M.on_duel(event, now)
        if event == "DUEL_REQUESTED" then duel.requested_at = now end
        if event == "DUEL_FINISHED" then duel.finished_at = now end
    end

    local function build_mode(W, now)
        local m = S.mode
        if (now - mode_at) >= MODE_EVERY then
            mode_at = now
            local w = ctx and ctx.world
            local itype = w and try(w.instance_type) or nil
            m.instance = type(itype) == "string" and itype:lower() or "none"
            m.name = w and try(w.instance_name) or ""
            m.bg = (m.instance == "pvp") or (w and w.in_battleground and try(w.in_battleground) == true) or false
            m.arena = (m.instance == "arena") or (w and w.in_arena and try(w.in_arena) == true) or false
        end
        m.group = S.in_raid and "raid" or S.in_group and "party" or "solo"

        -- One answer to "is this PvP", with every sign that says so.
        local signs = {}
        local V = W.pvp
        if m.bg then signs[#signs + 1] = "a battleground" end
        if m.arena then signs[#signs + 1] = "an arena" end
        if W.target.player then signs[#signs + 1] = "your target is a player" end
        if S.attackers > 0 then signs[#signs + 1] = string.format("%d player(s) on you", S.attackers) end
        if S.foes_n > 0 and S.attackers == 0 then signs[#signs + 1] = string.format("%d enemy player(s) within %d yd", S.players, REACH) end
        local ctl = V and (V.control or V.root or V.snare) or nil
        if ctl and ctl.from_player then signs[#signs + 1] = "a player's control on you" end
        if W.env.context == "pvp" and not m.bg and not m.arena then signs[#signs + 1] = "a PvP instance" end
        local ph = P.pvphunter
        if ph and ph.mode and try(ph.mode) == true then signs[#signs + 1] = "the PvP hunter's mode" end
        S.active = #signs > 0
        S.why = S.active and table.concat(signs, ", ") or ("no enemy player within " .. REACH .. " yd")

        -- The kind of fight.
        local kind, source, why = "none", "observed", ""
        if m.arena then
            kind, why = "arena", "instance type arena"
        elseif m.bg then
            kind, why = "bg", "instance type pvp"
        elseif S.active then
            local since = now - duel.requested_at
            if since >= 0 and since <= DUEL_WINDOW and duel.finished_at < duel.requested_at
                and S.foes_n == 1 and S.foe_list[1] and (S.foe_list[1].targets_me or S.foe_list[1].in_combat) then
                kind, source = "duel", "inferred"
                why = string.format("DUEL_REQUESTED %.0fs ago and one player fighting you", since)
            else
                kind, why = "world_pvp", S.why
            end
        else
            kind, why = (m.instance ~= "none" and m.instance ~= "") and m.instance or "world", "no PvP sign"
        end
        m.kind, m.source, m.why = kind, source, why
        m.duel_requested_ago = (duel.requested_at > -huge) and (now - duel.requested_at) or nil
    end

    -- --- the sweep ----------------------------------------------------------------------

    local sweep_at = -huge

    local function sweep(now)
        if (now - sweep_at) < SWEEP_EVERY then return end
        sweep_at = now
        for guid, f in pairs(S.foes) do
            local idle = now - f.at
            local last_cast = now - (f.recent_at or -huge)
            if idle > KEEP or (idle > GONE_AFTER and last_cast > KEEP) then S.foes[guid] = nil end
        end
    end

    -- --- the build ------------------------------------------------------------------------

    ---@param W table the reactions' world, with W.pvp filled
    ---@param now number
    ---@return table S
    function M.build(W, now)
        S.now, S.ticks = now, S.ticks + 1
        S.off = false
        build_me(W, now)
        build_foes(W, now)
        build_pet(W)
        build_allies(W, now)
        build_mode(W, now)
        build_env(W, now)
        sweep(now)
        return S
    end

    --- The cheap tick: nothing is read, the table says it is off.
    function M.idle(now, why)
        S.now = now
        S.off, S.active, S.why = true, false, why or "switched off"
        return S
    end

    -- --- events (init.lua feeds them) ---------------------------------------------------

    local tokens = {}               -- token -> { guid, unit, at }
    local TOKEN_KEEP = 0.2

    local function skip_token(token)
        if type(token) ~= "string" then return true end
        local head = token:match("^%a+")
        return head == "player" or head == "pet" or head == "party" or head == "raid"
            or head == "vehicle" or head == "partypet" or head == "raidpet"
    end

    --- The unit behind a token (or a guid), resolved through the object
    --- manager and kept TOKEN_KEEP seconds: tokens are recycled.
    local function usable(unit)
        if not unit then return nil end
        local ok, v = pcall(function() return unit:is_valid() end)
        return (ok and v == true) and unit or nil
    end

    local function resolve(token, now)
        local hit = tokens[token]
        if hit and (now - hit.at) <= TOKEN_KEEP then return hit.unit, hit.guid end
        -- JCore's by_guid takes a token too (the object manager's lookup
        -- accepts both); then the lookup itself; then, for "target", the
        -- player's own target.
        local unit = units.by_guid and try(units.by_guid, token) or nil
        if not unit and type(core) == "table" and core.object_manager and core.object_manager.get_object_from_guid then
            unit = usable(try(core.object_manager.get_object_from_guid, token))
        end
        if not unit and token == "target" then
            local me = units.player and try(units.player) or nil
            unit = me and usable(try(me.get_target, me)) or nil
        end
        local guid = unit and ((units.guid and units.guid(unit)) or try(unit.get_guid, unit)) or nil
        tokens[token] = { unit = unit, guid = guid, at = now }
        return unit, guid
    end

    local function player_unit()
        return units.player and try(units.player) or nil
    end

    --- A player we are not carrying yet, seen through an event: a minimal
    --- row, so its casts are kept until the rows catch up.
    local function foe_for_event(unit, guid, now)
        local f = S.foes[guid]
        if f then return f end
        if not is_player(unit, guid) then S.events.not_player = S.events.not_player + 1 return nil end
        local me = player_unit()
        if me and try(me.can_attack, me, unit) ~= true then S.events.not_hostile = S.events.not_hostile + 1 return nil end
        f = new_foe(guid, unit, now)
        f.seen = "event"
        S.foes[guid] = f
        return f
    end

    local EVENT_OF = { start = "UNIT_SPELLCAST_START", cast = "UNIT_SPELLCAST_SUCCEEDED",
                       interrupted = "UNIT_SPELLCAST_INTERRUPTED", channel = "UNIT_SPELLCAST_CHANNEL_START" }

    --- Another unit's cast event: UNIT_SPELLCAST_START / SUCCEEDED /
    --- INTERRUPTED / CHANNEL_START, args { token, cast_guid, spell_id }
    --- (cast_guid is a hole on the channel events: spell_id stays at 3).
    function M.on_cast(token, spell_id, kind, now)
        if skip_token(token) then return end
        local unit, guid = resolve(token, now)
        if not unit or not guid then
            S.events.unresolved = S.events.unresolved + 1
            local kind = token:match("^%a+") or "?"
            S.events.unresolved_by[kind] = (S.events.unresolved_by[kind] or 0) + 1
            return
        end
        local f = foe_for_event(unit, guid, now)
        if not f then return end
        local id = tonumber(spell_id)
        S.events.casts = S.events.casts + 1
        push_recent(f, { id = id, name = spell_name(id) or ("spell " .. tostring(id)), at = now,
                         kind = kind, source = EVENT_OF[kind] or "UNIT_SPELLCAST" })
    end

    --- An aura appearing on another unit (UNIT_AURA "added": { "added",
    --- token, instance_id, spell_id, name, stacks, duration, expiration,
    --- source, is_helpful, is_harmful, dispel }). A helpful aura on an
    --- enemy is the proxy a cooldown is seen through (Stage 3).
    function M.on_aura(token, spell_id, name, helpful, now)
        if skip_token(token) then return end
        local unit, guid = resolve(token, now)
        if not unit or not guid then
            S.events.unresolved = S.events.unresolved + 1
            local kind = token:match("^%a+") or "?"
            S.events.unresolved_by[kind] = (S.events.unresolved_by[kind] or 0) + 1
            return
        end
        local f = foe_for_event(unit, guid, now)
        if not f then return end
        S.events.auras = S.events.auras + 1
        local id = tonumber(spell_id)
        push_recent(f, { id = id, name = (type(name) == "string" and name ~= "") and name or spell_name(id) or ("aura " .. tostring(id)),
                         at = now, kind = helpful and "buff" or "debuff", source = "UNIT_AURA" })
        return guid
    end

    --- Era's combat log: a hostile player's SPELL_CAST_SUCCESS, by guid
    --- (no token to resolve). flags carry the source's type and reaction.
    function M.on_combat_log(source_guid, flags, spell_id, name, now)
        flags = tonumber(flags) or 0
        local hostile = floor(flags / 0x40) % 2 == 1
        local player = floor(flags / 0x400) % 2 == 1
        if not hostile or not player or type(source_guid) ~= "string" then return end
        local f = S.foes[source_guid]
        if not f then
            local unit = units.by_guid and try(units.by_guid, source_guid) or nil
            if not unit then return end
            f = foe_for_event(unit, source_guid, now)
            if not f then return end
        end
        S.events.combat_log = S.events.combat_log + 1
        local id = tonumber(spell_id)
        push_recent(f, { id = id, name = (type(name) == "string" and name ~= "") and name or spell_name(id) or "",
                         at = now, kind = "cast", source = "SPELL_CAST_SUCCESS" })
    end

    function M.on_unit_removed(guid)
        local f = guid and S.foes[guid]
        if f then f.at = math.min(f.at, S.now - GONE_AFTER) end
    end

    --- A zone change, a death, a reload: every player is stale.
    function M.invalidate(why)
        for guid in pairs(S.foes) do S.foes[guid] = nil end
        for i = #S.foe_list, 1, -1 do S.foe_list[i] = nil end
        S.foes_n, S.players, S.attackers, S.melee_attackers = 0, 0, 0, 0
        for guid in pairs(S.allies) do S.allies[guid] = nil end
        for i = #S.ally_list, 1, -1 do S.ally_list[i] = nil end
        S.allies_n = 0
        allies_at, mode_at, los_at, los_target = -huge, -huge, -huge, nil
        for i = #trail, 1, -1 do trail[i] = nil end
        trail_at = -huge
        for k in pairs(tokens) do tokens[k] = nil end
        duel.requested_at, duel.finished_at = -huge, -huge
        S.active, S.why = false, why or "reset"
    end

    --- Combat ended: the players stay (their casts outlive a fight), the
    --- tokens do not.
    function M.combat_end()
        for k in pairs(tokens) do tokens[k] = nil end
    end

    function M.reset()
        M.invalidate("reset")
        S.events.casts, S.events.auras, S.events.combat_log, S.events.unresolved, S.events.last = 0, 0, 0, 0, nil
        S.events.not_player, S.events.not_hostile = 0, 0
        for k in pairs(S.events.unresolved_by) do S.events.unresolved_by[k] = nil end
        S.ticks = 0
    end

    -- --- words ---------------------------------------------------------------------------

    local function pct(x) return floor((tonumber(x) or 0) * 100 + 0.5) end

    --- The readout's lines: what the picture says, and what it cannot.
    ---@return string[]
    function M.lines()
        if S.off then return { "Intel: off" } end
        if not S.active then return { "Intel: off -- " .. tostring(S.why) } end
        local m = S.mode
        local parts = { string.format("Intel: %s%s (%s)", m.kind, m.source == "inferred" and "?" or "", m.group) }
        parts[#parts + 1] = string.format("%d player(s) in %d yd, %d on you", S.players, REACH, S.attackers)
        local t = S.env.target
        local f = t.guid and S.foes[t.guid] or nil
        if f then
            local role, conf = M.sure(f.inferred.role, 0)
            local bits = { string.format("target %s %s (%.2f)", f.class or "?", tostring(role), conf) }
            if t.gap then bits[#bits + 1] = string.format("%.0f yd %s", t.gap, t.zone or "") end
            if f.facing_me ~= nil then bits[#bits + 1] = f.facing_me and "facing you" or "facing away" end
            local los = t.los
            bits[#bits + 1] = "LOS " .. (los.value == true and "yes" or los.value == false and "no" or "unknown")
            if f.st and f.st.immune then bits[#bits + 1] = "immune (" .. tostring(f.st.immune_name) .. ")" end
            if f.st and f.st.burst then bits[#bits + 1] = "bursting (" .. tostring(f.st.burst_name) .. ")" end
            if f.control then bits[#bits + 1] = string.format("%s %.1fs", f.control.kind, f.control.left or 0) end
            parts[#parts + 1] = table.concat(bits, ", ")
        end
        local me = S.me
        if me.control then
            parts[#parts + 1] = string.format("you: %s %.1fs (%s%s)", me.control.kind, me.control.left or 0,
                me.control.name or "", me.control.from_player and ", a player's" or "")
        elseif me.root or me.snare then
            local e = me.root or me.snare
            parts[#parts + 1] = string.format("you: %s %.1fs (%s)", e.kind, e.left or 0, e.name or "")
        end
        parts[#parts + 1] = string.format("ready: %d/%d defensives, %d/%d escapes, %d/%d controls",
            me.defensives_ready or 0, me.defensives_known or 0, me.escapes_ready or 0, me.escapes_known or 0,
            me.controls_ready or 0, me.controls_known or 0)
        local out = { table.concat(parts, " | ") }

        local ev = S.events
        local second = { string.format("Intel: %d cast(s), %d aura(s), %d log line(s) seen", ev.casts, ev.auras, ev.combat_log) }
        if ev.last then
            second[#second + 1] = string.format("last %s %s %.1fs ago", ev.last.kind, ev.last.name, S.now - ev.last.at)
        end
        if ev.unresolved > 0 then second[#second + 1] = ev.unresolved .. " token(s) unresolved" end
        if #S.unavailable > 0 then
            local names = {}
            for i = 1, #S.unavailable do names[i] = S.unavailable[i]:match("^[^(]+"):gsub("%s+$", "") end
            second[#second + 1] = "not on " .. S.client.name .. ": " .. table.concat(names, ", ")
        end
        out[#out + 1] = table.concat(second, " | ")
        return out
    end

    function M.stats()
        return { active = S.active, foes = S.foes_n, players = S.players, allies = S.allies_n, mode = S.mode.kind,
                 ticks = S.ticks, casts = S.events.casts, auras = S.events.auras, unresolved = S.events.unresolved }
    end

    return M
end

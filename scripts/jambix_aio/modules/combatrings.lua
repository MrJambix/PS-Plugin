-- Jambix AIO / combatrings -- your swing, your global cooldown and your
-- target's last seconds, on the ground (1.89.0).
--
-- The user, 2026-10-09, choosing what the world marks should do next:
-- "Swing timer + GCD" and "Time-to-die + execute".
--
--   YOUR SWING   a ring at your feet that fills as your auto attack comes
--                round: empty the moment a swing (or a shot) goes out, full
--                when the next is due. Only in a fight, while you attack.
--   YOUR GCD     a thin ring inside it, emptying over the global cooldown
--                after each spell that starts one. Nothing while it is free.
--   TIME TO DIE  under your target, a ring as full as its health, and the
--                seconds JCore expects it to live as small text at its feet
--                (when it has an estimate). Never under a friend. Shown in a
--                fight, or once the target is hurt.
--   EXECUTE      your execute in range -- Execute or Hammer of Wrath under
--                20%, Kill Shot or Shadow Word: Death under 20% where the
--                client has them, Drain Soul under 25% (the shard) -- and the
--                ring turns red, a red curtain stands round the target, and a
--                pulse goes out the moment it crosses the line. Only for a
--                spell in your spellbook; a rogue has none.
--
-- The ring fills with health, not with time to die over a fixed scale: health
-- is there from the first frame and moves only when the mob is hit, and the
-- execute line is a health line, so the ring empties down to the red. Time to
-- die is unknown for the first second of a fight, jumps with every burst, and
-- on a long fight would sit full; it is the number instead.
--
-- WHERE THE SWING COMES FROM, best first:
--   the Swing Timer addon, when it is loaded (its last swing and when the
--   next is due; never loaded on Forever so far); the loader's auto-attack
--   helper's last attack; and the swings this module sees itself: the
--   client's cast report for each melee swing, Auto Shot or wand shot (6603,
--   75, 5019...) and, on Era, the combat log's SWING_DAMAGE / SWING_MISSED
--   from you (the main hand). The latest swing any of them reports is the
--   ring's start. Its length is the addon's or the helper's when they say,
--   otherwise your weapon's speed (melee: get_attack_speed; ranged: the
--   ranged weapon's, which Forever answers with zeros), otherwise the gap
--   between the last two shots, otherwise 3 s melee / 2.5 s ranged.
--   Past the next swing's time while your attack is still on, the ring keeps
--   going round dimmer, a guess: for three swings once real ones have been
--   seen (out of range nothing swings), for as long as the attack is on when
--   none ever has been (the attack starting is then the only clock there is).
--
-- THE GLOBAL COOLDOWN is JCore's player.gcd (on Forever read off a spell with
-- no cooldown of its own, since get_global_cooldown answers 0 there); how long
-- it was is what was left the first time it was seen.

return function(P)
    local ctx = P.ctx or {}
    local units = P.units or {}
    local opt = P.opt
    local floor, max, min, huge, abs, sqrt = math.floor, math.max, math.min, math.huge, math.abs, math.sqrt

    local M = {}

    local READ_EVERY = 0.2       -- the attack flag, the addon, the helper: five a second
    local SPEED_EVERY = 1.0      -- the weapon's speed
    local DEDUPE = 0.4           -- one swing reported twice (two sources, or twice by one)
    local GRACE = 0.25           -- a swing a little late is not yet a guess
    local GUESS_SWINGS = 3       -- past the last real swing, this many more guessed
    local EXEC_EVERY = 2.0       -- seconds between spellbook asks for an execute
    local TTD_MAX = 600          -- seconds: longer is no number worth showing
    local MELEE_DEFAULT, RANGED_DEFAULT = 3.0, 2.5

    -- The lanes these rings stand in, as the world layer has them (its LANES);
    -- used only when there is no world layer to ask.
    local LANE_OFF = { gcd = 0.65, swing = 1.0, ttd = 1.05 }
    local BAND = 0.25
    local GCD_BAND = 0.12        -- the GCD's ring is the thin one

    -- The auto attacks' spell ids, and their names for a client with others.
    local AUTO = {
        [6603] = "melee",
        [75] = "ranged", [5019] = "ranged", [2480] = "ranged", [7918] = "ranged",
        [7919] = "ranged", [2764] = "ranged", [3018] = "ranged",
    }
    local AUTO_NAMES = {
        ["attack"] = "melee", ["auto attack"] = "melee",
        ["auto shot"] = "ranged", ["shoot"] = "ranged", ["shoot bow"] = "ranged", ["shoot gun"] = "ranged",
        ["shoot crossbow"] = "ranged", ["throw"] = "ranged",
    }

    -- Execute-style abilities, by spellbook name, and the health they need.
    local EXECUTES = {
        { name = "Execute", below = 0.20 },              -- warrior
        { name = "Hammer of Wrath", below = 0.20 },      -- paladin
        { name = "Kill Shot", below = 0.20 },            -- hunter, where the client has it
        { name = "Shadow Word: Death", below = 0.20 },   -- priest, where the client has it
        { name = "Drain Soul", below = 0.25 },           -- warlock: the shard
    }

    local function clock() return core.time() end
    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end

    local C = {
        band = color(0, 0, 0, 100),
        swing = color(150, 175, 215, 170), swing_to = color(255, 215, 110, 240),
        guess = color(150, 175, 215, 80), guess_to = color(255, 215, 110, 110),
        gcd = color(120, 210, 255, 225),
        ttd = color(215, 225, 235, 190),
        exec = color(240, 60, 50, 240), exec_top = color(240, 60, 50, 30), exec_pulse = color(250, 110, 90, 235),
        text = color(235, 235, 240, 230), text_exec = color(255, 120, 100, 255),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function guid_of(obj)
        if not obj then return nil end
        return (units.guid and ask(units.guid, obj)) or ask(obj.get_guid, obj)
    end

    -- A real vec3 for the text where the loader has the library; a plain table
    -- otherwise (JCore's text_3d takes either).
    local vec3_new = nil
    do
        local ok, lib = pcall(require, "common/geometry/vector_3")
        if ok and type(lib) == "table" and type(lib.new) == "function" then vec3_new = lib.new end
    end
    local function vec3(x, y, z)
        if vec3_new then
            local ok, v = pcall(vec3_new, x, y, z)
            if ok and v then return v end
        end
        return { x = x, y = y, z = z }
    end

    --- A lane's outer radius: the world layer's when it is there, the same sum
    --- otherwise.
    local function lane_radius(draw, unit, lane)
        if draw.lane_radius then
            local r = tonumber(ask(draw.lane_radius, unit, lane))
            if r then return r end
        end
        local reach = unit and tonumber(ask(units.combat_reach, unit)) or 1.2
        return min(4, max(0.9, reach + 0.3)) + (LANE_OFF[lane] or 0) + BAND
    end

    -- --- the swing ------------------------------------------------------------------

    local S = {
        last = nil,              -- when the last swing went out (core.time)
        kind = "melee",          -- "melee" | "ranged"
        source = nil,            -- "addon" | "helper" | "cast" | "log" | "start"
        due = nil,               -- when the next is due, when a source said
        real = 0,                -- swings reported this session (not the guess)
        prev = {},               -- kind -> the swing before, for the gap
        learned = {},            -- kind -> the gap between two swings
        speed = {},              -- kind -> the weapon's speed
        attacking = false,
        read_at = -1e9, speed_at = -1e9,
    }

    --- A swing reported: the latest wins, one told twice is one.
    local function offer(kind, at, source, due)
        local last = S.last
        if last and abs(at - last) < DEDUPE then
            if due and not S.due then S.due = due end
            if S.source == "start" and source ~= "start" then
                S.source = source
                S.real = S.real + 1
            end
            return
        end
        if last and at < last then return end
        if source ~= "start" then
            local before = S.prev[kind]
            if before then
                local gap = at - before
                local l = S.learned[kind]
                if gap >= 0.8 and gap <= 5 and (not l or gap < l * 1.5) then S.learned[kind] = gap end
            end
            S.prev[kind] = at
            S.real = S.real + 1
        end
        S.last, S.kind, S.source, S.due = at, kind, source, due
    end

    local function period_of(kind)
        local p = S.speed[kind] or S.learned[kind]
        if p then return p end
        return kind == "ranged" and RANGED_DEFAULT or MELEE_DEFAULT
    end

    -- Which auto attack a spell is, by id and then by name; cached per id.
    local kind_cache = {}
    local function auto_kind(id)
        if type(id) ~= "number" then return nil end
        local k = AUTO[id]
        if k then return k end
        local hit = kind_cache[id]
        if hit ~= nil then return hit or nil end
        local name = ctx.spells and ctx.spells.name and ask(ctx.spells.name, id)
        k = type(name) == "string" and AUTO_NAMES[name:lower()] or nil
        kind_cache[id] = k or false
        return k
    end

    local my_unit, my_guid = nil, nil
    local function me_guid()
        local player = units.player and units.player()
        if not rawequal(player, my_unit) then
            my_unit = player
            my_guid = player and guid_of(player) or nil
        end
        return my_guid, player
    end

    local function swings_wanted()
        return opt("combatrings_on", true) ~= false and opt("cr_swing", true) ~= false
    end

    if type(ctx.on) == "function" then
        -- The client's cast report for the player: every swing and shot of an
        -- auto attack, where the client sends one.
        ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
            if type(args) ~= "table" or args[1] ~= "player" then return end
            local kind = auto_kind(tonumber(args[3]))
            if kind and swings_wanted() then offer(kind, clock(), "cast") end
        end)
        -- The loader's cast callback: the same, with the caster on it.
        ctx.on("jcore.spell.cast", function(data)
            if type(data) ~= "table" then return end
            local kind = auto_kind(data.spell_id)
            if not kind or not data.caster then return end
            local mine, player = me_guid()
            if not player then return end
            if not rawequal(data.caster, player) then
                local g = guid_of(data.caster)
                if not g or g ~= mine then return end
            end
            if swings_wanted() then offer(kind, clock(), "cast") end
        end)
        -- Era's combat log: a melee swing of the main hand, hit or missed. (A
        -- shot is not read here: it lands after its flight, and the swing
        -- started when it left. Forever's log carries no arguments.)
        ctx.on("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", function(a)
            if type(a) ~= "table" then return end
            local sub = a[2]
            local off
            if sub == "SWING_DAMAGE" then off = a[21]
            elseif sub == "SWING_MISSED" then off = a[13]
            else return end
            if off == true or off == 1 then return end
            local mine = me_guid()
            if not mine or a[4] ~= mine then return end
            if swings_wanted() then offer("melee", clock(), "log") end
        end)
        ctx.on("jcore.combat.leave", function()
            S.last, S.due, S.source, S.attacking = nil, nil, nil, false
        end)
    end

    -- The Swing Timer addon, through JCore's guarded mirror when there is one.
    local function read_addon(now)
        local addons = ctx.addons
        local ns, loaded = nil, nil
        if type(addons) == "table" and type(addons.is_loaded) == "function" then
            loaded = ask(addons.is_loaded, "swing_timer")
            ns = addons.swing_timer
        end
        if loaded == nil or type(ns) ~= "table" then
            local raw = type(core.addons) == "table" and core.addons.swing_timer or nil
            if type(raw) ~= "table" then return end
            ns, loaded = raw, ask(raw.is_loaded)
        end
        if loaded ~= true then return end
        for pass = 1, 2 do
            local fn = pass == 1 and ns.get_player_mainhand_info or ns.get_player_ranged_info
            local info = ask(fn)
            if type(info) == "table" then
                local last, due = tonumber(info.last_swing), tonumber(info.expiration_time)
                if last and due and due - last >= 0.5 and due - last <= 6
                    and now - last >= -0.2 and now - last < 4 * (due - last) then
                    offer(pass == 1 and "melee" or "ranged", last, "addon", due)
                end
            end
        end
    end

    -- The loader's auto-attack helper (common/utility/auto_attack_helper): its
    -- own record of your last attack and the next.
    local helper = nil           -- nil: not asked yet; false: not there
    local function read_helper(now, me)
        if helper == nil then
            local ok, mod = pcall(require, "common/utility/auto_attack_helper")
            helper = (ok and type(mod) == "table") and mod or false
        end
        if not helper then return end
        local last = tonumber(ask(helper.get_last_attack_core_time, helper, me))
        if not last or last <= 0 or now - last < -0.2 or now - last >= 6 then return end
        local nxt = tonumber(ask(helper.get_next_attack_core_time, helper, me))
        local due = (nxt and nxt - last >= 0.5 and nxt - last <= 6) and nxt or nil
        offer(S.kind, last, "helper", due)
    end

    local function read_speeds(me)
        local pl = ctx.player
        local s = tonumber(pl and pl.attack_speed and ask(pl.attack_speed)) or tonumber(ask(me.get_attack_speed, me))
        if s and s > 100 then s = s / 1000 end              -- milliseconds
        S.speed.melee = (s and s >= 1 and s <= 5) and s or nil
        local info = ask(me.get_unit_ranged_damage, me)
        local r = type(info) == "table" and tonumber(info.speed) or nil
        S.speed.ranged = (r and r > 0.5 and r < 10) and r or nil
    end

    local function read_flag(me)
        local pl = ctx.player
        local v
        if pl and pl.is_auto_attacking then v = ask(pl.is_auto_attacking) else v = ask(me.is_auto_attacking, me) end
        return v == true
    end

    --- The swing's fraction now and whether it is a guess, or nil for none.
    local function swing_now(now)
        local last = S.last
        if not last then return nil end
        local period = S.due and (S.due - last) or period_of(S.kind)
        local since = max(0, now - last)
        local guess = S.source == "start"
        if since <= period then return since / period, guess end
        if since <= period + GRACE then return 1, guess end
        if not S.attacking then return nil end
        local limit = S.real > 0 and GUESS_SWINGS or huge
        if since > period * (1 + limit) then return nil end
        return (since % period) / period, true
    end

    -- --- the global cooldown --------------------------------------------------------

    local G = { total = nil, prev = 0 }

    local function gcd_left()
        local pl = ctx.player
        local v = pl and pl.gcd and ask(pl.gcd)
        if v == nil and ctx.spells and ctx.spells.gcd then v = ask(ctx.spells.gcd) end
        return tonumber(v) or 0
    end

    -- --- the target -----------------------------------------------------------------

    local exec_at, exec_row = -1e9, nil
    local function execute_spell(now)
        if now - exec_at < EXEC_EVERY then return exec_row end
        exec_at, exec_row = now, nil
        local book = P.spellbook
        if not (book and book.known) then return nil end
        for i = 1, #EXECUTES do
            local e = EXECUTES[i]
            if ask(book.known, e.name) == true and (not exec_row or e.below > exec_row.below) then exec_row = e end
        end
        return exec_row
    end

    --- Is the target something to fight: an enemy in JCore's sweep, or a row
    --- in its enemy tracker. A friend, yourself, or anything unknown is not.
    local function hostile(target)
        local snap = units.snapshot and ask(units.snapshot, target)
        if type(snap) == "table" then
            if snap.is_ally or snap.is_self then return false end
            if snap.is_enemy then return true end
        end
        local enemies = ctx.enemies
        return enemies ~= nil and ask(enemies.get, target) ~= nil
    end

    local exec_guid = nil
    local text_value, text_str = nil, nil
    local function ttd_text(ttd)
        local v = ttd < 10 and floor(ttd * 10 + 0.5) / 10 or floor(ttd + 0.5)
        if v ~= text_value then
            text_value = v
            text_str = ttd < 10 and string.format("%.1f s", v) or string.format("%d s", v)
        end
        return text_str
    end

    -- --- the frame -------------------------------------------------------------------

    -- Each mark's options, made once and refilled: a mark is drawn at most
    -- once a frame, and the world layer (or JCore's draw) has read them by
    -- the next.
    local O = {
        gcd = { to = C.gcd, bg = C.band, outer = 1.0, direction = -1, lane = "gcd", prio = "info", module = "gcd" },
        swing = { bg = C.band, outer = 1.0, lane = "swing", prio = "info", module = "swing" },
        ttd = { bg = C.band, outer = 1.0, lane = "ttd", prio = "info", module = "ttd" },
        curtain = { to = C.exec_top, height = 2.4, points = 24, rings = 3, fill = 0.4, speed = 1.6, spin = 1.2,
            lod = true, prio = "warn", module = "execute" },
        -- No `to` (yards) on the pulse: the world layer shades every `to` as a
        -- colour, and a number there raises in its flush. JCore's 2.4 yd it is.
        pulse = { life = 0.9, from = 0.8, prio = "warn", module = "execute" },
        text = { size = 12 },
    }

    local stats = {
        swing = false, swing_fraction = nil, swing_source = nil, swing_guess = false, swings = 0,
        gcd = false, gcd_fraction = nil,
        ttd = false, hp = nil, ttd_s = nil, execute = false, execute_spell = nil, pulses = 0,
    }

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.swing, stats.swing_fraction, stats.swing_source, stats.swing_guess = false, nil, nil, false
        stats.gcd, stats.gcd_fraction = false, nil
        stats.ttd, stats.hp, stats.ttd_s, stats.execute, stats.execute_spell = false, nil, nil, false, nil
        stats.swings = S.real
        if opt("combatrings_on", true) == false then return end
        local draw = P.worldmarks or P.draw
        if not (draw and draw.ring_3d) then return end
        local me = units.player and units.player()
        if not me then return end
        local now = clock()
        local L = ctx.LAYER or {}
        local layer = L.WORLD or 100
        local combat = P.combat or ctx.combat
        local fight = (combat and ask(combat.in_combat)) == true

        -- YOUR GCD and YOUR SWING, under you.
        local want_gcd = opt("cr_gcd", true) ~= false
        local want_swing = opt("cr_swing", true) ~= false
        local at = nil
        if want_gcd or want_swing then
            at = (units.player_position and units.player_position()) or (units.position and units.position(me))
        end

        if want_gcd and at then
            local left = gcd_left()
            if left > 0.05 and left < 3 then
                -- A new one: nothing was running, or it went up again.
                if not G.total or left > G.prev + 0.1 then G.total = left end
                G.prev = left
                local frac = min(1, left / G.total)
                local r = lane_radius(draw, me, "gcd")
                local o = O.gcd
                o.inner, o.layer = max(0.5, 1 - GCD_BAND / r), layer
                draw.ring_3d(at, r, frac, C.gcd, o)
                stats.gcd, stats.gcd_fraction = true, frac
            else
                G.total, G.prev = nil, 0
            end
        end

        if want_swing and fight then
            if now - S.speed_at >= SPEED_EVERY then
                S.speed_at = now
                read_speeds(me)
            end
            if now - S.read_at >= READ_EVERY then
                S.read_at = now
                local was = S.attacking
                S.attacking = read_flag(me)
                read_addon(now)
                read_helper(now, me)
                -- The attack just went on and nothing has swung lately: the
                -- start is the only clock there is, until a swing says.
                if S.attacking and not was
                    and (not S.last or now - S.last > period_of(S.kind) + GRACE) then
                    offer(S.kind, now, "start")
                end
            end
            local frac, guess = swing_now(now)
            if frac and at then
                local r = lane_radius(draw, me, "swing")
                local o = O.swing
                o.to, o.inner, o.layer = guess and C.guess_to or C.swing_to, max(0.5, 1 - BAND / r), layer
                draw.ring_3d(at, r, frac, guess and C.guess or C.swing, o)
                stats.swing, stats.swing_fraction, stats.swing_source, stats.swing_guess = true, frac, S.source, guess
            end
        elseif not fight then
            S.attacking = false
        end

        -- TIME TO DIE and EXECUTE, under your target.
        local want_ttd = opt("cr_ttd", true) ~= false
        local want_exec = opt("cr_execute", true) ~= false
        local target = (want_ttd or want_exec) and combat and ask(combat.target) or nil
        local dead = target ~= nil and units.is_dead ~= nil and ask(units.is_dead, target) == true
        if not target or dead or not hostile(target) then
            exec_guid = nil
            return
        end
        local pos = units.position and units.position(target)
        local hp = tonumber(units.health_fraction and ask(units.health_fraction, target)) or 1
        if not pos or hp <= 0 then
            exec_guid = nil
            return
        end
        stats.hp = hp
        local ex = want_exec and execute_spell(now) or nil
        local in_exec = ex ~= nil and hp <= ex.below
        local r = lane_radius(draw, target, "ttd")

        if want_ttd and (fight or hp < 0.995) then
            local col = in_exec and C.exec or C.ttd
            local o = O.ttd
            o.to, o.inner, o.layer, o.unit = col, max(0.5, 1 - BAND / r), layer, target
            draw.ring_3d(pos, r, hp, col, o)
            stats.ttd = true
            local row = ctx.enemies and ask(ctx.enemies.get, target)
            local ttd = type(row) == "table" and tonumber(row.ttd) or nil
            if ttd and ttd > 0 and ttd < TTD_MAX and draw.text_3d and opt("world_on", true) ~= false then
                stats.ttd_s = ttd
                -- On the ring's edge toward you, a little off the ground.
                local mp = at or (units.player_position and units.player_position())
                local tx, ty = pos.x, pos.y - r
                if mp then
                    local dx, dy = mp.x - pos.x, mp.y - pos.y
                    local d = sqrt(dx * dx + dy * dy)
                    if d > 0.1 then tx, ty = pos.x + dx / d * r, pos.y + dy / d * r end
                end
                O.text.layer = L.OVERLAY
                draw.text_3d(vec3(tx, ty, pos.z + 0.2), ttd_text(ttd), in_exec and C.text_exec or C.text, O.text)
            end
        end

        if in_exec then
            stats.execute, stats.execute_spell = true, ex.name
            -- 1.7.6: the curtain has its own switch, off by default; the red
            -- ring and the pulse stay with Execute range.
            if draw.curtain_3d and opt("cr_execute_curtain", false) == true then
                local o = O.curtain
                o.layer, o.unit = layer, target
                draw.curtain_3d(pos, r + 0.1, C.exec, o)
            end
            local g = guid_of(target) or target
            if g ~= exec_guid then
                exec_guid = g
                if draw.pulse then
                    local o = O.pulse
                    o.layer, o.unit = layer, target
                    draw.pulse(target, C.exec_pulse, o)
                    stats.pulses = stats.pulses + 1
                end
            end
        else
            exec_guid = nil
        end
    end

    function M.stats() return stats end

    return M
end

-- JCore / loot -- whose mob it is, and whether its corpse is ours (JCore 1.6.0).
--
-- Three questions a plugin asks of a mob and its corpse:
--   tapped(unit)   is it somebody else's? (no loot, no experience for us)
--   fought(guid)   when did it last fight us, our pet or our group?
--   corpse(unit)   is the corpse ours to loot, and can it be skinned?
--
-- ERA: the client answers these itself, so nothing is tracked and nothing is
-- added: tapped() is false with no read (the AIO's Era paths never asked),
-- and corpse() is the client's own has_loot / can_be_looted and
-- can_be_skinned.
--
-- FOREVER. Before client patch 1.60.1.70205 no read told a lootable corpse
-- from a looted one there (has_loot, can_be_looted, the npc and state flags
-- answered the same before and after 35 recorded loot windows), and
-- is_tap_denied answered false for everything. has_loot answers since then
-- (1.6.2, see CORPSE). So, as Jambix AIO's Forever ESP did from
-- 1.48.0 until it moved here:
--   FOUGHT  a mob seen engaged with us, on us, on our pet, on our group, or
--           in combat while our target, or cast at by us (UNIT_SPELLCAST_SENT
--           at the target). Kept FOUGHT_KEEP seconds.
--   TAPPED  is_tap_denied true (believed since the patch: true on strangers'
--           fights and their corpses, false on all 40 corpses we looted; read
--           every TAP_EVERY seconds per tracked hostile), or in combat with a
--           player or a player's pet outside our group with none of it on us.
--           The inferred tag goes when it leaves combat.
--   CORPSE  decided once, the first time it is asked about dead: ours when it
--           was fought within FOUGHT_KEEP, is not tapped, and the client does
--           not call it tap-denied -- or, since the patch, when the client's
--           has_loot says so (1.6.2). The window an open() brought marks that
--           corpse looted. A window nobody asked for (a right-click of the
--           player's own) marks the nearest corpse marked ours within
--           LOOT_REACH yards -- unless it came within CAST_WINDOW of a cast
--           of the player's ending: then it is a skin's, a vein's, a herb's
--           or a chest's, and no corpse's loot (1.6.3: a vein's window used
--           to take a corpse nearby off the list, unlooted). A window from a
--           bag item is not a corpse's. A window that comes PENDING_MAX
--           seconds after an attempt is not that attempt's (1.6.3: one stayed
--           pending 84 s and the next window, another corpse's, was put down
--           to it). Skinnable is the client's can_be_skinned, kept CORPSE_TTL,
--           until a skinning cast on it succeeds (1.6.3: a skinned corpse
--           stayed listed, was pressed again, and the client said "Invalid
--           target").

local FOUGHT_KEEP = 120
local TAP_EVERY = 2.0
local LOOT_REACH = 6.0
local CORPSE_TTL = 1.0
local LOOTED_HOLD = 3.0     -- s a corpse whose window just opened stays off the list (1.6.9)
local SAME_WINDOW = 0.5     -- s: a second LOOT_OPENED this soon is the same window (1.6.10)
local PENDING_MAX = 8.0     -- an open() attempt older than this brought nothing
local CAST_WINDOW = 2.0     -- a loot window this soon after the player's cast is the cast's

return function(rt)
    local events = rt.events
    local units = rt.units

    local M = {}

    local forever = nil
    local function on_forever()
        if forever ~= nil then return forever end
        local world = rt.world
        if not (world and world.client) then return false end
        local ok, c = pcall(world.client)
        if not ok or type(c) ~= "table" then return false end
        forever = c.forever == true
        return forever
    end

    local function ask(obj, method)
        if not obj then return nil end
        local ok_f, fn = pcall(function() return obj[method] end)
        if not ok_f or type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, obj)
        if ok then return value end
        return nil
    end

    -- THE CLIENT'S TAP, AS THE CONTRACT TYPES IT (1.8.8). scripts/.api has
    -- is_tap_denied answer a number; Forever's client answers a boolean (the
    -- recorder: `() -> false`). Only `== true` was taken, so a 1 from a build
    -- that keeps to the contract read as nobody's. True or a non-zero number
    -- is somebody else's tag, as Jambix AIO's esp/classify.lua reads it.
    local function tap_denied(obj)
        local value = ask(obj, "is_tap_denied")
        return value == true or (type(value) == "number" and value ~= 0)
    end

    local fought = {}       -- guid -> last time it fought us / pet / group
    local others = {}       -- guid -> true: in a stranger's fight (inferred)
    local tap_read = {}     -- guid -> { denied, at }: the client's is_tap_denied
    local corpses = {}      -- guid -> { ours, looted, looted_at, x, y, z, skin, skin_at }
    -- HAS_LOOT IS THE ANSWER (1.6.9). The loot study (1.6.8, AIO 1.58.1
    -- session, 2026-10-03): has_loot was true from death until the window
    -- took the loot on the one corpse opened, and false on all five never
    -- opened -- among them a Forest Spider we killed, which had nothing.
    -- "We fought it" made that one ours, and auto-loot pressed it three
    -- times (7 s, the next pull held behind it) before giving up. So once
    -- has_loot has answered true this session, a corpse is lootable exactly
    -- when has_loot says so and it is not somebody else's, and a window
    -- keeps it off the list only LOOTED_HOLD s, until has_loot catches up
    -- (0.5 s after the window in the study). Until then -- a client where it
    -- never answers -- the fight still stands in, as before.
    local has_loot_answers = false
    local group_guids = {}
    local stats = { fought = 0, tapped_read = 0, tapped_inferred = 0, corpses = 0, looted = 0 }

    local function guid_of(unit_or_guid)
        if type(unit_or_guid) == "string" then return unit_or_guid end
        return unit_or_guid and units.guid(unit_or_guid) or nil
    end

    local function refresh_group()
        for k in pairs(group_guids) do group_guids[k] = nil end
        local group = rt.group
        local ok, members = pcall(function() return group and group.objects and group.objects() end)
        if not ok or type(members) ~= "table" then return end
        for i = 1, #members do
            local g = units.guid(members[i])
            if g then group_guids[g] = true end
        end
    end

    --- A stranger's fight, by JCore's enemy row: in combat with a player (or
    --- a player's pet) outside our group, and none of it on us.
    local function strangers(row)
        if not row.in_combat or row.engaged or row.targeting_me or row.targeting_pet then return false end
        local tg = row.target_guid
        if type(tg) ~= "string" or group_guids[tg] then return false end
        return tg:sub(1, 7) == "Player-" or tg:sub(1, 4) == "Pet-"
    end

    local watch_walk            -- set with the opening below (1.6.7)

    --- Once a tick, after the enemies stage (Forever only).
    function M._poll()
        if not on_forever() then return end
        if watch_walk then watch_walk() end
        local enemies = rt.enemies
        if not (enemies and enemies.all) then return end
        refresh_group()
        local now = core.time()
        local target_guid = nil
        do
            local combat = rt.combat
            local ok, target = pcall(function() return combat and combat.target and combat.target() end)
            if ok and target then target_guid = units.guid(target) end
        end
        local rows = enemies.all()
        for i = 1, #rows do
            local row = rows[i]
            local guid = row.guid
            if guid then
                if row.engaged or row.targeting_me or row.targeting_pet
                    or (row.target_guid and group_guids[row.target_guid])
                    or (guid == target_guid and row.in_combat) then
                    fought[guid] = now
                end
                if strangers(row) then
                    others[guid] = true
                elseif not row.in_combat then
                    others[guid] = nil
                end
                local t = tap_read[guid]
                if (not t or now >= t.at) and row.obj then
                    t = t or {}
                    tap_read[guid] = t
                    t.denied = tap_denied(row.obj)
                    -- Spread out, so a crowd is not re-read on one frame.
                    t.at = now + TAP_EVERY * (0.75 + 0.5 * math.random())
                end
            end
        end
    end

    --- Is this mob somebody else's? Era: false, with no read.
    ---@param unit_or_guid game_object|string
    ---@return boolean tapped
    ---@return string|nil how "client" (is_tap_denied) or "fight" (inferred)
    function M.tapped(unit_or_guid)
        if not on_forever() then return false end
        local guid = guid_of(unit_or_guid)
        if not guid then return false end
        local t = tap_read[guid]
        if t and t.denied then return true, "client" end
        if others[guid] then return true, "fight" end
        return false
    end

    --- When it last fought us, our pet or our group (core.time()), or nil.
    --- Forever only; nil elsewhere.
    ---@param unit_or_guid game_object|string
    ---@return number|nil
    function M.fought(unit_or_guid)
        local guid = guid_of(unit_or_guid)
        return guid and fought[guid] or nil
    end

    --- Is this corpse ours to loot, and can it be skinned?
    ---@param unit game_object A dead unit.
    ---@return boolean lootable
    ---@return boolean skinnable
    function M.corpse(unit)
        if not unit then return false, false end
        if not on_forever() then
            local lootable = ask(unit, "can_be_looted") == true or ask(unit, "has_loot") == true
            return lootable, ask(unit, "can_be_skinned") == true
        end
        local guid = units.guid(unit)
        if not guid then return false, false end
        local now = core.time()
        local c = corpses[guid]
        if not c then
            local when = fought[guid]
            local denied = others[guid] == true or (tap_read[guid] ~= nil and tap_read[guid].denied == true)
                or tap_denied(unit)
            c = {
                ours = when ~= nil and (now - when) <= FOUGHT_KEEP and not denied,
                denied = denied,
                looted = false,
            }
            local pos = units.position(unit)
            if pos then c.x, c.y, c.z = pos.x, pos.y, pos.z end
            corpses[guid] = c
            stats.corpses = stats.corpses + 1
        end
        if c.skin_at == nil or now >= c.skin_at then
            c.skin = ask(unit, "can_be_skinned") == true
            -- The client's own word since patch 1.60.1.70205: has_loot was
            -- true on every one of 36 corpses whose loot window then opened
            -- (1.6.2). A corpse it says has loot is ours unless it is
            -- somebody else's, even when the fight was not seen.
            c.has_loot = ask(unit, "has_loot") == true
            if c.has_loot then has_loot_answers = true end
            c.skin_at = now + CORPSE_TTL
        end
        local skinnable = c.skin == true and not c.skinned
        if has_loot_answers then
            local just_looted = c.looted and (now - (c.looted_at or now)) < LOOTED_HOLD
            return (c.has_loot and not c.denied and not just_looted) == true, skinnable
        end
        return (c.ours or (c.has_loot and not c.denied)) and not c.looted, skinnable
    end

    --- Mark a corpse looted (a plugin that knows better than the window).
    ---@param unit_or_guid game_object|string
    function M.looted(unit_or_guid)
        local guid = guid_of(unit_or_guid)
        local c = guid and corpses[guid]
        if c and not c.looted then
            c.looted, c.looted_at = true, core.time()
            stats.looted = stats.looted + 1
        end
    end

    -- --- opening a corpse (1.6.1, 1.6.2) ---------------------------------------
    --
    -- On Forever a corpse does not always open. The first traced session
    -- (AIO 1.55.1, 2026-10-03): three loot_object calls within two seconds at
    -- a corpse 3.7 yd away, the first walking the character onto it (0.1 yd),
    -- no loot window from any -- pressed again before the first could finish.
    -- A single loot_object later opened a Wendigo in 0.6 s; the right-click's
    -- interact_with_object (tried first in 1.6.1) never opened one. So the
    -- call is LEARNED: the kind's own call (loot_object, skin_object) first,
    -- interact_with_object next, alternating per attempt until one is followed by what it should bring
    -- -- a loot window, or for skinning the player's cast -- and from then on
    -- that one goes first, the other on the next try at the same corpse
    -- (1.6.5; it used to be the only one). An attempt is PENDING until that happens, or until
    -- SETTLE seconds have passed with the player standing still (the call may
    -- walk the character there first); opening() says so, and a caller waits
    -- rather than pressing again. Every other client calls exactly what it
    -- always did, and nothing is ever pending.
    --
    -- A PRESS THAT WALKED THERE (1.6.7). A press from a few yards walks the
    -- character onto the corpse first, and that press seldom opens it:
    -- across the AIO 1.57.0 and 1.58.0 traces one in four did (loot_object
    -- from 2.2 and 3.2 yd, the interact from 1.9 yd: nothing; the interact
    -- from 3.7 yd: a window), while every press made standing beside one
    -- opened it within 0.4 s (five of five, both calls, 0.8 to 1.5 yd). So
    -- once a press has walked and the character has stood still ARRIVE
    -- seconds with nothing, the attempt is over and the caller presses again
    -- from where it now stands, instead of waiting SETTLE (2.8 s lost on an
    -- Elder Crag Boar). The walk is seen once a tick (watch_walk, from
    -- _poll): a caller is not asked while the character moves.
    local SETTLE = 2.0
    local ARRIVE = 0.5
    local OWN = { loot = "loot_object", skin = "skin_object" }
    local works = {}            -- kind -> the call seen working on this client
    local pending = nil         -- { kind, call, guid, at, still_since, walked }
    local last_attempt = nil    -- the latest attempt, kept after it settles (1.6.8)
    local open_tries = {}       -- "guid:kind" -> attempts through open()
    local open_stats = { tried = 0, opened = 0, nothing = 0 }

    local function trace(text)
        pcall(events.emit, "jcore.recorder.trace", text)
    end

    local function settle(opened, what)
        local p = pending
        if not p then return end
        pending = nil
        if opened then
            open_stats.opened = open_stats.opened + 1
            if works[p.kind] ~= p.call then
                works[p.kind] = p.call
                trace(string.format("loot: %s opens on this client (%s after %.1fs)", p.call, what or p.kind,
                    core.time() - p.at))
            end
        else
            open_stats.nothing = open_stats.nothing + 1
            trace(string.format("loot: %s at %s brought nothing in %.1fs%s", p.call, tostring(p.guid):sub(-10),
                core.time() - p.at, p.walked and " (it walked there; pressing again from beside it)" or ""))
            -- For the loot study (1.6.11): a press that brought nothing.
            pcall(events.emit, "jcore.loot.nothing", { kind = p.kind, call = p.call, guid = p.guid, at = p.at,
                walked = p.walked == true })
        end
    end

    -- Once a tick (_poll): did the pending press walk the character, and
    -- when did it stop?
    watch_walk = function()
        local p = pending
        if not p then return end
        local player = units.player()
        if player and ask(player, "is_moving") == true then
            p.walked, p.still_since = true, nil
        elseif p.walked and not p.still_since then
            p.still_since = core.time()
        end
    end

    -- A window that comes PENDING_MAX after the attempt is not its (1.6.3).
    -- opening() settles an attempt only when a caller asks, and nobody asks
    -- while no corpse is in reach: one tried at 165 s was still pending at
    -- 249 s, and the window that came then, another corpse's, was put down
    -- to it. (While the character walks, opening() still holds the attempt.)
    local function expire(now)
        local p = pending
        if p and ((now or core.time()) - p.at) > PENDING_MAX then settle(false) end
    end

    -- The player's casts with a bar (1.6.3): a skin's, a vein's, a herb's, a
    -- chest's. The loot window that follows one is that cast's.
    local cast_started = nil    -- when the cast under way started
    local cast_ended_at = -1e9  -- when the last one succeeded
    local skinning = nil        -- { guid, at }: the corpse a skinning cast is on

    --- Is an attempt still waiting on its window (Forever)? False elsewhere.
    ---@return boolean
    function M.opening()
        local p = pending
        if not p then return false end
        local now = core.time()
        local player = units.player()
        local moving = player and ask(player, "is_moving") == true
        if moving then
            p.walked, p.still_since = true, nil
            return true
        end
        p.still_since = p.still_since or now
        local wait = p.walked and ARRIVE or SETTLE
        if (now - p.still_since) >= wait and (now - p.at) >= wait then
            settle(false)
            return false
        end
        return true
    end

    --- Opens a corpse to loot it ("loot") or skins it ("skin"), the way that
    --- works on this client. Era: loot_object / skin_object as always.
    ---@param unit game_object
    ---@param kind? "loot"|"skin"
    ---@return boolean dispatched
    function M.open(unit, kind)
        kind = kind == "skin" and "skin" or "loot"
        local own = OWN[kind]
        if not on_forever() then
            -- Remembered for the loot study (1.6.8), never waited on here.
            last_attempt = { kind = kind, call = own, guid = units.guid(unit), at = core.time(), direct = true }
            if kind == "loot" then return select(2, pcall(core.input.loot_object, unit, true)) == true end
            return select(2, pcall(core.input.skin_object, unit)) == true
        end
        if pending then settle(false) end
        local guid = units.guid(unit)
        -- Counted per kind (1.6.5): a corpse's skin is its first skin try,
        -- whatever its looting took.
        local key = guid and (guid .. ":" .. kind) or nil
        local n = (open_tries[key or ""] or 0) + 1
        if key then open_tries[key] = n end
        -- The call that last opened one goes first -- the kind's own until
        -- one has: loot_object did open corpses (0.6 s after the call, AIO
        -- 1.55.1's trace) -- and the other on the next try at the same corpse
        -- (1.6.5). Kept for good, one window taught the interact in the 1.57.0
        -- trace (pressed point-blank after loot_object had walked there), and
        -- the next corpse refused it twice with loot_object never tried.
        -- Tried and taken out again (1.7.0): targeting the corpse first
        -- (1.6.11) and use_object as a third call (1.6.12). Neither opened a
        -- corpse the two calls below had not; the target change was the
        -- player's to lose. What a press brings stays the loader's on Forever.
        local first = works[kind] or own
        local call = (n % 2 == 1) and first or (first == own and "interact_with_object" or own)
        local ok
        if call == "loot_object" then
            ok = select(2, pcall(core.input.loot_object, unit, true))
        else
            ok = select(2, pcall(core.input[call], unit))
        end
        open_stats.tried = open_stats.tried + 1
        pending = { kind = kind, call = call, guid = guid, at = core.time() }
        last_attempt = pending
        trace(string.format("loot: %s %s via %s (try %d, answered %s)", kind, tostring(guid):sub(-10), call, n,
            tostring(ok)))
        return true
    end

    --- The latest attempt through open() (the loot study, 1.6.8): its kind,
    --- call, corpse guid and time, whether it walked, and whether it still
    --- waits on its window. nil before the first. Elsewhere (Era, SoD) a
    --- press is never waited on, so it counts as waiting for DIRECT_WAIT s.
    local DIRECT_WAIT = 2.0
    function M.attempt()
        local a = last_attempt
        if not a then return nil end
        local waiting = pending == a or (a.direct == true and core.time() - a.at <= DIRECT_WAIT)
        return { kind = a.kind, call = a.call, guid = a.guid, at = a.at, walked = a.walked == true,
            pending = waiting }
    end

    --- The call that opens corpses on this client, once seen; nil until then.
    function M.open_call(kind) return works[kind or "loot"] end

    --- Does an open loot window need its slots taken by hand? Forever: yes.
    --- loot_object opens the corpse there and LOOT_OPENED even says auto-loot,
    --- but the items stay (session 31, 2026-10-03: one corpse's window opened
    --- five times with its Rough Stone still in it). Elsewhere the client's
    --- own auto-loot empties it.
    ---@return boolean
    function M.window_needs_taking()
        return on_forever()
    end

    --- Takes every slot of the open loot window, 0 to the count minus 1, as
    --- the contract numbers them. Returns how many slots the window had, or 0
    --- where nothing needs taking.
    ---
    --- NOT TO THE COUNT INCLUSIVE (1.8.11). Until now one more slot was taken,
    --- for a client that counts from 1. Forever settled it (2026-10-05): the
    --- loot study read every item at 0 to count - 1 and nil at the count, and
    --- loot_item(count) raised "specified invalid slot" (14 of 54 calls).
    ---@return integer
    function M.take_window()
        if not on_forever() then return 0 end
        local ok, count = pcall(core.game_ui.get_loot_item_count)
        count = ok and tonumber(count) or 0
        if count <= 0 then return 0 end
        for index = 0, count - 1 do pcall(core.input.loot_item, index) end
        return count
    end

    function M.stats()
        local n_fought, n_others, n_denied = 0, 0, 0
        for _ in pairs(fought) do n_fought = n_fought + 1 end
        for _ in pairs(others) do n_others = n_others + 1 end
        for _, t in pairs(tap_read) do if t.denied then n_denied = n_denied + 1 end end
        return {
            forever = on_forever(), fought = n_fought, tapped_inferred = n_others,
            tapped_read = n_denied, corpses = stats.corpses, looted = stats.looted,
        }
    end

    -- --- events (Forever) -----------------------------------------------------

    local opts = { owner = "jcore", priority = 0 }

    -- Casting at the target is a fight with it: what it drops is ours.
    events.on("jcore.game_event.UNIT_SPELLCAST_SENT", function(args)
        if not on_forever() or type(args) ~= "table" or args[1] ~= "player" then return end
        local combat = rt.combat
        local ok, target = pcall(function() return combat and combat.target and combat.target() end)
        if not ok or not target then return end
        local row = units.snapshot(target)
        if row and row.is_enemy and not row.dead then
            local guid = units.guid(target)
            if guid then fought[guid] = core.time() end
        end
    end, opts)

    -- The enemy tracker's word can come between two polls.
    events.on("jcore.enemy.engaged", function(row)
        if on_forever() and type(row) == "table" and type(row.guid) == "string" then
            fought[row.guid] = core.time()
        end
    end, opts)

    --- A loot window opened: the corpse being opened, else -- not right after
    --- a cast of the player's -- the nearest one marked ours within reach. A
    --- window from a bag item is not a corpse's.
    -- ONE WINDOW, TWO EVENTS (1.6.10). Forever sends LOOT_OPENED twice for
    -- each loot window, about 0.13 s apart, and LOOT_CLOSED twice (the loot
    -- study, 2026-10-03: every window of the session). The first settled the
    -- press; the second, with nothing pending, was taken for a window nobody
    -- pressed for and marked the nearest OTHER corpse looted.
    local last_window_at = -1e9
    events.on("jcore.game_event.LOOT_OPENED", function(args)
        if not on_forever() then return end
        if type(args) == "table" and args[2] == true then return end
        local now = core.time()
        if now - last_window_at < SAME_WINDOW then return end
        last_window_at = now
        expire(now)
        -- The corpse we were opening is the one this window is from; failing
        -- that, the nearest lootable one (a right-click of the player's own).
        local opened = pending and pending.guid or nil
        if pending then settle(true, "a loot window") end
        if opened and corpses[opened] then
            if not corpses[opened].looted then
                corpses[opened].looted, corpses[opened].looted_at = true, now
                stats.looted = stats.looted + 1
            end
            return
        end
        -- A cast of the player's just ended: this window is its own.
        if (now - cast_ended_at) <= CAST_WINDOW then return end
        local player = units.player()
        local me = player and units.position(player)
        if not me then return end
        local best, best_d = nil, LOOT_REACH
        for _, c in pairs(corpses) do
            if (c.ours or (c.has_loot and not c.denied)) and not c.looted and c.x then
                local dx, dy, dz = c.x - me.x, c.y - me.y, (c.z or 0) - (me.z or 0)
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d <= best_d then best, best_d = c, d end
            end
        end
        if best then
            best.looted, best.looted_at = true, now
            stats.looted = stats.looted + 1
        end
    end, opts)

    -- "Creature must be looted first" to a skin: it has loot after all, and
    -- is ours to loot (1.6.2; the fight was missed, or the window that took
    -- its loot away was another corpse's).
    events.on("jcore.game_event.UI_ERROR_MESSAGE", function(args)
        if not on_forever() or not pending or type(args) ~= "table" then return end
        local text = tostring(args[2] or ""):lower()
        if not text:find("looted first", 1, true) then return end
        local c = pending.guid and corpses[pending.guid]
        if c then
            c.ours, c.looted, c.denied, c.has_loot = true, false, false, true
            trace(string.format("loot: %s must be looted first: looting it", tostring(pending.guid):sub(-10)))
        end
        settle(false)
    end, opts)

    -- Skinning is a cast: the player starting one settles a skin attempt,
    -- and once that cast succeeds the corpse is skinned (1.6.3). Every cast
    -- with a bar is remembered, so the window it brings is not taken for a
    -- corpse's loot.
    events.on("jcore.game_event.UNIT_SPELLCAST_START", function(args)
        if not on_forever() or type(args) ~= "table" or args[1] ~= "player" then return end
        cast_started = core.time()
        if pending and pending.kind == "skin" then
            skinning = { guid = pending.guid, at = cast_started }
            settle(true, "the skinning cast")
        end
    end, opts)

    events.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
        if not on_forever() or type(args) ~= "table" or args[1] ~= "player" then return end
        if not cast_started then return end
        cast_started = nil
        cast_ended_at = core.time()
        local s = skinning
        skinning = nil
        local c = s and s.guid and corpses[s.guid]
        if c then c.skinned = true end
    end, opts)

    -- A cast that did not finish skinned nothing: the corpse stays listed.
    local function cast_over(args)
        if not on_forever() or type(args) ~= "table" or args[1] ~= "player" then return end
        cast_started, skinning = nil, nil
    end
    events.on("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", cast_over, opts)
    events.on("jcore.game_event.UNIT_SPELLCAST_FAILED", cast_over, opts)

    events.on("jcore.unit.removed", function(guid)
        if not guid then return end
        fought[guid], others[guid], tap_read[guid], corpses[guid] = nil, nil, nil, nil
    end, opts)

    events.on("jcore.zone.changed", function()
        fought, others, tap_read, corpses = {}, {}, {}, {}
    end, opts)

    return M
end

-- Jambix AIO / aspects -- the hunter's aspects, switched by hand.
--
-- Since 1.49.0 nothing automatic casts an aspect. The four hunter profiles
-- lost their Aspect of the Hawk rule, and the catalogue gate refuses every
-- ability whose row says exclusive = "aspect" (rotation.lua, catalog_blocks),
-- which is the gate both the priority walk and the reaction engine
-- (press_blocked) go through. Which aspect is up is the player's choice, made
-- here: a small window with one slide switch per trained aspect.
--
-- WHAT A SWITCH MEANS
--   on   that aspect is put up, and put back whenever it goes missing while
--        the switch stays on: after a death, a dismount, a reload.
--   off  the aspect is cancelled (core.input.cancel_buff). On a core before
--        2026-10-06 Forever has no UnitBuff for the native to find it with,
--        so there it stays until it is clicked off the buff bar, and the
--        window says so. From that core on it is cancelled there too (JCore
--        1.9.0 lets the call through once the core can do it).
-- One aspect at a time, as in the game: sliding one on slides the other off.
--
-- THE SWITCHES FOLLOW THE GAME
-- An aspect picked from the action bar slides its own switch on. One clicked
-- off the buff bar while alive slides it off. The window never fights a
-- choice made outside it; it only keeps the choice standing.
--
-- THE ONE EXCEPTION: OUT OF CHEETAH BEFORE THE HIT (1.50.0)
-- Hit while in Cheetah and you are dazed; hit while in Pack and so is every
-- party member who was hit. When something is about to land -- a mob on you
-- that is in melee or reaches you before a swap could, a cast at you, a
-- missile in flight at you, a mob shooting at you from where it stands --
-- the switch moves for you, to the aspect you last fought in (Hawk, else
-- Monkey), and the cast goes out at once. The reaction engine makes that call
-- ("Out of Cheetah before the hit", react/rules/hunter.lua) with M.incoming
-- and M.switch_to; while the engine is not running -- the rotation off, its
-- key up, or mounted -- the keeper below makes the same call from the same
-- rows. A mob you are outrunning is not a hit: Cheetah stays while the gap
-- grows.
--
-- ONLY WITH AUTO SWAP ASPECTS ON (1.7.6). The user, 2026-10-10: "the option
-- to Auto Swap Aspect should be a thing if its not enabled it should not
-- swap any aspects at all". The switch sits under the aspect switches in the
-- Hunter window (and on the Rotation page, rot_hunter_auto_aspect), off by
-- default. Off, neither the reaction nor the keeper's guard moves an aspect:
-- Cheetah stays up through the hit. The switch you slid on is still put back
-- after a death or a dismount -- that is keeping your choice, not a swap.
--
-- WHY THE ROWS HAVE NO ICONS
-- A JCore window's body is a solid fill and the loader paints textures
-- beneath every shape, so an icon inside it would be hidden (timeline.lua
-- explains). Switches and text are shapes, which is all this needs.

return function(P)
    local ctx, log = P.ctx, P.log
    local units = P.units
    local book = P.spellbook

    local M = {}

    local floor, huge = math.floor, math.huge

    -- Every aspect a Classic hunter trains, in the order the window lists
    -- them. Only the trained ones get a row.
    local ASPECTS = {
        { name = "Aspect of the Hawk", short = "Hawk",
          tip = "+ranged attack power. The aspect to shoot in." },
        { name = "Aspect of the Monkey", short = "Monkey",
          tip = "+dodge. For a fight stuck in melee." },
        { name = "Aspect of the Cheetah", short = "Cheetah",
          tip = "+30% run speed. Dazed when hit -- switched out of when a hit is coming." },
        { name = "Aspect of the Pack", short = "Pack",
          tip = "+30% run speed for the party. Dazed when hit -- switched out of when a hit is coming." },
        { name = "Aspect of the Wild", short = "Wild",
          tip = "+nature resistance for the party." },
        { name = "Aspect of the Beast", short = "Beast",
          tip = "Untrackable by Track Humanoids." },
    }
    local BY_NAME = {}
    for i = 1, #ASPECTS do BY_NAME[ASPECTS[i].name] = ASPECTS[i] end

    -- Hit while in one of these and you are dazed.
    local CHEETAH, PACK = "Aspect of the Cheetah", "Aspect of the Pack"
    local TRAVEL = { [CHEETAH] = true, [PACK] = true }
    local TRAVEL_ORDER = { CHEETAH, PACK }
    -- What to leave one for when nothing better is known.
    local FIGHT_ORDER = { "Aspect of the Hawk", "Aspect of the Monkey" }

    local TICK = 0.1
    local GONE_AFTER = 1.5      -- missing this long while alive: it was clicked off
    local RESEND = 2.0          -- after a cast went out, this long for the aura to show
    local STUCK_AFTER = 1.5     -- slid off and still up this long: the cancel did nothing
    local NOTE_FOR = 6.0
    local PRIORITY = (ctx.PRIORITY and ctx.PRIORITY.UTILITY) or 100
    local GUARD_PRIORITY = (ctx.PRIORITY and ctx.PRIORITY.DEFENSIVE) or 200

    -- The guard's timings. A swap lands one round trip after it is sent,
    -- and not before the global cooldown is over.
    local LEAD = 1.0            -- seconds a swap needs, on top of the global cooldown left
    local MISSILE_LEAD = 2.5    -- a missile aimed at you is a hit; this far out it counts
    local MELEE = 5.5           -- yards: in reach of a swing
    local SHOOTER_AFTER = 0.6   -- on you, standing still, this long: it attacks from range
    local REACT_QUIET = 0.35    -- the engine asked this recently: the keeper's guard stands aside
    local AUTO_SWAP = "rot_hunter_auto_aspect"  -- the hunter's setting (classes/hunter.lua)

    local trained = {}          -- the ASPECTS rows this character knows
    local by_id = {}            -- spell id of any trained rank -> aspect name
    local wanted = nil          -- the aspect whose switch is on
    local released, released_at = nil, 0   -- slid off or being replaced: up, not followed
    local seen_up = false       -- wanted has been up since it was chosen (or since the last death)
    local missing_since = nil
    local sent_name, sent_at = nil, -huge
    local up_name = nil         -- what was up at the last tick
    local last_fight = nil      -- the last aspect up that was not a travel aspect
    local status = ""
    local note, note_until = nil, 0
    local flash, flash_until = nil, 0
    local shown = false
    local react_asked_at = -huge
    local on_me_since = {}      -- guid -> when it was first seen on us, for the shooter test

    local function rebuild()
        trained, by_id = {}, {}
        for i = 1, #ASPECTS do
            local a = ASPECTS[i]
            if book.known(a.name) then
                trained[#trained + 1] = a
                local ids = book.ids(a.name) or {}
                for j = 1, #ids do by_id[ids[j]] = a.name end
            end
        end
    end
    ctx.on("jambix.aio.spellbook_refreshed", rebuild)
    rebuild()

    -- --- the choice, kept per character ------------------------------------

    local store = ctx.store and ctx.store("aspects") or nil
    local loaded_for = nil

    local function ask(unit, method)
        local fn = unit and unit[method]
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, unit)
        if ok then return v end
        return nil
    end

    local function save()
        if not store or not loaded_for then return end
        if type(store.data.wanted) ~= "table" then store.data.wanted = {} end
        store.data.wanted[loaded_for] = wanted or false
        store:touch()
    end

    local function load_for(player)
        local guid = ask(player, "get_guid")
        if guid == nil then return end
        local key = tostring(guid)
        if key == loaded_for then return end
        loaded_for = key
        local saved = store and type(store.data.wanted) == "table" and store.data.wanted[key] or nil
        wanted = (type(saved) == "string" and BY_NAME[saved]) and saved or nil
        seen_up, missing_since, released = false, nil, nil
    end

    local function set_wanted(name)
        if wanted == name then return end
        wanted = name
        seen_up, missing_since = false, nil
        save()
    end

    -- --- reading the player ----------------------------------------------------

    local function aura_up(player, name)
        local ids = book.ids(name)
        return ids ~= nil and units.has_aura(player, ids) == true
    end

    --- The trained aspect that is up, or nil.
    local function aspect_up(player)
        for i = 1, #trained do
            if aura_up(player, trained[i].name) then return trained[i].name end
        end
        return nil
    end

    local function dead(player)
        return ask(player, "is_dead") == true or ask(player, "is_ghost") == true
    end

    --- Why the aspect cannot go up right now, or nil when it can.
    local function hold_reason(player, name)
        if P.master_on and not P.master_on() then return "the plugin is switched off" end
        if dead(player) then return "dead" end
        if ask(player, "is_mounted") == true then return "mounted" end
        -- A cast stands you up from Feign Death and from food.
        if aura_up(player, "Feign Death") then return "feigning death" end
        if P.rest and P.rest.consuming and P.rest.consuming() then return "eating or drinking" end
        local cp = ctx.player
        if cp and cp.casting_spell_id then
            local ok, id = pcall(cp.casting_spell_id)
            if ok and type(id) == "number" and id > 0 then return "casting" end
        end
        if not book.ready(name) then return "not ready (cooldown or mana)" end
        return nil
    end

    --- Cancels the named aspect on the player. Passes back the very row
    --- get_buffs() handed out, as the native requires (game_object.lua).
    local function cancel(name)
        local player = units.player()
        local input = ctx.input
        if not player or not input or type(input.cancel_buff) ~= "function" then return false end
        local ids = book.ids(name)
        if not ids then return false end
        local want = {}
        for i = 1, #ids do want[ids[i]] = true end
        local ok, buffs = pcall(player.get_buffs, player)
        if not ok or type(buffs) ~= "table" then return false end
        for i = 1, #buffs do
            local row = buffs[i]
            if type(row) == "table" and want[row.buff_id] then
                local ok_c, res = pcall(input.cancel_buff, row)
                return ok_c and res ~= false
            end
        end
        return false
    end

    local function gcd_left()
        local spells = ctx.spells
        if not spells or not spells.gcd then return 0 end
        local ok, v = pcall(spells.gcd)
        return (ok and type(v) == "number" and v > 0) and v or 0
    end

    -- --- the switches ---------------------------------------------------------

    --- Slides `name` on. Whatever aspect is up now is to be replaced, not
    --- followed back.
    ---@param name string
    ---@return boolean
    function M.choose(name)
        if not BY_NAME[name] then return false end
        local player = units.player()
        if player then load_for(player) end
        if up_name and up_name ~= name then
            released, released_at = up_name, core.time()
        elseif up_name == name then
            released = nil
        end
        set_wanted(name)
        if up_name == name then seen_up = true end
        note, flash = nil, nil
        log.fmt("debug", "aspect: %s switched on", BY_NAME[name].short)
        return true
    end

    --- Slides `name` off: cancelled when it is up, and nothing replaces it.
    ---@param name string
    function M.release(name)
        if not BY_NAME[name] then return false end
        local player = units.player()
        if player then load_for(player) end
        if wanted == name then set_wanted(nil) end
        note, flash = nil, nil
        if up_name == name then
            released, released_at = name, core.time()
            cancel(name)
        end
        log.fmt("debug", "aspect: %s switched off", BY_NAME[name].short)
        return true
    end

    ctx.on("jcore.cast.sent", function(request)
        if type(request) ~= "table" or type(request.spell_id) ~= "number" then return end
        if ctx.id and request.owner and request.owner ~= ctx.id then return end
        local name = by_id[request.spell_id]
        if name then sent_name, sent_at = name, core.time() end
    end)

    -- --- out of Cheetah before the hit ----------------------------------------

    --- May an aspect be swapped for you? Auto swap aspects, off by default.
    ---@return boolean
    function M.auto_swap_on()
        return P.opt ~= nil and P.opt(AUTO_SWAP, false) == true
    end

    --- Writes Auto swap aspects where the menu keeps it (the Rotation page),
    --- as the class window writes its options.
    local function set_auto_swap(on)
        local page = P.pages and P.pages.rotation
        if page and page.set then pcall(page.set, page, AUTO_SWAP, on == true) end
        if P.opt_invalidate then P.opt_invalidate() end
    end

    --- The travel aspect that is up (Cheetah or Pack), read now, or nil.
    ---@return string|nil
    function M.travel_up()
        local player = units.player()
        if not player then return nil end
        for i = 1, #TRAVEL_ORDER do
            local name = TRAVEL_ORDER[i]
            if book.known(name) and aura_up(player, name) then return name end
        end
        return nil
    end

    --- The aspect to leave a travel aspect for: the one you last fought in,
    --- else Hawk, else Monkey -- whichever is trained.
    ---@return string|nil
    function M.fight_aspect()
        if last_fight and not TRAVEL[last_fight] and book.known(last_fight) then return last_fight end
        for i = 1, #FIGHT_ORDER do
            if book.known(FIGHT_ORDER[i]) then return FIGHT_ORDER[i] end
        end
        return nil
    end

    local function who(row)
        if row and row.obj and units.name then
            local ok, name = pcall(units.name, row.obj)
            if ok and type(name) == "string" and name ~= "" then return name end
        end
        return "a mob"
    end

    --- Is a hit about to land while a travel aspect is up? Seconds until it
    --- does and why, or nil when nothing is. Read from JCore's enemies rows
    --- (the ones the reaction world carries; JCore's own list by default) and
    --- the missiles in flight -- no reads of its own beyond a name for the
    --- answer.
    ---
    --- In Pack a mob on any party member counts too: they are dazed as well.
    ---@param travel string the travel aspect that is up
    ---@param rows? table[] enemy rows
    ---@param n? integer how many of them
    ---@param gcd? number the global cooldown left
    ---@return number|nil seconds
    ---@return string|nil why
    function M.incoming(travel, rows, n, gcd)
        local now = core.time()
        local lead = LEAD + math.max(0, tonumber(gcd) or gcd_left())
        local best, best_row, best_kind = nil, nil, nil
        local function consider(eta, row, kind)
            if eta <= lead and (not best or eta < best) then best, best_row, best_kind = eta, row, kind end
        end

        local enemies = ctx.enemies
        if not rows then
            rows = (enemies and enemies.all and enemies.all()) or {}
            n = #rows
        end
        n = n or #rows

        local world = P.react and P.react.world
        local in_group = travel == PACK and world and world.in_group or nil
        local seen = {}
        for i = 1, n do
            local r = rows[i]
            if r and r.guid and r.activity ~= "dead" and not r.control then
                local on_me = r.targeting_me == true
                local on_us = on_me or (in_group ~= nil and r.target_guid ~= nil and in_group(r.target_guid))
                if on_us then
                    seen[r.guid] = true
                    on_me_since[r.guid] = on_me_since[r.guid] or now
                    local dist = r.dist or huge
                    local reach = r.time_to_reach or huge
                    if not on_me then
                        -- Pack: a mob in a fight with a party member near you.
                        if r.in_combat and dist <= 40 then consider(0, r, "party") end
                    elseif dist <= MELEE then
                        consider(0, r, "melee")
                    else
                        if reach < huge then consider(reach, r, "closing") end
                        -- A cast at you lands wherever you run to.
                        if r.casting then
                            consider(math.min(lead, tonumber(r.casting.remaining) or 0), r, "casting")
                        end
                        -- On you, in the fight, standing still and not closing:
                        -- it attacks from where it is. Not a mob still finding
                        -- its feet -- a moment's look first -- and never one
                        -- that is moving: that one is chasing, and is either
                        -- closing (above) or being outrun.
                        if r.in_combat and not r.moving and reach == huge
                            and (now - on_me_since[r.guid]) >= SHOOTER_AFTER then
                            consider(lead, r, "shooting")
                        end
                    end
                end
            end
        end
        for guid in pairs(on_me_since) do
            if not seen[guid] then on_me_since[guid] = nil end
        end

        local missiles = ctx.missiles
        if missiles and missiles.incoming and missiles.time_to_impact then
            local ok, list = pcall(missiles.incoming)
            if ok and type(list) == "table" then
                for i = 1, #list do
                    local m = list[i]
                    local caster = m and (m.caster or m.source)
                    local hostile = caster and enemies and enemies.get and enemies.get(caster) or nil
                    if hostile then
                        local ok_t, eta = pcall(missiles.time_to_impact, m)
                        if ok_t and type(eta) == "number" and eta <= MISSILE_LEAD and (not best or eta < best) then
                            best, best_row, best_kind = eta, hostile, "missile"
                        end
                    end
                end
            end
        end

        if not best then return nil, nil end
        local name = who(best_row)
        local why
        if best_kind == "melee" then
            why = name .. " is in melee"
        elseif best_kind == "closing" then
            why = string.format("%s reaches you in %.1fs", name, best)
        elseif best_kind == "casting" then
            why = name .. " is casting at you"
        elseif best_kind == "shooting" then
            why = name .. " is attacking you from range"
        elseif best_kind == "missile" then
            why = string.format("%s's missile lands in %.1fs", name, best)
        else
            why = name .. " is on your party"
        end
        return best, why
    end

    --- Why `name` cannot go up in place of a travel aspect right now, or nil.
    ---@param name string
    ---@return string|nil
    function M.can_switch(name)
        if not M.auto_swap_on() then return "Auto swap aspects is off" end
        if not BY_NAME[name] or not book.known(name) then return "not trained" end
        local player = units.player()
        if not player then return "no player" end
        if aura_up(player, name) then return "already up" end
        if wanted == name and sent_name == name and (core.time() - sent_at) < RESEND then
            return "already on its way"
        end
        return hold_reason(player, name)
    end

    --- Puts `name` up in place of the travel aspect: its switch on, the
    --- travel aspect's off, the cast sent at once. The reaction engine's
    --- action for "Out of Cheetah before the hit", and the keeper's own guard.
    ---@param name string
    ---@param why string
    ---@param priority? number
    ---@return boolean sent
    function M.switch_to(name, why, priority)
        if not M.auto_swap_on() then return false end
        if not BY_NAME[name] or not book.known(name) then return false end
        local player = units.player()
        if not player then return false end
        load_for(player)
        local id = book.id(name)
        if not id then return false end
        local from = aspect_up(player)
        up_name = from
        if from and from ~= name then released, released_at = from, core.time() end
        set_wanted(name)
        ctx.cast({
            spell_id = id,
            target = player,
            priority = priority or GUARD_PRIORITY,
            reason = "aspect: " .. BY_NAME[name].short .. " (" .. tostring(why) .. ")",
        })
        local left = from and BY_NAME[from] and BY_NAME[from].short or "travel"
        flash, flash_until = string.format("Out of %s: %s.", left, tostring(why)), core.time() + NOTE_FOR
        log.fmt("info", "aspect: out of %s into %s -- %s", left, BY_NAME[name].short, tostring(why))
        return true
    end

    --- The reaction engine says it is watching; the keeper's guard stands
    --- aside while it does.
    function M.react_watching()
        react_asked_at = core.time()
    end

    -- --- keeping the choice up ------------------------------------------------

    local function tick()
        if #trained == 0 or P.esp_only then status = "" return end
        local player = units.player()
        if not player then return end
        load_for(player)
        local now = core.time()
        local up = aspect_up(player)
        up_name = up
        if up and not TRAVEL[up] then last_fight = up end

        if released and up ~= released then released = nil end

        -- Ours, sent before the switch moved on: replaced, not followed --
        -- and cancelled when the switch it was sent for is now off.
        if up and up ~= wanted and up ~= released and up == sent_name and (now - sent_at) < RESEND + 1 then
            released, released_at = up, now
            if not wanted then cancel(up) end
        end

        -- Picked from the action bar: the switches follow.
        if up and up ~= wanted and up ~= released then
            set_wanted(up)
            seen_up = true
        end

        -- Out of Cheetah before the hit, while the reaction engine is not
        -- the one watching (the rotation off, its key up, or mounted), and
        -- only with Auto swap aspects on.
        if up and TRAVEL[up] and wanted == up and (now - react_asked_at) > REACT_QUIET and M.auto_swap_on() then
            local eta, why = M.incoming(up)
            local to = eta and M.fight_aspect() or nil
            if to and not M.can_switch(to) then
                M.switch_to(to, why, GUARD_PRIORITY)
                status = flash
                return
            end
        end

        if not wanted then
            if released and up == released and (now - released_at) >= STUCK_AFTER then
                status = BY_NAME[released].short .. " is still up: click it off the buff bar."
            elseif note and now < note_until then
                status = note
            else
                status = "No aspect. Slide one on."
            end
            return
        end

        local short = BY_NAME[wanted].short
        local flashing = flash and now < flash_until
        if up == wanted then
            seen_up, missing_since = true, nil
            status = flashing and flash or (short .. " is up.")
            return
        end

        if seen_up then
            if dead(player) or ask(player, "is_mounted") == true then
                -- A death takes every buff; it goes back up afterwards.
                seen_up, missing_since = false, nil
            else
                missing_since = missing_since or now
                if (now - missing_since) < GONE_AFTER then return end
                -- Clicked off the buff bar: its switch follows.
                note, note_until = short .. " was clicked off.", now + NOTE_FOR
                set_wanted(nil)
                status = note
                return
            end
        end

        if (now - sent_at) < RESEND and sent_name == wanted then
            status = flashing and flash or ("Casting " .. short .. "...")
            return
        end
        local why = hold_reason(player, wanted)
        if why then
            status = short .. ": waiting, " .. why .. "."
            return
        end
        local id = book.id(wanted)
        if not id then return end
        ctx.cast({
            spell_id = id,
            target = player,
            priority = PRIORITY,
            reason = "aspect: " .. short,
        })
        status = flashing and flash or ("Casting " .. short .. "...")
    end

    ctx.tick(tick, { interval = TICK })
    M._tick = tick

    -- --- the window -------------------------------------------------------------

    local WINDOW_ID = "aspects"
    local WIDTH = 200

    local function body(ui, win)
        for i = 1, #trained do
            local a = trained[i]
            local id = "aspect_" .. a.short
            -- The switch shows the choice, whatever its stored value says.
            ui:set(win or WINDOW_ID, id, wanted == a.name)
            local on, flipped = ui:toggle(id, a.short, false, { tooltip = a.tip })
            if flipped then
                if on then M.choose(a.name) else M.release(a.name) end
            end
        end
        -- 1.7.6: the one swap made for you, only when this is on.
        local auto = M.auto_swap_on()
        ui:set(win or WINDOW_ID, "aspect_auto_swap", auto)
        local on, flipped = ui:toggle("aspect_auto_swap", "Auto swap aspects", auto, {
            tooltip = "On: out of Cheetah or Pack into the aspect you last fought in (Hawk, else Monkey) "
                .. "just before a hit would daze you. Off: no aspect is ever swapped for you; "
                .. "the one switched on above is kept up.",
        })
        if flipped then set_auto_swap(on) end
        if status ~= "" then ui:text(status, { color = "text_dim", size = "small" }) end
    end

    -- WHY IT IS NOT ON SCREEN (1.61.3). The user, 2026-10-04: "that UI for
    -- aspect i dont see it on forever when i turn it on". Each way the window
    -- stays away has its reason, kept for stats() and, when it changes, put in
    -- the recorder's trace (Forever with Jambix Debug), so one session says
    -- which: nothing trained, switched off, the plugin's master off, no UI,
    -- or the window call itself refusing (with its error).
    local hidden_why = nil
    local function hidden(why)
        if why == hidden_why then return end
        hidden_why = why
        local client = ctx.world and ctx.world.client and ctx.world.client() or nil
        if client and client.recording then
            local names = {}
            for i = 1, #trained do names[i] = trained[i].short end
            pcall(ctx.emit, "jcore.recorder.trace", string.format("aspects: window %s (trained: %s)",
                why and ("not shown: " .. why) or "shown", #names > 0 and table.concat(names, ", ") or "none"))
        end
    end

    function M.render()
        shown = false
        if #trained == 0 then return hidden("no aspect trained (the spellbook names none)") end
        if P.esp_only then return hidden("ESP-only client") end
        if not P.opt("aspect_window", true) then return hidden("switched off on the Rotation page") end
        if P.master_on and not P.master_on() then return hidden("the plugin's master switch is off") end
        local ui = ctx.ui
        if not (ui and ui.begin_window and ui.toggle and ui.set) then return hidden("JCore's UI has no window calls") end

        local sw, sh = 1920, 1080
        local draw = P.draw
        if draw and draw.screen_size then
            local w, h = draw.screen_size()
            if w and w > 0 and h and h > 0 then sw, sh = w, h end
        end

        -- Default spot: left of centre, the spell window's mirror. Dragged
        -- by its title bar and remembered by JCore after that.
        local ok, open = pcall(ui.begin_window, ui, WINDOW_ID, {
            title = "Aspects", x = floor(sw * 0.285 - WIDTH / 2), y = floor(sh * 0.62),
            w = WIDTH, min_w = WIDTH, collapsible = true, closable = false, scroll = false,
        })
        if ok and open then
            shown = true
            local ok_body, err = pcall(body, ui)
            if not ok_body then
                log.once("error", "aspects_window", "Aspects window failed: " .. tostring(err))
                hidden("its body raised: " .. tostring(err))
            else
                hidden(nil)
            end
        elseif not ok then
            hidden("begin_window raised: " .. tostring(open))
        else
            hidden("begin_window answered closed (collapsed, or hidden by JCore)")
        end
        -- ALWAYS paired, whatever begin answered.
        pcall(ui.end_window, ui)
    end

    --- The switches and the status line, drawn inside another window: the
    --- Hunter window (modules/classwin.lua, 1.62.0) holds them now.
    ---@param ui table JCore's UI, inside an open window
    ---@param win string that window's id, for ui:set
    function M.draw(ui, win)
        shown = true
        body(ui, win)
    end

    --- For the tests and the Debug page.
    function M.stats()
        local names = {}
        for i = 1, #trained do names[i] = trained[i].short end
        return {
            trained = names,
            wanted = wanted,
            up = up_name,
            released = released,
            status = status,
            shown = shown,
            hidden_why = hidden_why,
            last_fight = last_fight,
            auto_swap = M.auto_swap_on(),
        }
    end

    return M
end

-- Jambix AIO / classwin -- every class's own window (1.62.0).
--
-- The user, 2026-10-04: "let's reorganize all the menus!! each class should
-- have its own UI for things like Hunter does for aspects!" -- and, asked what
-- such a window holds: both the buffs switched by hand and the class's
-- options with a live status. This is the window and its buffs, stances and
-- forms; what each class has is in modules/classwin_data.lua.
--
-- THREE KINDS OF GROUP
--   pick   one of a set: an aura, a seal, a blessing on yourself, an armor, a
--          shield. "Auto" (the default where offered) is what happened before
--          this window: the rotation decides, and the window keeps nothing. A
--          spell picked here is kept up -- put back whenever it goes missing --
--          and the rotation casts none of the set any more. "None" keeps none
--          up, and the rotation casts none either.
--   keep   one buff, on or off: Battle Shout, Inner Fire, Fortitude, Arcane
--          Intellect, Mark of the Wild. On -- the default where the rotation
--          kept it up -- keeps it up; off leaves it alone. Either way the
--          rotation no longer casts it on you: the window owns it.
--   form   a stance or a form, picked with Auto: the pick is what the
--          rotation's form keeper (forms.lua) holds instead of the profile's.
--
-- WHEN THE WINDOW ACTS. A choice nobody made -- a default -- acts only while
-- the rotation runs, which is exactly when the rotation used to cast these;
-- a player who never opens the window sees no change. A choice made in the
-- window acts while the rotation runs, and while it is paused or off as the
-- shared setting `classwin_paused` says (1.7.5):
--   1 Out-of-combat buffs (the default): out of combat only, and never a
--     `fight` group (the seal) or a stance or form.
--   2 Everything picked here: whenever the plugin is on, as before 1.7.5.
--   3 Nothing.
-- A player asked for "a setting to stop auto applying seal even when rota is
-- paused": a seal lasts half a minute, so a picked one was put back twice a
-- minute in town, and a shield or a shout went out in the middle of a fight
-- being played by hand. "Runs" is the rotation's own test: Enable rotation
-- on and its key active.
--
-- THE GAME LEADS, as in the Aspects window. A member of a picked set put up
-- from the action bar becomes the pick. A buff that vanishes out of combat
-- with time still on it was clicked off, and its switch follows (a seal
-- judged or a shield's charges used up is not that: "consumed"). Anything
-- that runs out is put back. A stance or form held while the rotation is
-- paused is let go once you take another yourself (1.7.5): it was put back
-- every 1.2 s, a druid shifting to heal or to travel included. Held again
-- after a death or a mount, once the rotation has run, or picked again.
--
-- The hunter's window holds the Aspects switches (modules/aspects.lua keeps
-- them, as it always has) above its own groups.
--
-- OPTIONS AND STATUS (1.63.0). Under the groups, the class's settings: its
-- own (the hunter's kiting, the rogue's stealth, the warlock's stones) and
-- the shared ones its class module says it can use (threat, stances, wand,
-- healing, pet). They are the menu's settings: read with P.opt and written to
-- the Rotation page, so the menu and the window always agree. On top, one
-- line, under the switches: the rotation on or off, the profile, the
-- stance or form.
--
-- A section with no capability flag is every class's: Group (1.70.0), with
-- "Assist the tank" and a live line from modules/assist.lua under it.

local GONE_AFTER = 1.0      -- s missing before a click-off is believed
local CLICKED_LEFT = 3.0    -- s it still had: more than this and it was clicked off
local RESEND = 2.5          -- s after a cast for its aura to show
local GAP = 0.5             -- s between two casts of the window's
local TICK = 0.2
local WIDTH = 230
local WINDOW_ID = "class_window"
local STEALTHY = { "Stealth", "Prowl", "Shadowmeld", "Vanish", "Feign Death" }

return function(P, DATA)
    local ctx, log = P.ctx, P.log
    local units = P.units
    local book = P.spellbook

    local M = {}

    local cls = nil             -- this class's entry in DATA
    local class_file = nil      -- "WARRIOR", ...
    local OPTIONS = DATA.OPTIONS or {}
    local groups = {}           -- { def, members } with trained members only
    local owned = {}            -- spell name -> true: the rotation leaves it alone
    local status = ""
    local shown = false
    local hidden_why = nil

    -- --- the choices, kept per character ------------------------------------

    local store = ctx.store and ctx.store("classwin") or nil
    local loaded_for = nil
    local picks, keeps, touched = {}, {}, {}

    local function ask(unit, method)
        local fn = unit and unit[method]
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, unit)
        if ok then return v end
        return nil
    end

    local function save()
        if not store or not loaded_for then return end
        if type(store.data.chars) ~= "table" then store.data.chars = {} end
        store.data.chars[loaded_for] = { picks = picks, keeps = keeps, touched = touched }
        store:touch()
    end

    local recompute_owned

    local function load_for(player)
        local guid = ask(player, "get_guid")
        if guid == nil then return end
        local key = tostring(guid)
        if key == loaded_for then return end
        loaded_for = key
        local saved = store and type(store.data.chars) == "table" and store.data.chars[key] or nil
        picks = (saved and type(saved.picks) == "table") and saved.picks or {}
        keeps = (saved and type(saved.keeps) == "table") and saved.keeps or {}
        touched = (saved and type(saved.touched) == "table") and saved.touched or {}
        recompute_owned()
    end

    --- The group's pick: "Auto", "None", or a spell name.
    local function pick_of(def)
        local v = picks[def.key]
        if type(v) == "string" then return v end
        return def.auto and "Auto" or "None"
    end

    --- Is this kept buff switched on?
    local function keep_of(spell)
        local v = keeps[spell.name]
        if v == nil then return spell.default == true end
        return v == true
    end

    function recompute_owned()
        owned = {}
        if not cls then return end
        for _, def in ipairs(cls.groups or {}) do
            if def.kind == "keep" then
                for _, sp in ipairs(def.spells) do owned[sp.name] = true end
            elseif pick_of(def) ~= "Auto" then
                for _, sp in ipairs(def.spells) do owned[sp.name] = true end
            end
        end
    end

    --- The rotation's gate: true when this spell is the window's to keep.
    ---@param name string
    ---@return boolean
    function M.owns(name)
        return owned[name] == true
    end

    --- The stance or form picked here, or nil for Auto (the profile's).
    ---@return string|nil
    function M.form_choice()
        for _, g in ipairs(groups) do
            if g.def.kind == "form" then
                local v = pick_of(g.def)
                if v ~= "Auto" and v ~= "None" then return v end
            end
        end
        return nil
    end

    -- --- the class and what is trained ---------------------------------------

    local function detect()
        local rot = P.rotation
        local ok, name = pcall(function() return rot and rot.detect_class and rot.detect_class() end)
        return ok and name or nil
    end

    local function rebuild()
        local name = detect()
        class_file = name
        cls = name and name ~= "OPTIONS" and DATA[name] or nil
        groups = {}
        if cls then
            for _, def in ipairs(cls.groups or {}) do
                local members = {}
                for _, sp in ipairs(def.spells) do
                    if book.known(sp.name) then members[#members + 1] = sp end
                end
                if #members > 0 then groups[#groups + 1] = { def = def, members = members } end
            end
        end
        recompute_owned()
    end
    ctx.on("jambix.aio.spellbook_refreshed", rebuild)
    ctx.on("jambix.aio.class_detected", rebuild)
    rebuild()

    --- Makes a choice, as the player does in the window.
    ---@param key string group key
    ---@param value string "Auto", "None" or a spell name
    function M.choose(key, value)
        local player = units.player()
        if player then load_for(player) end
        picks[key] = value
        touched[key] = true
        recompute_owned()
        save()
    end

    ---@param name string spell
    ---@param on boolean
    function M.set_keep(name, on)
        local player = units.player()
        if player then load_for(player) end
        keeps[name] = on and true or false
        touched[name] = true
        recompute_owned()
        save()
    end

    -- --- keeping them up -------------------------------------------------------

    local function aura_up(player, name)
        local ids = book.ids(name)
        return ids ~= nil and units.has_aura(player, ids) == true
    end

    local function aura_left(player, name)
        local ids = book.ids(name)
        if not ids or not units.aura_remaining then return 0 end
        local ok, v = pcall(units.aura_remaining, player, ids)
        return (ok and type(v) == "number") and v or 0
    end

    local function dead(player)
        return ask(player, "is_dead") == true or ask(player, "is_ghost") == true
    end

    local function in_combat(player)
        return ask(player, "is_in_combat") == true
    end

    --- Why `spell` cannot go up right now, or nil when it can.
    local function hold_reason(player, spell, def)
        if dead(player) then return "dead" end
        if ask(player, "is_mounted") == true then return "mounted" end
        for i = 1, #STEALTHY do
            if aura_up(player, STEALTHY[i]) then return STEALTHY[i]:lower() .. " is up" end
        end
        if P.rest and P.rest.consuming and P.rest.consuming() then return "eating or drinking" end
        local cp = ctx.player
        if cp and cp.casting_spell_id then
            local ok, id = pcall(cp.casting_spell_id)
            if ok and type(id) == "number" and id > 0 then return "casting" end
        end
        local combat_ok = spell.combat
        if combat_ok == nil then combat_ok = def.combat end
        if combat_ok == false and in_combat(player) then return "out of combat only" end
        if not book.ready(spell.name) then return "not ready (cooldown or mana)" end
        return nil
    end

    --- Is the rotation running? Its own test (rotation.tick): Enable rotation
    --- on and its key active. The key alone read as running with the
    --- rotation switched off, when nothing held a picked form either.
    local function running()
        if not P.opt("rot_enabled", false) then return false end
        return P.rotation_active ~= nil and P.rotation_active() == true
    end

    -- What the window keeps while the rotation is paused or off (1.7.5).
    local PAUSED_OOC, PAUSED_ALL, PAUSED_NONE = 1, 2, 3

    --- Acts for this choice now? A default only while the rotation runs; a
    --- choice made in the window also while it is paused, as the setting says.
    local function acting(key, def, player)
        if P.master_on and not P.master_on() then return false end
        if running() then return true end
        if not touched[key] then return false end
        local mode = tonumber(P.opt("classwin_paused", PAUSED_OOC)) or PAUSED_OOC
        if mode == PAUSED_ALL then return true end
        if mode == PAUSED_NONE then return false end
        if def and (def.fight or def.kind == "form") then return false end
        return not in_combat(player)
    end

    local seen = {}             -- spell -> { up, left, missing_since }
    local sent_name, sent_at = nil, -1e9
    local last_cast = -1e9

    ctx.on("jcore.cast.sent", function(request)
        if type(request) ~= "table" or type(request.spell_id) ~= "number" then return end
        if ctx.id and request.owner and request.owner ~= ctx.id then return end
        for _, g in ipairs(groups) do
            for _, sp in ipairs(g.members) do
                local ids = book.ids(sp.name) or {}
                for i = 1, #ids do
                    if ids[i] == request.spell_id then sent_name, sent_at = sp.name, core.time() end
                end
            end
        end
    end)

    --- Puts `spell` up. True when a cast went out.
    local function cast(player, spell, def, now)
        if (now - last_cast) < GAP then return false end
        if sent_name == spell.name and (now - sent_at) < RESEND then return false end
        local why = hold_reason(player, spell, def)
        if why then
            status = spell.short .. ": waiting, " .. why .. "."
            return false
        end
        local id = book.id(spell.name)
        if not id then return false end
        last_cast = now
        sent_name, sent_at = spell.name, now
        ctx.cast({ spell_id = id, target = player, priority = ctx.PRIORITY.UTILITY,
            reason = "class window: " .. spell.name })
        status = "Casting " .. spell.short .. "..."
        return true
    end

    --- Follows one buff that went missing: "clicked" when it was clicked off,
    --- "waiting" while that is being decided, nil when it simply needs
    --- putting back (it ran out, was used up, was lost to a death).
    local function clicked_off(player, spell, def, up, now)
        local st = seen[spell.name] or {}
        seen[spell.name] = st
        if up then
            st.up, st.left, st.missing_since = true, aura_left(player, spell.name), nil
            return nil
        end
        if not st.up then return nil end
        if def.consumed or spell.consumed or dead(player) or in_combat(player)
            or ask(player, "is_mounted") == true or (st.left or 0) <= CLICKED_LEFT then
            st.up, st.missing_since = false, nil
            return nil
        end
        st.missing_since = st.missing_since or now
        if (now - st.missing_since) < GONE_AFTER then return "waiting" end
        st.up, st.missing_since = false, nil
        return "clicked"
    end

    local function keep_pick(g, player, now)
        local def = g.def
        local choice = pick_of(def)
        if choice == "Auto" then return false end
        local up = nil
        for _, sp in ipairs(g.members) do
            if aura_up(player, sp.name) then up = sp break end
        end
        -- Put up from the action bar, not by us: the pick follows.
        if up and up.name ~= choice and not (sent_name == up.name and (now - sent_at) < RESEND + 1) then
            M.choose(def.key, up.name)
            return false
        end
        if choice == "None" then return false end
        local spell = nil
        for _, sp in ipairs(g.members) do if sp.name == choice then spell = sp end end
        if not spell then return false end
        local gone = clicked_off(player, spell, def, up ~= nil and up.name == choice, now)
        if gone == "waiting" then return false end
        if gone == "clicked" then
            status = spell.short .. " was clicked off."
            M.choose(def.key, "None")
            return false
        end
        if up and up.name == choice then return false end
        if not acting(def.key, def, player) then return false end
        return cast(player, spell, def, now)
    end

    local function keep_one(g, spell, player, now)
        if not keep_of(spell) then return false end
        local up = aura_up(player, spell.name)
        local gone = clicked_off(player, spell, g.def, up, now)
        if gone == "waiting" then return false end
        if gone == "clicked" then
            status = spell.short .. " was clicked off."
            M.set_keep(spell.name, false)
            return false
        end
        -- REFRESHED BEFORE IT RUNS OUT (1.80.0). A keep with `refresh` goes
        -- out again in its last seconds, as Battle Shout's tooltip always
        -- said; it was put back only once gone, and the rotation's own
        -- early refresh never ran, because this window owns the spell.
        if up then
            local left = spell.refresh and aura_left(player, spell.name) or 0
            if not (left > 0 and left < spell.refresh) then return false end
        end
        if not acting(spell.name, g.def, player) then return false end
        return cast(player, spell, g.def, now)
    end

    -- The pick seen held while the rotation is paused, and let go: the
    -- player took another form themselves (1.7.5).
    local form_held, form_let_go, form_for = false, false, nil

    --- A form picked here, held while the rotation is paused or off (while it
    --- runs, its own form keeper holds the pick), until you take another.
    local function keep_form(g, player)
        local choice = pick_of(g.def)
        if choice ~= form_for or running() then
            form_held, form_let_go, form_for = false, false, choice
        end
        if choice == "Auto" or choice == "None" then return false end
        if running() then return false end
        if not acting(g.def.key, g.def, player) or not P.forms then return false end
        -- A death or a mount drops a form, and a reload starts from none:
        -- put the pick back after them, as before.
        if dead(player) or ask(player, "is_mounted") == true then
            form_held, form_let_go = false, false
            return false
        end
        if P.forms.is(choice) then
            form_held = true
            return false
        end
        if form_held then form_let_go = true end
        if form_let_go then
            status = choice .. ": left as you set it until the rotation runs."
            return false
        end
        return P.forms.switch_to(choice, "class window") == true
    end

    local function tick()
        if not cls or P.esp_only then return end
        local player = units.player()
        if not player then return end
        load_for(player)
        local now = core.time()
        for _, g in ipairs(groups) do
            local kind = g.def.kind
            if kind == "pick" then
                if keep_pick(g, player, now) then return end
            elseif kind == "keep" then
                for _, sp in ipairs(g.members) do
                    if keep_one(g, sp, player, now) then return end
                end
            elseif kind == "form" then
                if keep_form(g, player) then return end
            end
        end
    end
    ctx.tick(tick, { interval = TICK })
    M._tick = tick
    M._rebuild = rebuild

    -- --- the window ---------------------------------------------------------------

    -- --- options -------------------------------------------------------------

    --- Does the rotation's class module have this capability?
    local function capable(flag)
        local rot = P.rotation
        local ok, c = pcall(function() return rot and rot.active_class and rot.active_class() end)
        return ok and type(c) == "table" and c[flag] == true
    end

    --- The option sections for this class: the shared ones first, its own last.
    local function option_sections()
        local out = {}
        for _, sec in ipairs(OPTIONS.common or {}) do
            if sec.flag == nil or capable(sec.flag) then out[#out + 1] = sec end
        end
        local own = class_file and OPTIONS[class_file]
        if type(own) == "table" and #own > 0 then
            out[#out + 1] = { label = (cls and cls.label or "Class") .. " options", rows = own }
        end
        return out
    end

    local BUTTONS = {
        pet_focus_target = function()
            if P.pet and P.combat then P.pet.set_focus(P.combat.target()) end
        end,
        pet_focus_clear = function()
            if P.pet then P.pet.set_focus(nil) end
        end,
    }

    --- Writes a setting where the menu keeps it (the Rotation page).
    local function write(id, value)
        local page = P.pages and P.pages.rotation
        if page and page.set then pcall(page.set, page, id, value) end
        if P.opt_invalidate then P.opt_invalidate() end
    end
    M._write = write

    -- A live line under an option, from the module that knows (1.70.0).
    local NOTES = {
        assist = function() return P.assist and P.assist.status and P.assist.status() or "" end,
        -- 1.7.6: the hunter's AOE melee weave (ALPHA/TEST).
        hunter_aoe = function()
            local rotation = P.rotation
            local class_module = rotation and rotation.active_class and rotation.active_class()
            local fn = class_module and class_module.aoe_status
            return type(fn) == "function" and fn() or ""
        end,
        -- 1.7.6: the PvP hunter (ALPHA/TEST).
        hunter_pvp = function()
            local rotation = P.rotation
            local class_module = rotation and rotation.active_class and rotation.active_class()
            local fn = class_module and class_module.pvp_status
            return type(fn) == "function" and fn() or ""
        end,
    }

    local function draw_option(ui, row)
        local wid = "opt_" .. row.id
        if row.kind == "note" then
            local fn = NOTES[row.id]
            local ok, text = true, ""
            if fn then ok, text = pcall(fn) end
            if ok and type(text) == "string" and text ~= "" then
                ui:text(text, { color = "text_dim", size = "small" })
            end
            return
        end
        if row.kind == "button" then
            if ui:button(wid, row.label) and BUTTONS[row.id] then BUTTONS[row.id]() end
            return
        end
        local current = P.opt(row.id, row.default)
        if row.kind == "toggle" then
            current = current == true
            ui:set(WINDOW_ID, wid, current)
            local v, changed = ui:toggle(wid, row.label, current, row.tip and { tooltip = row.tip } or nil)
            if changed then write(row.id, v == true) end
        elseif row.kind == "slider" then
            current = tonumber(current) or row.default
            ui:set(WINDOW_ID, wid, current)
            local v, changed = ui:slider(wid, row.label, row.min, row.max, current)
            if changed then write(row.id, v) end
        elseif row.kind == "dropdown" then
            current = tonumber(current) or row.default
            ui:set(WINDOW_ID, wid, current)
            local v, changed = ui:dropdown(wid, row.label, row.items, current, row.tip and { tooltip = row.tip } or nil)
            if changed then write(row.id, v) end
        end
    end

    --- The line on top: rotation on or off, the profile, the stance or form.
    local function status_line()
        local on = running()
        local w = {}
        local rot = P.rotation
        if rot and rot.stats then
            local ok, st = pcall(rot.stats)
            if ok and type(st) == "table" then w = st end
        end
        local form = P.forms and P.forms.current and P.forms.current() or nil
        return string.format("Rotation %s%s%s", on and "on" or "off",
            (w.label or w.profile) and (" - " .. tostring(w.label or w.profile)) or "",
            (form and form ~= "None") and (" - " .. form) or "")
    end
    M.status_line = status_line

    --- The dropdown rows for a pick or form group, and the index of the pick.
    local function options_of(g)
        local labels, values = {}, {}
        if g.def.auto then labels[#labels + 1], values[#values + 1] = "Auto", "Auto" end
        labels[#labels + 1], values[#values + 1] = "None", "None"
        for _, sp in ipairs(g.members) do labels[#labels + 1], values[#values + 1] = sp.short, sp.name end
        local current = pick_of(g.def)
        local index = 1
        for i = 1, #values do if values[i] == current then index = i end end
        return labels, values, index
    end

    local function body(ui)
        -- The hunter's aspects first, under the window's own title.
        if cls.aspects and P.aspects and P.aspects.draw then P.aspects.draw(ui, WINDOW_ID) end
        for _, g in ipairs(groups) do
            local def = g.def
            if def.kind == "keep" then
                ui:separator(def.label)
                for _, sp in ipairs(g.members) do
                    local id = "keep_" .. sp.name
                    ui:set(WINDOW_ID, id, keep_of(sp))
                    local on, flipped = ui:toggle(id, sp.short, keep_of(sp), { tooltip = sp.tip })
                    if flipped then M.set_keep(sp.name, on) end
                end
            else
                local labels, values, index = options_of(g)
                local id = "pick_" .. def.key
                ui:set(WINDOW_ID, id, index)
                local v, changed = ui:dropdown(id, def.label, labels, index, { tooltip = def.tip })
                if changed and values[v] then M.choose(def.key, values[v]) end
            end
        end
        -- Under the switches, so they keep their place at the top.
        ui:text(status_line(), { color = "text_dim", size = "small" })
        if status ~= "" then ui:text(status, { color = "text_dim", size = "small" }) end
        for _, sec in ipairs(option_sections()) do
            ui:separator(sec.label)
            for _, row in ipairs(sec.rows) do draw_option(ui, row) end
        end
    end

    -- Why the window is not on screen, as the Aspects window says it (1.61.3).
    local function hidden(why)
        if why == hidden_why then return end
        hidden_why = why
        local client = ctx.world and ctx.world.client and ctx.world.client() or nil
        if client and client.recording then
            pcall(ctx.emit, "jcore.recorder.trace", string.format("class window: %s",
                why and ("not shown: " .. why) or ("shown (" .. (cls and cls.label or "?") .. ")")))
        end
    end

    function M.render()
        shown = false
        if not cls then return hidden("the class is not known yet") end
        local has_aspects = cls.aspects and P.aspects and P.aspects.stats and #P.aspects.stats().trained > 0
        if #groups == 0 and not has_aspects and #option_sections() == 0 then
            return hidden("nothing for this class is trained yet")
        end
        if P.esp_only then return hidden("ESP-only client") end
        if not P.opt("class_window", true) then return hidden("switched off on the Rotation page") end
        if P.master_on and not P.master_on() then return hidden("the plugin's master switch is off") end
        local ui = ctx.ui
        if not (ui and ui.begin_window and ui.toggle and ui.set and ui.dropdown) then
            return hidden("JCore's UI has no window calls")
        end

        local sw, sh = 1920, 1080
        local draw = P.draw
        if draw and draw.screen_size then
            local w, h = draw.screen_size()
            if w and w > 0 and h and h > 0 then sw, sh = w, h end
        end
        local ok, open = pcall(ui.begin_window, ui, WINDOW_ID, {
            title = cls.label, x = math.floor(sw * 0.285 - WIDTH / 2), y = math.floor(sh * 0.58),
            w = WIDTH, min_w = WIDTH, collapsible = true, closable = false, scroll = false,
        })
        if ok and open then
            shown = true
            local ok_body, err = pcall(body, ui)
            if not ok_body then
                log.once("error", "class_window", "Class window failed: " .. tostring(err))
                hidden("its body raised: " .. tostring(err))
            else
                hidden(nil)
            end
        elseif not ok then
            hidden("begin_window raised: " .. tostring(open))
        else
            hidden("begin_window answered closed (collapsed, or hidden by JCore)")
        end
        pcall(ui.end_window, ui)
    end

    --- For the tests and the Debug page.
    function M.stats()
        local rows = {}
        for _, g in ipairs(groups) do
            local names = {}
            for i, sp in ipairs(g.members) do names[i] = sp.short end
            rows[#rows + 1] = { key = g.def.key, kind = g.def.kind, members = names,
                pick = g.def.kind ~= "keep" and pick_of(g.def) or nil }
        end
        local own = {}
        for name in pairs(owned) do own[#own + 1] = name end
        table.sort(own)
        return { class = cls and cls.key or nil, groups = rows, owned = own, status = status,
            shown = shown, hidden_why = hidden_why }
    end

    return M
end

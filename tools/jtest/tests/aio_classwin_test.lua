-- Jambix AIO 1.62.0: every class's own window (modules/classwin.lua), on a
-- hand-built bundle with a scripted clock. Only trained spells get a row. A
-- default acts only while the rotation runs (as the rotation did before); a
-- choice made in the window also while it is paused, as `classwin_paused`
-- says (1.7.5: out-of-combat buffs by default, never a seal or a form; or
-- everything; or nothing). A pick owns its whole set and Auto hands it back.
-- A kept buff is put back when it runs out and switched off when it is
-- clicked off. The game leads, a stance taken by hand included. Mounted and
-- out-of-combat-only holds. A stance picked is the form choice. The window's
-- dropdown lists Auto, None and the trained spells.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local DATA = require("jambix_aio/modules/classwin_data")

local function world(class, known_names, opts)
    opts = opts or {}
    local W = { clock = 100, known = {}, auras = {}, left = {}, casts = {}, switched = {},
        settings = { rot_enabled = true }, rotation_on = opts.rotation_on ~= false, master = true, combat = false, mounted = false }
    for _, n in ipairs(known_names) do W.known[n] = true end
    local ids, next_id = {}, 1000
    local function id_of(name)
        if not ids[name] then next_id = next_id + 1; ids[name] = next_id end
        return ids[name]
    end
    local function name_of(id)
        for n, i in pairs(ids) do if i == id then return n end end
    end
    W.name_of = name_of
    _G.core = { time = function() return W.clock end }
    local player = {
        get_guid = function() return "Player-1-ME" end,
        is_dead = function() return false end, is_ghost = function() return false end,
        is_mounted = function() return W.mounted end, is_in_combat = function() return W.combat end,
    }
    local book = {
        known = function(n) return W.known[n] == true end,
        ids = function(n) return W.known[n] and { id_of(n) } or nil end,
        id = function(n) return W.known[n] and id_of(n) or nil end,
        ready = function(n) return W.known[n] == true end,
    }
    local units = {
        player = function() return player end,
        has_aura = function(_, list)
            for _, id in ipairs(list) do if W.auras[name_of(id)] then return true end end
            return false
        end,
        aura_remaining = function(_, list)
            for _, id in ipairs(list) do
                local n = name_of(id)
                if W.auras[n] then return W.left[n] or 600 end
            end
            return 0
        end,
    }
    local tick
    local store = { data = {}, touch = function() end }
    local P = {
        ctx = {
            on = function() end, emit = function() end,
            tick = function(fn) tick = fn end,
            store = function() return store end,
            cast = function(req) W.casts[#W.casts + 1] = name_of(req.spell_id) return true end,
            PRIORITY = { UTILITY = 50 },
            ui = opts.ui,
        },
        log = { once = function() end, fmt = function() end },
        units = units, spellbook = book,
        rotation = {
            detect_class = function() return class end,
            active_class = function() return opts.flags or {} end,
            stats = function() return { label = opts.profile or "Leveling" } end,
        },
        pages = { rotation = { set = function(_, id, v) W.settings[id] = v end } },
        opt_invalidate = function() end,
        pet = { set_focus = function(u) W.focus = u or "cleared" end },
        assist = opts.assist,
        combat = { target = function() return "the target" end },
        rotation_active = function() return W.rotation_on end,
        master_on = function() return W.master end,
        opt = function(id, d) local v = W.settings[id] if v == nil then return d end return v end,
        forms = {
            is = function(n) return W.form == n end,
            switch_to = function(n) W.switched[#W.switched + 1] = n return true end,
        },
    }
    package.loaded["jambix_aio/modules/classwin"] = nil
    W.M = require("jambix_aio/modules/classwin")(P, DATA)
    function W.run(seconds)
        for _ = 1, math.floor(seconds / 0.2 + 0.5) do
            W.clock = W.clock + 0.2
            tick()
        end
    end
    function W.group(key)
        for _, g in ipairs(W.M.stats().groups) do if g.key == key then return g end end
    end
    return W
end

local T = {}

T[#T + 1] = { "only trained spells get a row; a stance on Auto is the rotation's, a kept buff the window's", function()
    local W = world("WARRIOR", { "Battle Stance", "Defensive Stance", "Battle Shout" })
    assert_eq(W.M.stats().class, "warrior", "the warrior's window")
    assert_eq(table.concat(W.group("stance").members, ","), "Battle,Defensive", "two trained stances")
    assert_eq(W.group("stance").pick, "Auto", "Auto to begin with")
    assert_eq(W.M.owns("Battle Stance"), false, "Auto: the rotation's")
    assert_eq(W.M.form_choice(), nil, "no form choice")
    assert_eq(W.M.owns("Battle Shout"), true, "a kept buff is the window's")
end }

T[#T + 1] = { "a default acts only while the rotation runs; a choice made in the window while it is paused too", function()
    local W = world("WARRIOR", { "Battle Shout" }, { rotation_on = false })
    W.run(1)
    assert_eq(#W.casts, 0, "rotation off: the untouched default waits, as the rotation did")
    W.rotation_on = true
    W.run(1)
    assert_eq(W.casts[1], "Battle Shout", "rotation on: kept up")

    local P2 = world("PALADIN", { "Devotion Aura", "Retribution Aura" }, { rotation_on = false })
    P2.M.choose("aura", "Devotion Aura")
    P2.run(1)
    assert_eq(P2.casts[1], "Devotion Aura", "picked in the window: kept up with the rotation off")
    P2.master = false
    P2.casts = {}
    P2.auras = {}
    P2.run(5)
    assert_eq(#P2.casts, 0, "the plugin's master off: nothing")
end }

T[#T + 1] = { "paused, by default: out-of-combat buffs only, never the seal, nothing in a fight (1.7.5)", function()
    local W = world("PALADIN", { "Seal of Righteousness", "Seal of Wisdom", "Devotion Aura" }, { rotation_on = false })
    W.M.choose("seal", "Seal of Wisdom")
    W.M.choose("aura", "Devotion Aura")
    W.combat = true
    W.run(2)
    assert_eq(#W.casts, 0, "paused, in a fight: nothing, the aura either")
    W.combat = false
    W.run(2)
    assert_eq(#W.casts, 1, "out of combat: one cast only")
    assert_eq(W.casts[1], "Devotion Aura", "the aura is kept; the seal is not")
    W.auras["Devotion Aura"] = true

    W.rotation_on = true
    W.run(1)
    assert_eq(W.casts[2], "Seal of Wisdom", "the rotation runs: the picked seal goes up")
    assert_eq(W.M.owns("Seal of Righteousness"), true, "and the rotation casts none of the set")

    -- Judged, with the rotation paused again: not put back.
    W.rotation_on = false
    W.run(3)
    assert_eq(#W.casts, 2, "paused: nothing")

    -- Enable rotation off with the key active is not running either.
    W.rotation_on, W.settings.rot_enabled = true, false
    W.run(3)
    assert_eq(#W.casts, 2, "switched off: nothing")
end }

T[#T + 1] = { "paused, by default: a shield or a shout used up in a fight waits for the fight to end (1.7.5)", function()
    local S = world("SHAMAN", { "Lightning Shield" }, { rotation_on = false })
    S.M.choose("shield", "Lightning Shield")
    S.combat = true
    S.run(3)
    assert_eq(#S.casts, 0, "paused, in a fight: the shield waits")
    S.combat = false
    S.run(1)
    assert_eq(S.casts[1], "Lightning Shield", "after it: put back")

    local W = world("WARRIOR", { "Battle Shout" }, { rotation_on = false })
    W.M.set_keep("Battle Shout", true)      -- switched by hand: the player's
    W.combat = true
    W.run(3)
    assert_eq(#W.casts, 0, "paused, in a fight: no shout")
    W.combat = false
    W.run(1)
    assert_eq(W.casts[1], "Battle Shout", "out of combat: kept up")
end }

T[#T + 1] = { "paused: Everything picked here keeps them all, as before 1.7.5; Nothing keeps none", function()
    local W = world("PALADIN", { "Seal of Wisdom", "Devotion Aura" }, { rotation_on = false })
    W.settings.classwin_paused = 2
    W.M.choose("seal", "Seal of Wisdom")
    W.combat = true
    W.run(2)
    assert_eq(W.casts[1], "Seal of Wisdom", "Everything: the seal goes up paused, in a fight too")
    W.master = false
    W.casts = {}
    W.run(5)
    assert_eq(#W.casts, 0, "never with the plugin off")

    local N = world("PALADIN", { "Seal of Wisdom", "Devotion Aura" }, { rotation_on = false })
    N.settings.classwin_paused = 3
    N.M.choose("seal", "Seal of Wisdom")
    N.M.choose("aura", "Devotion Aura")
    N.run(3)
    assert_eq(#N.casts, 0, "Nothing: the window waits for the rotation")
    N.rotation_on = true
    N.run(2)
    local sent = table.concat(N.casts, ",")
    assert(sent:find("Seal of Wisdom", 1, true) and sent:find("Devotion Aura", 1, true), "and acts once it runs: " .. sent)
end }

T[#T + 1] = { "the rotation runs only with Enable rotation on: its key alone is not enough (1.7.5)", function()
    local W = world("WARRIOR", { "Battle Shout", "Battle Stance", "Defensive Stance" })
    W.settings.rot_enabled = false
    W.settings.classwin_paused = 2
    W.run(1)
    assert_eq(#W.casts, 0, "an untouched default waits for the rotation")
    W.M.choose("stance", "Defensive Stance")
    W.run(1)
    assert_eq(W.switched[1], "Defensive Stance", "the window holds a picked stance, as with the key off")
    assert(W.M.status_line():find("^Rotation off"), "the line says off: " .. W.M.status_line())
end }

T[#T + 1] = { "a pick owns its whole set; Auto hands it back to the rotation", function()
    local W = world("PALADIN", { "Devotion Aura", "Retribution Aura" })
    W.M.choose("aura", "Retribution Aura")
    assert_eq(W.M.owns("Devotion Aura"), true, "the whole set, Devotion too")
    assert_eq(W.M.owns("Concentration Aura"), true, "and one not trained yet")
    W.M.choose("aura", "Auto")
    assert_eq(W.M.owns("Devotion Aura"), false, "Auto: the rotation's again")
    W.M.choose("aura", "None")
    assert_eq(W.M.owns("Devotion Aura"), true, "None: nobody casts one")
    W.run(2)
    assert_eq(#W.casts, 0, "and the window does not either")
end }

T[#T + 1] = { "kept up: put back when it runs out, switched off when it is clicked off", function()
    local W = world("MAGE", { "Arcane Intellect" })
    W.run(1)
    assert_eq(W.casts[1], "Arcane Intellect", "cast")
    W.auras["Arcane Intellect"], W.left["Arcane Intellect"] = true, 1700
    W.run(3)
    -- Clicked off: gone out of combat with most of it left.
    W.auras["Arcane Intellect"] = nil
    W.run(3)
    assert_eq(#W.casts, 1, "not put back")
    assert(W.M.stats().status:find("clicked off", 1, true), "said: " .. W.M.stats().status)
    assert_eq(W.M.owns("Arcane Intellect"), true, "still the window's, switched off")
    -- On again; this time it runs out.
    W.M.set_keep("Arcane Intellect", true)
    W.auras["Arcane Intellect"], W.left["Arcane Intellect"] = true, 1
    W.run(1)
    W.auras["Arcane Intellect"] = nil
    W.run(3)
    assert_eq(W.casts[2], "Arcane Intellect", "ran out: put back")
end }

T[#T + 1] = { "the game leads: a member put up from the action bar becomes the pick", function()
    local W = world("PALADIN", { "Devotion Aura", "Retribution Aura" })
    W.M.choose("aura", "Devotion Aura")
    W.auras["Retribution Aura"] = true
    W.run(1)
    assert_eq(W.group("aura").pick, "Retribution Aura", "followed")
    assert_eq(#W.casts, 0, "and nothing fought it")
end }

T[#T + 1] = { "holds: mounted, and in combat for an out-of-combat buff", function()
    local W = world("MAGE", { "Arcane Intellect" })
    W.combat = true
    W.run(1)
    assert_eq(#W.casts, 0, "in combat: Arcane Intellect waits")
    assert(W.M.stats().status:find("out of combat only", 1, true), "said: " .. W.M.stats().status)
    W.combat, W.mounted = false, true
    W.run(1)
    assert_eq(#W.casts, 0, "mounted: waits")
    W.mounted = false
    W.run(1)
    assert_eq(W.casts[1], "Arcane Intellect", "then cast")
end }

T[#T + 1] = { "a stance picked is the form choice, held by the window while the rotation is off", function()
    local W = world("WARRIOR", { "Battle Stance", "Defensive Stance" }, { rotation_on = false })
    W.M.choose("stance", "Defensive Stance")
    assert_eq(W.M.form_choice(), "Defensive Stance", "the form choice")
    assert_eq(W.M.owns("Battle Stance"), true, "the stances are the window's")
    W.run(1)
    assert_eq(#W.switched, 0, "paused, by default: a stance is never held (1.7.5)")
    W.settings.classwin_paused = 2
    W.run(1)
    assert_eq(W.switched[1], "Defensive Stance", "Everything picked here: held while the rotation is off")
    W.rotation_on = true
    W.switched = {}
    W.run(1)
    assert_eq(#W.switched, 0, "while it runs, the rotation's form keeper holds it")
end }

T[#T + 1] = { "a stance or form taken by hand while paused is left alone, until a death, a mount or the rotation (1.7.5)", function()
    local W = world("DRUID", { "Bear Form", "Cat Form" }, { rotation_on = false })
    W.settings.classwin_paused = 2
    W.M.choose("form", "Bear Form")
    W.run(1)
    assert_eq(W.switched[1], "Bear Form", "put up")
    W.form = "Bear Form"
    W.run(1)
    -- Shifted out by hand: to heal, or to Travel Form.
    W.form = nil
    W.switched = {}
    W.run(5)
    assert_eq(#W.switched, 0, "left as the player set it")
    assert(W.M.stats().status:find("left as you set it", 1, true), "said: " .. W.M.stats().status)
    -- A mount drops a form: put back after it, as before.
    W.mounted = true
    W.run(1)
    W.mounted = false
    W.run(1)
    assert_eq(W.switched[1], "Bear Form", "after a mount: held again")
    -- Let go again; then the rotation runs and is paused: held again.
    W.form = "Bear Form"
    W.run(1)
    W.form = "Cat Form"
    W.switched = {}
    W.run(2)
    assert_eq(#W.switched, 0, "let go again")
    W.rotation_on = true
    W.run(1)
    W.rotation_on = false
    W.run(1)
    assert_eq(W.switched[1], "Bear Form", "after the rotation ran: held again")
end }

T[#T + 1] = { "the window: a dropdown of Auto, None and the trained ones; picking from it chooses", function()
    local picks = {}
    local ui = { sets = {} }
    function ui:begin_window() return true end
    function ui:end_window() end
    function ui:set(win, id, v) self.sets[id] = v end
    function ui:toggle(_, _, v) return v, false end
    function ui:separator() end
    function ui:text() end
    function ui:dropdown(id, label, options, index)
        picks[id] = options
        if id == "pick_aura" then return 3, true end      -- the third row
        return index, false
    end
    local W = world("PALADIN", { "Devotion Aura", "Retribution Aura" }, { ui = ui })
    W.M.render()
    assert_eq(W.M.stats().shown, true, "shown")
    assert_eq(table.concat(picks.pick_aura, ","), "Auto,None,Devotion,Retribution", "the rows")
    assert_eq(W.group("aura").pick, "Devotion Aura", "the third row picked")
    W.settings.class_window = false
    W.M.render()
    assert_eq(W.M.stats().hidden_why, "switched off on the Rotation page", "its switch hides it")
end }

-- --- options and status (1.63.0) ----------------------------------------------

local function recording_ui(changes)
    local ui = { calls = {}, texts = {}, tips = {} }
    function ui:begin_window() return true end
    function ui:end_window() end
    function ui:set() end
    function ui:separator(label) self.calls[#self.calls + 1] = "sep:" .. tostring(label) end
    function ui:text(t) self.texts[#self.texts + 1] = t end
    local function widget(kind)
        return function(self, id, label, a, b, c)
            self.calls[#self.calls + 1] = kind .. ":" .. id
            local opts = (kind == "dropdown" and c) or (kind == "toggle" and b) or nil
            if type(opts) == "table" then self.tips[id] = opts.tooltip end
            local ch = changes[id]
            if ch ~= nil then changes[id] = nil return ch, true end
            if kind == "dropdown" then return b, false end
            if kind == "slider" then return c, false end
            return a, false
        end
    end
    ui.toggle, ui.slider, ui.dropdown = widget("toggle"), widget("slider"), widget("dropdown")
    function ui:button(id) self.calls[#self.calls + 1] = "button:" .. id
        if changes[id] then changes[id] = nil return true end
        return false
    end
    return ui
end

local function has(list, item)
    for _, v in ipairs(list) do if v == item then return true end end
    return false
end

T[#T + 1] = { "options: the rogue's window holds its stealth setting, written where the menu keeps it", function()
    local ui = recording_ui({ opt_rot_rogue_stealth_mode = 1 })
    local W = world("ROGUE", {}, { ui = ui })
    W.M.render()
    assert_eq(W.M.stats().shown, true, "a window with no buff groups, for its options")
    assert(has(ui.calls, "sep:Rogue options"), "the section: " .. table.concat(ui.calls, " "))
    assert(has(ui.calls, "dropdown:opt_rot_rogue_stealth_mode"), "the dropdown")
    assert_eq(W.settings.rot_rogue_stealth_mode, 1, "picked Never: written to the Rotation page")
end }

T[#T + 1] = { "options: the shared ones by capability, buttons included", function()
    local ui = recording_ui({ opt_pet_focus_clear = true, opt_rot_hunter_kite = false })
    local W = world("HUNTER", {}, { ui = ui, flags = { pet_capable = true } })
    W.M.render()
    assert(has(ui.calls, "sep:Pet"), "the pet section")
    assert(has(ui.calls, "dropdown:opt_pet_mode"), "pet mode")
    assert(not has(ui.calls, "sep:Healing"), "no healing for a hunter")
    assert_eq(W.focus, "cleared", "the clear button")
    assert_eq(W.settings.rot_hunter_kite, false, "the hunter's own option, switched off")
end }

T[#T + 1] = { "options: the hunter picks which mobs get the mark and how many a sting, with a tip on each (1.84.0)", function()
    local ui = recording_ui({ opt_rot_hunter_mark_on = 3 })
    local W = world("HUNTER", {}, { ui = ui, flags = { pet_capable = true } })
    W.M.render()
    assert(has(ui.calls, "dropdown:opt_rot_hunter_mark_on"), "Hunter's Mark on")
    assert(has(ui.calls, "dropdown:opt_rot_hunter_sting_spread"), "Serpent Sting on")
    assert_eq(W.settings.rot_hunter_mark_on, 3, "picked Bosses only: written to the Rotation page")
    assert(tostring(ui.tips.opt_rot_hunter_mark_on):find("boss flag", 1, true), "the mark's tip")
    assert(tostring(ui.tips.opt_rot_hunter_sting_spread):find("each in turn", 1, true), "the sting's tip")
    assert_eq(ui.tips.opt_pet_mode, nil, "a dropdown with no tip has none")
end }

T[#T + 1] = { "options: the hunter's mana for extra shots, with its tip (1.7.4)", function()
    local ui = recording_ui({ opt_rot_hunter_mana_use = 3 })
    local W = world("HUNTER", {}, { ui = ui, flags = { pet_capable = true } })
    W.M.render()
    assert(has(ui.calls, "dropdown:opt_rot_hunter_mana_use"), "Mana for extra shots")
    assert_eq(W.settings.rot_hunter_mana_use, 3, "picked Save for regen: written to the Rotation page")
    assert(tostring(ui.tips.opt_rot_hunter_mana_use):find("five seconds", 1, true), "the tip says why")
end }

T[#T + 1] = { "options: every class's window has what to keep up while the rotation is paused, with its tip (1.7.5)", function()
    local ui = recording_ui({ opt_classwin_paused = 3 })
    local W = world("PALADIN", { "Seal of Wisdom" }, { ui = ui, flags = { tank_capable = true, heal_capable = true } })
    W.M.render()
    assert(has(ui.calls, "sep:While the rotation is paused"), "the section: " .. table.concat(ui.calls, " "))
    assert(has(ui.calls, "dropdown:opt_classwin_paused"), "the dropdown")
    assert_eq(W.settings.classwin_paused, 3, "picked Nothing: written to the Rotation page")
    assert(tostring(ui.tips.opt_classwin_paused):find("never a seal, a stance or a form", 1, true), "the tip")
    assert(not has(ui.calls, "sep:Paladin options"), "no paladin switch of its own")

    local quiet = recording_ui({})
    local R = world("ROGUE", {}, { ui = quiet })
    R.M.render()
    assert(has(quiet.calls, "dropdown:opt_classwin_paused"), "every class's, the rogue's too")
end }

T[#T + 1] = { "options: every class has the Group section, Assist the tank and its live line (1.70.0)", function()
    local ui = recording_ui({ opt_rot_assist_tank = true })
    local W = world("MAGE", {}, { ui = ui,
        assist = { status = function() return "Assisting Tanky (group role): on Kobold Miner." end } })
    W.M.render()
    assert(has(ui.calls, "sep:Group"), "no capability flag: every class: " .. table.concat(ui.calls, " "))
    assert(has(ui.calls, "toggle:opt_rot_assist_tank"), "the switch")
    assert_eq(W.settings.rot_assist_tank, true, "switched on: written to the Rotation page")
    assert(has(ui.texts, "Assisting Tanky (group role): on Kobold Miner."), "the live line under it")

    local quiet = recording_ui({})
    local V = world("WARLOCK", {}, { ui = quiet, assist = { status = function() return "" end } })
    V.M.render()
    assert(has(quiet.calls, "sep:Group"), "the warlock's too")
    assert_eq(#quiet.texts, 1, "switched off: no line, only the status on top")
end }

T[#T + 1] = { "status: the rotation on or off and the profile, on top", function()
    local ui = recording_ui({})
    local W = world("PALADIN", { "Devotion Aura" }, { ui = ui, profile = "Retribution" })
    W.M.render()
    assert_eq(ui.texts[1], "Rotation on - Retribution", "the line")
    W.rotation_on = false
    assert_eq(W.M.status_line(), "Rotation off - Retribution", "off")
end }

return T

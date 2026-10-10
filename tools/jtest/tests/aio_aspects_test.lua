-- Jambix AIO: the hunter's aspects (modules/aspects.lua), switched by hand.
--
-- Pinned here:
--   * nothing automatic casts an aspect any more: no hunter profile has an
--     aspect rule, and the catalogue gate refuses an exclusive = "aspect" row
--     in the priority walk and in press_blocked (the reactions' gate);
--   * a switch slid on puts its aspect up once, waits for it, and puts it
--     back after a death; slid off, it is cancelled with the very row
--     get_buffs() handed out;
--   * the switches follow the game: an aspect picked from the action bar
--     turns its switch on, one clicked off the buff bar turns it off;
--   * the window shows one switch per trained aspect and always pairs
--     begin_window with end_window.

-- run.js already searches scripts/, after any JTEST_OVERLAY copy; a prefix
-- here would hide the staged copy, so it is only for running outside it.
if not jtest then package.path = "scripts/?.lua;" .. package.path end

local make_aspects = require("jambix_aio/modules/aspects")
local make_rotation = require("jambix_aio/modules/rotation")
local make_hunter = require("jambix_aio/modules/classes/hunter")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local HAWK, MONKEY, CHEETAH = "Aspect of the Hawk", "Aspect of the Monkey", "Aspect of the Cheetah"
local IDS = {
    [HAWK] = 13165, [MONKEY] = 13163, [CHEETAH] = 5118,
    ["Aspect of the Pack"] = 13159, ["Feign Death"] = 5384,
}

--- The overlay UI's facade, as far as the window uses it. A label in
--- `clicks` is flipped the next time its switch is drawn.
local function mock_ui()
    local ui = { values = {}, toggles = {}, texts = {}, begun = 0, ended = 0, open = true, clicks = {} }
    function ui:begin_window(id, opts)
        self.begun = self.begun + 1
        self.win_id, self.win_opts = id, opts
        return self.open, {}
    end
    function ui:end_window() self.ended = self.ended + 1 end
    function ui:set(win, id, v) self.values[win .. "/" .. id] = v end
    function ui:toggle(id, label, default, opts)
        local key = self.win_id .. "/" .. id
        local v = self.values[key]
        if v == nil then v = default end
        self.toggles[#self.toggles + 1] = { id = id, label = label, value = v, tip = opts and opts.tooltip }
        if self.clicks[label] then
            self.clicks[label] = nil
            v = not v
            self.values[key] = v
            return v, true
        end
        return v, false
    end
    function ui:text(s) self.texts[#self.texts + 1] = s end
    function ui:reset() self.toggles, self.texts, self.begun, self.ended = {}, {}, 0, 0 end
    return ui
end

---@param opts? { store?: table, guid?: string, ui?: table, auto_swap?: boolean }
local function bundle(opts)
    opts = opts or {}
    local W = {
        clock = 1000.0,
        auras = {},               -- spell id -> true, on the player
        known = { [HAWK] = true, [MONKEY] = true, [CHEETAH] = true, ["Feign Death"] = true },
        not_ready = {},
        casts = {}, cancels = {}, handlers = {}, settings = {},
        dead = false, mounted = false, casting = 0, eating = false,
        dispatch = true,
        rows = {}, missiles = {}, gcd = 0,
        guid = opts.guid or "Player-1-0001",
        ui = opts.ui,
    }
    -- Auto swap aspects (1.7.6), off unless a test turns it on.
    if opts.auto_swap then W.settings.rot_hunter_auto_aspect = true end
    local store = opts.store or { data = {} }
    store.touch = function(self) self.touched = (self.touched or 0) + 1 end
    W.store = store

    _G.core = { time = function() return W.clock end }

    local player = {
        get_guid = function() return W.guid end,
        is_dead = function() return W.dead end,
        is_ghost = function() return false end,
        is_mounted = function() return W.mounted end,
        get_buffs = function()
            local out = {}
            for id in pairs(W.auras) do
                out[#out + 1] = { buff_id = id, impl = id * 10, buff_index = #out + 1 }
            end
            W.buff_rows = out
            return out
        end,
    }
    W.player = player

    local P = {
        log = {
            fmt = function() end, info = function() end, debug = function() end,
            once = function(_, _, msg) W.logged = msg end,
        },
        ctx = {
            id = "jambix.aio",
            PRIORITY = { ROTATION = 50, UTILITY = 100 },
            on = function(event, fn)
                W.handlers[event] = W.handlers[event] or {}
                table.insert(W.handlers[event], fn)
            end,
            tick = function(fn, tick_opts) W.tick_fn, W.tick_opts = fn, tick_opts end,
            cast = function(request)
                request.owner = "jambix.aio"
                W.casts[#W.casts + 1] = request
                if W.dispatch then W.fire("jcore.cast.sent", request) end
                return true
            end,
            input = {
                cancel_buff = function(row)
                    W.cancels[#W.cancels + 1] = row
                    if W.cancel_works == false then return false end
                    W.auras[row.buff_id] = nil
                end,
            },
            player = { casting_spell_id = function() return W.casting end },
            spells = { gcd = function() return W.gcd end },
            enemies = {
                all = function() return W.rows end,
                get = function(u)
                    for i = 1, #W.rows do if W.rows[i].obj == u then return W.rows[i] end end
                    return nil
                end,
            },
            missiles = {
                incoming = function() return W.missiles end,
                time_to_impact = function(m) return m.eta end,
            },
            store = function(name) W.store_name = name; return store end,
            ui = opts.ui,
        },
        units = {
            player = function() return player end,
            name = function(u) return u.name end,
            has_aura = function(_, ids)
                for i = 1, #ids do if W.auras[ids[i]] then return true end end
                return false
            end,
        },
        spellbook = {
            known = function(name) return W.known[name] == true end,
            ids = function(name) return (W.known[name] and IDS[name]) and { IDS[name] } or nil end,
            id = function(name) return W.known[name] and IDS[name] or nil end,
            ready = function(name) return W.known[name] == true and not W.not_ready[name] end,
        },
        opt = function(id, default)
            local v = W.settings[id]
            if v == nil then return default end
            return v
        end,
        -- Where the window writes Auto swap aspects (the Rotation page).
        pages = { rotation = { set = function(_, id, v) W.settings[id] = v end } },
        master_on = function() return W.master ~= false end,
        rest = { consuming = function() return W.eating end },
        draw = { screen_size = function() return 1920, 1080 end },
    }
    W.P = P

    function W.fire(event, data)
        for _, fn in ipairs(W.handlers[event] or {}) do fn(data) end
    end

    W.M = make_aspects(P)

    function W.tick() W.tick_fn() end

    --- Ticks every 0.2 s for `seconds`.
    function W.run(seconds)
        for _ = 1, math.floor(seconds / 0.2 + 0.5) do
            W.clock = W.clock + 0.2
            W.tick()
        end
    end

    function W.cast_of(name)
        local n = 0
        for i = 1, #W.casts do if W.casts[i].spell_id == IDS[name] then n = n + 1 end end
        return n
    end

    function W.up(name) W.auras[IDS[name]] = true end
    function W.down(name) W.auras[IDS[name]] = nil end

    return W
end

local T = {}

-- --- nothing automatic casts an aspect ------------------------------------------

T[#T + 1] = { "no hunter profile has an aspect rule", function()
    _G.core = { time = function() return 1000 end }
    local P = {
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
        targeting = {}, ctx = {}, pet = {}, kite = {},
    }
    local H = {
        book = { known = function() return true end }, units = {},
        auto_repeat = function() return { set_period = function() end } end,
    }
    local CS = {
        opt = function(_, default) return default end,
        tune = function(_, default) return default / 100 end,
        pct = function(_, default) return default / 100 end,
        tune_secs = function(_, default) return default end,
    }
    local class = make_hunter(P, H, CS)
    for _, key in ipairs(class.profile_order) do
        local rules = class.profiles[key].rules
        assert(#rules > 5, key .. " still has its rules")
        for i = 1, #rules do
            assert(not tostring(rules[i][1]):find("^Aspect of"), key .. " has an aspect rule: " .. tostring(rules[i][1]))
        end
    end
end }

T[#T + 1] = { "the catalogue gate refuses an aspect in the walk and in press_blocked; a shot still goes", function()
    local clock = 1000.0
    _G.core = {
        time = function() return clock end,
        spell_book = { is_current_spell = function() return false end },
    }
    local ROT_IDS = { [HAWK] = 13165, ["Arcane Shot"] = 14281 }
    local ROWS = {
        ["aspect of the hawk"] = { name = HAWK, range = "self", kind = "aura", exclusive = "aspect" },
        ["arcane shot"] = { name = "Arcane Shot", range = "ranged", cooldown = 6 },
    }
    local casts = {}
    local player = {
        get_guid = function() return "player" end, get_class = function() return 3 end,
        get_attack_speed = function() return 2.0 end, is_moving = function() return false end,
    }
    local target = {
        is_valid = function() return true end, is_dead = function() return false end,
        get_guid = function() return "mob" end,
    }
    local P = {
        log = { fmt = function() end, once = function() end, info = function() end,
                debug = function() end, warn = function() end, error = function() end },
        ctx = {
            on = function() end, tick = function() end, emit = function() end,
            cast = function(request) casts[#casts + 1] = request end,
            PRIORITY = { ROTATION = 50, COOLDOWN = 80, EMERGENCY = 100 },
        },
        units = {
            player = function() return player end,
            distance = function() return 25 end,
            has_aura = function() return false end,
        },
        combat = { cast_remaining = function() return 0 end },
        spellbook = {
            id = function(name) return ROT_IDS[name] end,
            ids = function(name) return ROT_IDS[name] and { ROT_IDS[name] } or nil end,
            known = function(name) return ROT_IDS[name] ~= nil end,
            ready = function(name) return ROT_IDS[name] ~= nil end,
            castable = function(name) return ROT_IDS[name] ~= nil end,
            names = function() return {} end,
        },
        talents = { rank = function() return 0 end },
        targeting = {},
        catalog = {
            ability = function(name) return ROWS[name:lower()] end,
            current = function() return { ranges = { ranged = { min = 8, max = 35 } } } end,
            with_role = function() return {} end,
        },
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
    }
    local rotation = make_rotation(P)
    local profile = {
        label = "Test",
        rules = {
            { HAWK, function() return true end, self = true },
            { "Arcane Shot", function() return true end },
        },
    }
    rotation.classes.HUNTER = { key = "hunter", profiles = { test = profile }, profile_order = { "test" } }
    local s = { player = player, target = target, in_combat = true, distance = 25, hold_fire = false, ttd = 20 }

    for _ = 1, 10 do
        clock = clock + 0.1
        rotation.run_rules(profile, s)
    end
    local hawk, arcane = 0, 0
    for i = 1, #casts do
        if casts[i].spell_id == ROT_IDS[HAWK] then hawk = hawk + 1 end
        if casts[i].spell_id == ROT_IDS["Arcane Shot"] then arcane = arcane + 1 end
    end
    assert_eq(hawk, 0, "the walk never presses an aspect, even with a rule that wants it")
    assert(arcane > 0, "the shot below it still goes")

    local why = rotation.press_blocked(HAWK, s, player)
    assert(type(why) == "string" and why:find("Aspects window", 1, true), "press_blocked refuses it: " .. tostring(why))
    assert_eq(rotation.press_blocked("Arcane Shot", s, target), nil, "and leaves a shot alone")
end }

-- --- the keeper -------------------------------------------------------------------

T[#T + 1] = { "only trained aspects get a switch, in the game's order", function()
    local W = bundle()
    assert_eq(table.concat(W.M.stats().trained, ","), "Hawk,Monkey,Cheetah", "the trained three")
    assert_eq(W.tick_opts and W.tick_opts.interval, 0.1, "ticks ten times a second")
    W.known["Aspect of the Pack"] = true
    W.fire("jambix.aio.spellbook_refreshed")
    assert_eq(table.concat(W.M.stats().trained, ","), "Hawk,Monkey,Cheetah,Pack", "a new aspect gets its switch")
end }

T[#T + 1] = { "the window keeps why it is not on screen (1.61.3)", function()
    local ui = mock_ui()
    local W = bundle({ ui = ui })
    W.M.render()
    assert_eq(W.M.stats().shown, true, "shown")
    assert_eq(W.M.stats().hidden_why, nil, "no reason while it is up")
    W.settings.aspect_window = false
    W.M.render()
    assert_eq(W.M.stats().hidden_why, "switched off on the Rotation page", "switched off")
    W.settings.aspect_window = nil
    W.master = false
    W.M.render()
    assert_eq(W.M.stats().hidden_why, "the plugin's master switch is off", "master off")
    W.master = true
    ui.open = false
    W.M.render()
    assert_eq(W.M.stats().hidden_why, "begin_window answered closed (collapsed, or hidden by JCore)", "closed")
    ui.open = true
    W.known = {}
    W.fire("jambix.aio.spellbook_refreshed")
    W.M.render()
    assert_eq(W.M.stats().hidden_why, "no aspect trained (the spellbook names none)", "nothing trained")
end }

T[#T + 1] = { "nothing chosen and nothing up: nothing is cast", function()
    local W = bundle()
    W.run(2)
    assert_eq(#W.casts, 0, "no cast")
    assert_eq(W.M.stats().status, "No aspect. Slide one on.", "the window says so")
end }

T[#T + 1] = { "slid on: one cast, then it waits for the aura and leaves it alone", function()
    local W = bundle()
    W.tick()
    W.M.choose(HAWK)
    W.tick()
    assert_eq(#W.casts, 1, "one request")
    local r = W.casts[1]
    assert_eq(r.spell_id, IDS[HAWK], "Aspect of the Hawk")
    assert_eq(r.target, W.player, "on the player")
    assert_eq(r.priority, 100, "the utility band")
    assert(not r.fast, "in the global cooldown's lane")
    W.run(1.2)
    assert_eq(#W.casts, 1, "no second press while the aura is on its way")
    W.up(HAWK)
    W.run(5)
    assert_eq(#W.casts, 1, "up: nothing more")
    assert_eq(W.M.stats().status, "Hawk is up.", "the window says it is up")
end }

T[#T + 1] = { "a request that lost arbitration is asked for again", function()
    local W = bundle()
    W.dispatch = false
    W.M.choose(HAWK)
    W.tick()
    W.clock = W.clock + 0.2
    W.tick()
    assert_eq(#W.casts, 2, "never sent, so asked again")
end }

T[#T + 1] = { "sliding another on replaces the one that is up, and the old one is not followed back", function()
    local W = bundle()
    W.up(HAWK)
    W.tick()
    assert_eq(W.M.stats().wanted, HAWK, "Hawk up at load: its switch is on")
    W.M.choose(MONKEY)
    W.tick()
    assert_eq(W.cast_of(MONKEY), 1, "Monkey cast")
    assert_eq(W.M.stats().wanted, MONKEY, "Hawk still up is not followed back")
    W.down(HAWK); W.up(MONKEY)
    W.run(1)
    assert_eq(W.M.stats().wanted, MONKEY, "Monkey is the choice")
    assert_eq(W.M.stats().status, "Monkey is up.", "and up")
    assert_eq(#W.casts, 1, "one cast in all")
end }

T[#T + 1] = { "picked from the action bar: the switch follows, nothing is cast", function()
    local W = bundle()
    W.tick()
    W.up(CHEETAH)
    W.tick()
    assert_eq(W.M.stats().wanted, CHEETAH, "Cheetah's switch is on")
    W.down(CHEETAH); W.up(HAWK)
    W.run(3)
    assert_eq(W.M.stats().wanted, HAWK, "Hawk picked over it: Hawk's switch")
    assert_eq(#W.casts, 0, "never a cast of ours")
end }

T[#T + 1] = { "clicked off the buff bar while alive: its switch slides off", function()
    local W = bundle()
    W.up(HAWK)
    W.tick()
    W.down(HAWK)
    W.run(0.4)
    assert_eq(W.M.stats().wanted, HAWK, "a moment's gap is not a click")
    W.run(1.6)
    assert_eq(W.M.stats().wanted, nil, "gone for good: switched off")
    assert_eq(W.M.stats().status, "Hawk was clicked off.", "the window says why")
    assert_eq(#W.casts, 0, "and it is not put back")
end }

T[#T + 1] = { "a death takes the aspect; it goes back up after", function()
    local W = bundle()
    W.up(HAWK)
    W.tick()
    W.dead = true
    W.down(HAWK)
    W.run(5)
    assert_eq(W.M.stats().wanted, HAWK, "the switch stays on through a death")
    assert_eq(#W.casts, 0, "nothing cast while dead")
    assert_eq(W.M.stats().status, "Hawk: waiting, dead.", "the window says why")
    W.dead = false
    W.run(0.2)
    assert_eq(W.cast_of(HAWK), 1, "back up after")
end }

T[#T + 1] = { "it waits, and says why, while mounted, feigning, eating, casting, switched off or not ready", function()
    local cases = {
        { "mounted", function(W) W.mounted = true end },
        { "feigning death", function(W) W.up("Feign Death") end },
        { "eating or drinking", function(W) W.eating = true end },
        { "casting", function(W) W.casting = 2643 end },
        { "the plugin is switched off", function(W) W.master = false end },
        { "not ready (cooldown or mana)", function(W) W.not_ready[HAWK] = true end },
    }
    for _, case in ipairs(cases) do
        local W = bundle()
        case[2](W)
        W.M.choose(HAWK)
        W.run(1)
        assert_eq(#W.casts, 0, case[1] .. ": no cast")
        assert_eq(W.M.stats().status, "Hawk: waiting, " .. case[1] .. ".", case[1] .. ": the reason")
    end
end }

T[#T + 1] = { "slid off: cancelled with the very row get_buffs handed out, and not put back", function()
    local W = bundle()
    W.up(HAWK)
    W.tick()
    W.M.release(HAWK)
    assert_eq(#W.cancels, 1, "one cancel")
    assert_eq(W.cancels[1], W.buff_rows[1], "the row get_buffs returned, not a copy")
    assert_eq(W.cancels[1].buff_id, IDS[HAWK], "Hawk's")
    W.run(3)
    assert_eq(W.M.stats().wanted, nil, "switch off")
    assert_eq(#W.casts, 0, "nothing cast")
    assert_eq(W.M.stats().status, "No aspect. Slide one on.", "the window is back to empty")
end }

T[#T + 1] = { "a client that cannot cancel: the switch stays off and the window says to click it off", function()
    local W = bundle()
    W.cancel_works = false
    W.up(HAWK)
    W.tick()
    W.M.release(HAWK)
    W.run(0.4)
    assert_eq(W.M.stats().wanted, nil, "still up, but not followed back on")
    W.run(1.4)
    assert_eq(W.M.stats().status, "Hawk is still up: click it off the buff bar.", "the window says so")
    W.down(HAWK)
    W.run(0.4)
    assert_eq(W.M.stats().status, "No aspect. Slide one on.", "clicked off: back to empty")
    assert_eq(W.M.stats().released, nil, "nothing held")
end }

T[#T + 1] = { "slid on and straight back off: the aspect is cancelled when it lands", function()
    local W = bundle()
    W.tick()
    W.M.choose(HAWK)
    W.tick()
    W.M.release(HAWK)
    W.up(HAWK)
    W.clock = W.clock + 0.3
    W.tick()
    assert_eq(#W.cancels, 1, "cancelled on arrival")
    assert_eq(W.M.stats().wanted, nil, "and its switch stays off")
end }

T[#T + 1] = { "the choice is kept per character, across a reload", function()
    local store = { data = {} }
    local W = bundle({ store = store })
    W.M.choose(HAWK)
    assert_eq(W.store_name, "aspects", "its own store")
    assert_eq(store.data.wanted["Player-1-0001"], HAWK, "saved under the character")
    local again = bundle({ store = store })
    again.tick()
    assert_eq(again.M.stats().wanted, HAWK, "a reload remembers it")
    assert_eq(again.cast_of(HAWK), 1, "and puts it up")
    local alt = bundle({ store = store, guid = "Player-1-0002" })
    alt.tick()
    assert_eq(alt.M.stats().wanted, nil, "another character has its own")
end }

-- --- out of Cheetah before the hit (1.50.0) ---------------------------------------

--- A hostile row as JCore's enemies tracker keeps it: on you by default.
local function mob(fields)
    local r = {
        guid = "mob1", obj = { name = "Boar" }, dist = 20, targeting_me = true,
        time_to_reach = math.huge, moving = false, in_combat = true, activity = "attacking",
    }
    for k, v in pairs(fields or {}) do r[k] = v end
    return r
end

T[#T + 1] = { "the detector: what is a hit about to land, and what is not", function()
    local function first(fields, gcd)
        local W = bundle()
        W.rows = { mob(fields) }
        return W.M.incoming(CHEETAH, nil, nil, gcd)
    end
    local W = bundle()
    assert_eq(W.M.incoming(CHEETAH), nil, "nobody about: nothing")

    local eta, why = first({ dist = 4 })
    assert_eq(eta, 0, "in melee: now")
    assert_eq(why, "Boar is in melee", "and says who")

    eta, why = first({ dist = 12, moving = true, time_to_reach = 0.8 })
    assert_eq(eta, 0.8, "reaches you before a swap could")
    assert_eq(why, "Boar reaches you in 0.8s", "and when")

    assert_eq(first({ dist = 25, moving = true, time_to_reach = 3.0 }), nil, "three seconds out: not yet")
    assert_eq(first({ dist = 25, moving = true, time_to_reach = 3.0 }, 2.5), 3.0,
        "unless the global cooldown would make the swap that late")

    eta, why = first({ dist = 30, casting = { remaining = 2.5 } })
    assert_eq(eta, 1.0, "a cast at you counts at once")
    assert_eq(why, "Boar is casting at you", "and says so")

    assert_eq(first({ dist = 3, control = { kind = "stun" } }), nil, "a stunned mob in melee swings at nothing")
    assert_eq(first({ dist = 3, targeting_me = false, target_guid = "someone" }), nil,
        "in Cheetah, a mob on someone else is not your hit")
end }

T[#T + 1] = { "the detector: a mob you are outrunning is not a hit; one shooting from where it stands is", function()
    local W = bundle()
    W.rows = { mob({ dist = 15, moving = true, time_to_reach = math.huge }) }
    for _ = 1, 20 do
        W.clock = W.clock + 0.1
        assert_eq(W.M.incoming(CHEETAH), nil, "chasing and losing ground: Cheetah stays")
    end

    local S = bundle()
    S.rows = { mob({ dist = 25, moving = false }) }
    assert_eq(S.M.incoming(CHEETAH), nil, "just turned on you, standing: a moment's look first")
    S.clock = S.clock + 0.7
    local eta, why = S.M.incoming(CHEETAH)
    assert_eq(eta, 1.0, "on you, in the fight, standing still at range: it attacks from there")
    assert_eq(why, "Boar is attacking you from range", "and says so")
end }

T[#T + 1] = { "the detector: a hostile missile at you counts, a friendly one does not; Pack counts the party", function()
    local W = bundle()
    local archer = mob({ dist = 30, targeting_me = false, in_combat = false })
    archer.obj = { name = "Archer" }
    W.rows = { archer }
    W.missiles = { { caster = archer.obj, eta = 1.2 } }
    local eta, why = W.M.incoming(CHEETAH)
    assert_eq(eta, 1.2, "a hostile missile landing on you")
    assert_eq(why, "Archer's missile lands in 1.2s", "and whose")
    W.missiles = { { caster = { name = "Priest" }, eta = 0.5 } }
    assert_eq(W.M.incoming(CHEETAH), nil, "a friendly one is not a hit")

    local G = bundle()
    G.P.react = { world = { in_group = function(guid) return guid == "friend" end } }
    G.rows = { mob({ dist = 10, targeting_me = false, target_guid = "friend" }) }
    assert_eq(G.M.incoming(CHEETAH), nil, "Cheetah: the party's fight is not your daze")
    eta, why = G.M.incoming("Aspect of the Pack")
    assert_eq(eta, 0, "Pack: a mob on a party member dazes them")
    assert_eq(why, "Boar is on your party", "and says so")
end }

T[#T + 1] = { "the keeper's guard: out of Cheetah into Hawk before the mob reaches you, once", function()
    local W = bundle({ auto_swap = true })
    W.up(CHEETAH)
    W.tick()
    assert_eq(W.M.stats().wanted, CHEETAH, "travelling")
    W.rows = { mob({ dist = 12, moving = true, time_to_reach = 0.8 }) }
    W.clock = W.clock + 0.1
    W.tick()
    assert_eq(#W.casts, 1, "one swap")
    assert_eq(W.casts[1].spell_id, IDS[HAWK], "into Hawk")
    assert_eq(W.casts[1].priority, 200, "in the defensive band")
    assert(W.casts[1].reason:find("Boar reaches you in 0.8s", 1, true), "the reason says why: " .. W.casts[1].reason)
    assert_eq(W.M.stats().wanted, HAWK, "Hawk's switch on, Cheetah's off")
    assert_eq(W.M.stats().status, "Out of Cheetah: Boar reaches you in 0.8s.", "the window says what happened")

    W.run(0.6)
    assert_eq(#W.casts, 1, "Cheetah still up for a moment: not followed back, not sent twice")
    assert_eq(W.M.stats().wanted, HAWK, "still Hawk")
    W.down(CHEETAH); W.up(HAWK)
    W.run(1)
    assert_eq(#W.casts, 1, "Hawk landed: done")
    assert_eq(W.M.stats().released, nil, "nothing held")
end }

T[#T + 1] = { "the keeper's guard: back into the aspect you last fought in", function()
    local W = bundle({ auto_swap = true })
    W.up(MONKEY)
    W.tick()
    W.down(MONKEY); W.up(CHEETAH)
    W.clock = W.clock + 0.1
    W.tick()
    assert_eq(W.M.stats().last_fight, MONKEY, "Monkey was the last fight")
    W.rows = { mob({ dist = 3 }) }
    W.clock = W.clock + 0.1
    W.tick()
    assert_eq(W.cast_of(MONKEY), 1, "Monkey, not Hawk")
    assert_eq(W.cast_of(HAWK), 0, "Hawk left alone")
end }

T[#T + 1] = { "the keeper's guard: outrunning, mounted, the engine watching, the global cooldown", function()
    local W = bundle({ auto_swap = true })
    W.up(CHEETAH)
    W.tick()
    W.rows = { mob({ dist = 15, moving = true, time_to_reach = math.huge }) }
    W.run(3)
    assert_eq(#W.casts, 0, "outrunning it: Cheetah stays")

    local M2 = bundle({ auto_swap = true })
    M2.up(CHEETAH)
    M2.tick()
    M2.mounted = true
    M2.rows = { mob({ dist = 3 }) }
    M2.run(1)
    assert_eq(#M2.casts, 0, "mounted: no cast")

    local E = bundle({ auto_swap = true })
    E.up(CHEETAH)
    E.tick()
    E.rows = { mob({ dist = 3 }) }
    E.M.react_watching()
    E.clock = E.clock + 0.1
    E.tick()
    assert_eq(#E.casts, 0, "the reaction engine is watching: the keeper stands aside")
    E.clock = E.clock + 0.4
    E.tick()
    assert_eq(E.cast_of(HAWK), 1, "the engine went quiet (rotation off): the keeper switches")

    local G = bundle({ auto_swap = true })
    G.up(CHEETAH)
    G.tick()
    G.not_ready[HAWK] = true
    G.rows = { mob({ dist = 3 }) }
    G.run(0.4)
    assert_eq(#G.casts, 0, "Hawk not ready yet (global cooldown): wait")
    G.not_ready[HAWK] = nil
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.cast_of(HAWK), 1, "the moment it is ready, it goes")
end }

T[#T + 1] = { "Auto swap aspects off (the default): no aspect is swapped at all (1.7.6)", function()
    local W = bundle()
    W.up(CHEETAH)
    W.tick()
    assert_eq(W.M.stats().auto_swap, false, "off by default")
    W.rows = { mob({ dist = 3 }) }
    W.run(2)
    assert_eq(#W.casts, 0, "a mob in melee: Cheetah stays, nothing cast")
    assert_eq(W.M.stats().wanted, CHEETAH, "Cheetah's switch stays on")
    assert_eq(W.M.can_switch(HAWK), "Auto swap aspects is off", "the reaction is refused too")
    assert_eq(W.M.switch_to(HAWK, "test"), false, "and switch_to sends nothing")
    assert_eq(#W.casts, 0, "still nothing cast")

    -- Your own choice is still kept: back up after a death.
    local D = bundle()
    D.M.choose(HAWK)
    D.tick()
    assert_eq(D.cast_of(HAWK), 1, "the switch you slid on goes up")
    D.up(HAWK)
    D.run(0.4)
    D.dead = true
    D.down(HAWK)
    D.run(0.4)
    D.dead = false
    D.run(2.4)
    assert_eq(D.cast_of(HAWK), 2, "and back up after a death")
end }

T[#T + 1] = { "the window's Auto swap aspects switch turns the swap on and off", function()
    local ui = mock_ui()
    local W = bundle({ ui = ui })
    W.up(CHEETAH)
    W.tick()
    ui.clicks["Auto swap aspects"] = true
    W.M.render()
    assert_eq(W.settings.rot_hunter_auto_aspect, true, "written to the Rotation page")
    W.rows = { mob({ dist = 3 }) }
    W.clock = W.clock + 0.1
    W.tick()
    assert_eq(W.cast_of(HAWK), 1, "on: out of Cheetah into Hawk")

    local O = bundle({ ui = ui, auto_swap = true })
    ui:reset()
    O.up(CHEETAH)
    O.tick()
    ui.clicks["Auto swap aspects"] = true
    O.M.render()
    assert_eq(O.settings.rot_hunter_auto_aspect, false, "switched off")
    O.rows = { mob({ dist = 3 }) }
    O.run(1)
    assert_eq(#O.casts, 0, "off: Cheetah stays")
end }

-- --- the window -------------------------------------------------------------------

T[#T + 1] = { "the window: one slide switch per trained aspect, showing the choice", function()
    local ui = mock_ui()
    local W = bundle({ ui = ui })
    W.tick()
    W.M.render()
    assert_eq(ui.begun, 1, "one window")
    assert_eq(ui.ended, 1, "paired")
    assert_eq(ui.win_opts.title, "Aspects", "titled")
    assert_eq(#ui.toggles, 4, "three switches and Auto swap aspects")
    assert_eq(ui.toggles[1].label .. ui.toggles[2].label .. ui.toggles[3].label, "HawkMonkeyCheetah", "named")
    for i = 1, 3 do assert_eq(ui.toggles[i].value, false, ui.toggles[i].label .. " off") end
    assert_eq(ui.toggles[4].label, "Auto swap aspects", "under them, Auto swap aspects")
    assert_eq(ui.toggles[4].value, false, "off by default")
    assert(ui.toggles[3].tip:find("Dazed", 1, true), "Cheetah's tooltip warns of the daze")
    assert_eq(W.M.stats().shown, true, "shown")

    W.up(MONKEY)
    W.tick()
    ui:reset()
    W.M.render()
    assert_eq(ui.toggles[2].value, true, "Monkey up: its switch is on")
    assert_eq(ui.toggles[1].value or ui.toggles[3].value, false, "the others off")
    assert_eq(ui.texts[1], "Monkey is up.", "and the line under them says so")
end }

T[#T + 1] = { "flipping a switch chooses; flipping it back cancels", function()
    local ui = mock_ui()
    local W = bundle({ ui = ui })
    W.tick()
    ui.clicks.Hawk = true
    W.M.render()
    assert_eq(W.M.stats().wanted, HAWK, "slid on")
    W.tick()
    assert_eq(W.cast_of(HAWK), 1, "and cast")
    W.up(HAWK)
    W.tick()

    ui.clicks.Monkey = true
    ui:reset()
    W.M.render()
    assert_eq(W.M.stats().wanted, MONKEY, "Monkey slid on")
    ui:reset()
    W.M.render()
    assert_eq(ui.toggles[1].value, false, "Hawk's switch slid off with it")

    W.down(HAWK); W.up(MONKEY)
    W.tick()
    ui.clicks.Monkey = true
    ui:reset()
    W.M.render()
    assert_eq(W.M.stats().wanted, nil, "Monkey slid off")
    assert_eq(#W.cancels, 1, "and cancelled")
    assert_eq(W.cancels[1].buff_id, IDS[MONKEY], "Monkey's aura")
end }

T[#T + 1] = { "no window without a trained aspect, with its option off, on an ESP-only client or with the plugin off", function()
    local ui = mock_ui()
    local W = bundle({ ui = ui })
    W.tick()

    W.settings.aspect_window = false
    W.M.render()
    assert_eq(ui.begun, 0, "option off")
    W.settings.aspect_window = nil

    W.master = false
    W.M.render()
    assert_eq(ui.begun, 0, "plugin off")
    W.master = nil

    W.P.esp_only = true
    W.M.render()
    assert_eq(ui.begun, 0, "ESP-only client")
    W.P.esp_only = nil

    W.known = {}
    W.fire("jambix.aio.spellbook_refreshed")
    W.M.render()
    assert_eq(ui.begun, 0, "no aspect trained (not a hunter, or below level 4)")
    assert_eq(W.M.stats().shown, false, "not shown")
end }

T[#T + 1] = { "folded away: begin and end still paired, no switches drawn", function()
    local ui = mock_ui()
    ui.open = false
    local W = bundle({ ui = ui })
    W.tick()
    W.M.render()
    assert_eq(ui.begun, 1, "asked")
    assert_eq(ui.ended, 1, "paired")
    assert_eq(#ui.toggles, 0, "nothing drawn")
    assert_eq(W.M.stats().shown, false, "not shown")
end }

return T

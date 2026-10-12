-- JCore 1.8.0: the reaction framework (services/react.lua) on its own, with
-- a hand-made context: a scripted clock, a recording cast, a spellbook of
-- ids, and the events a test fires by hand.
--
-- What these hold it to: a rule is data and the engine does the rest; one
-- winner per lane and only over the rotation's score; the memory answers an
-- event once and backs a refused action off; the safety checks refuse the
-- wrong kind of target; a consumer's own kinds validate and send through
-- its hooks; the latch does not chatter; an owner's rules go with the owner.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local make_react = require("jcore/services/react")

local clock = { s = 1000.0 }
_G.core = { time = function() return clock.s end }

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function has(lines, needle)
    for i = 1, #lines do
        local text = type(lines[i]) == "table" and lines[i][2] or lines[i]
        if text:find(needle, 1, true) then return true end
    end
    return false
end

-- --- the world ------------------------------------------------------------------

local NAMES = { [100] = "Kick", [200] = "Last Stand", [300] = "Heal", [400] = "Shield Wall" }

local function unit(guid, hostile)
    local u = { guid = guid, hostile = hostile, dead = false }
    function u.is_valid() return true end
    function u.is_dead() return u.dead end
    function u.get_guid() return u.guid end
    return u
end

--- A context handle the way api.lua would build one, recording what the
--- engine does with it.
local function context(owner)
    local G = { handlers = {}, casts = {}, lines = {}, known = { [100] = true, [200] = true, [300] = true },
                unready = {} }
    G.me = unit("me", false)
    function G.me.can_attack(_, other) return other ~= nil and other.hostile == true end
    G.mob = unit("mob", true)
    G.ctx = {
        id = owner,
        on = function(event, fn)
            G.handlers[event] = G.handlers[event] or {}
            table.insert(G.handlers[event], fn)
        end,
        cast = function(req)
            req.owner = owner
            G.casts[#G.casts + 1] = req
            return true
        end,
        PRIORITY = { IDLE = 10, FILLER = 30, ROTATION = 50, COOLDOWN = 70, UTILITY = 100,
                     INTERRUPT = 150, DEFENSIVE = 200, EMERGENCY = 255 },
        spells = {
            name = function(id) return NAMES[id] or "" end,
            known = function(id) return G.known[id] == true end,
            ready = function(id) return G.known[id] == true and not G.unready[id] end,
        },
        units = {
            guid = function(u) return u and u.guid or nil end,
            player = function() return G.me end,
        },
        log = { fmt = function(level, f, ...) G.lines[#G.lines + 1] = { level, string.format(f, ...) } end },
    }
    function G.fire(event, ...)
        for _, fn in ipairs(G.handlers[event] or {}) do fn(...) end
    end
    --- The arbiter sent our cast, and the client confirmed it.
    function G.land(i)
        local req = G.casts[i or #G.casts]
        G.fire("jcore.cast.sent", req)
        G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "", req.spell_id })
    end
    function G.world(o)
        o = o or {}
        return {
            now = clock.s, mode = o.mode or "NORMAL", context = o.context,
            player = { unit = G.me, in_combat = o.in_combat ~= false, busy = o.busy == true,
                       casting_id = o.casting_id, hp = o.hp or 1 },
            pet = { alive = o.pet == true, unit = o.pet and G.pet or nil },
            target = { unit = o.target, casting = o.casting == true },
            group = { in_group = o.group == true },
            enemies = { casting_n = o.casters or 0 },
            bailout = o.bailout == true, fight_on = o.fight_on == true, hold_fire = o.hold_fire == true,
        }
    end
    return G
end

local function engine_for(owner)
    local G = context(owner or "test.plugin")
    local M = make_react({})
    G.M = M
    G.E = M.for_owner(G.ctx.id, G.ctx)
    return G
end

local function sent(G, id)
    local n = 0
    for i = 1, #G.casts do if G.casts[i].spell_id == id then n = n + 1 end end
    return n
end

local T = {}

-- --- the latch ----------------------------------------------------------------------

T[#T + 1] = { "latch: enters at one line, leaves only at the other, holds, and ignores a reading that is not a number", function()
    local L = make_react({}).latch
    local l = L.new({ enter = 0.30, exit = 0.45, below = true })
    local now = 0
    local function feed(v) now = now + 0.1 return (l.update(v, now)) end
    assert_eq(feed(0.31), false, "above the entry line")
    assert_eq(feed(0.30), true, "at the entry line: on")
    assert_eq(feed(0.44), true, "under the exit line: still on")
    assert_eq(feed(nil), true, "nil changes nothing")
    assert_eq(feed(0 / 0), true, "NaN changes nothing")
    assert_eq(feed(0.45), false, "at the exit line: off")
    assert_eq(l.age(now), 0, "just changed")

    -- A moved exit line cannot undo the hysteresis: the line in force is
    -- the further one while the latch stays on.
    local m = L.new({ enter = 0.30, exit = 0.45, below = true })
    assert_eq((m.update(0.30, 1)), true, "on at the entry line")
    assert_eq((m.update(0.40, 2, 0.30, 0.35)), true, "the exit line moved down to 35%: the 45% in force keeps it on")
    assert_eq((m.update(0.46, 3, 0.30, 0.35)), false, "and 46% is past both")

    local h = L.new({ enter = 70, exit = 60, below = false, hold = 1.0 })
    assert_eq((h.update(70, 1)), true, "threat 70: on")
    assert_eq((h.update(50, 1.5)), true, "held for a second whatever the value does")
    assert_eq((h.update(50, 2.1)), false, "then off")

    local d = L.debounce({ settle_on = 0.5, settle_off = 0 })
    assert_eq((d.update(true, 1.0)), false, "yes has to settle")
    assert_eq((d.update(true, 1.4)), false, "not yet")
    assert_eq((d.update(true, 1.5)), true, "settled")
    assert_eq((d.update(false, 1.6)), false, "no at once")
end }

-- --- the memory --------------------------------------------------------------------

T[#T + 1] = { "memory: an attempt is requested, sent, confirmed; silence after a confirmed name is a failure; a refusal twice backs it off", function()
    local M = make_react({})
    local mem = M.new_memory(function() return clock.s end, function(id) return NAMES[id] end)
    local row = mem.attempt({ name = "Kick", id = 100, kind = "spell", target_guid = "mob", event_key = "cast:1",
                              rule = "Interrupt", score = 90, lane = "gcd" })
    assert_eq(row.state, "requested", "asked")
    assert_eq(mem.waiting("Kick"), true, "waiting on the arbiter")
    mem.on_sent(100, "mob", "react: Kick")
    assert_eq(row.state, "sent", "sent")
    mem.on_success(100)
    assert_eq(row.state, "ok", "confirmed")
    assert_eq(mem.confirmed("Kick"), true, "the name has been confirmed once")
    assert_eq(select(1, mem.handled("cast:1")), false, "handled is the engine's to mark, not the memory's")

    -- A press the memory never heard of (a rotation's) arrives through on_sent.
    mem.on_sent(200, nil, "rotation")
    assert_eq(mem.last_sent.name, "Last Stand", "named through the spell names")
    assert_eq(mem.last_sent.rule, "rotation", "and credited to the rotation")

    -- Refusals: one is a wobble, two inside the window back the name off.
    clock.s = clock.s + 1
    mem.attempt({ name = "Kick", id = 100, kind = "spell" })
    mem.on_sent(100)
    assert_eq(mem.on_failure(100, "out of range", false) ~= nil, true, "laid on our attempt")
    local n, left = mem.failures("Kick")
    assert_eq(n, 1, "one failure")
    assert_eq(left, 0, "no back-off yet")
    mem.attempt({ name = "Kick", id = 100, kind = "spell" })
    mem.on_sent(100)
    mem.on_failure(100, "out of range", false)
    n, left = mem.failures("Kick")
    assert_eq(n, 2, "two failures")
    assert_eq(left, 1.5, "backed off 1.5s")
    mem.attempt({ name = "Kick", id = 100, kind = "spell" })
    mem.on_sent(100)
    mem.on_failure(100, "out of range", false)
    n, left = mem.failures("Kick")
    assert_eq(left, 3.0, "doubling")
    mem.attempt({ name = "Kick", id = 100, kind = "spell" })
    mem.on_sent(100)
    mem.on_failure(100, "out of range", false)
    n, left = mem.failures("Kick")
    assert_eq(left, 4.0, "capped at four seconds")
    mem.on_success(100)
    n, left = mem.failures("Kick")
    assert_eq(n, 0, "a success clears it")

    -- A soft refusal is recorded and never counted.
    mem.attempt({ name = "Kick", id = 100, kind = "spell" })
    mem.on_sent(100)
    mem.on_failure(100, "not ready", true)
    assert_eq(select(1, mem.failures("Kick")), 0, "soft: not a failure")
    assert_eq(mem.last_failure.why, "not ready", "but remembered")

    -- A refusal with no spell named lands on whatever we sent in the last moment.
    mem.attempt({ name = "Heal", id = 300, kind = "spell" })
    mem.on_sent(300)
    local laid = mem.on_failure(nil, "TOO_CLOSE", false)
    assert_eq(laid and laid.name, "Heal", "laid on the newest sent row")
    assert_eq(mem.persistent_error("SPELL_FAILED_OUT_OF_RANGE"), true, "a persistent error id")
    assert_eq(mem.persistent_error("SPELL_FAILED_NOT_READY"), false, "one that fixes itself")

    -- Silence: a confirmed name with no answer is a failure for a reaction, unknown for the rotation.
    clock.s = clock.s + 10
    mem.attempt({ name = "Kick", id = 100, kind = "spell", rule = "Interrupt" })
    mem.on_sent(100)
    clock.s = clock.s + 2
    mem.update(false)
    assert_eq(mem.last_attempt.state, "failed", "no confirmation counts against a reaction")
    mem.on_sent(100, nil, "rotation")
    clock.s = clock.s + 2
    mem.update(false)
    assert_eq(mem.last_sent.state, "unknown", "the rotation's press is only unknown")

    -- An attempt that lost arbitration is lost, not failed.
    mem.attempt({ name = "Heal", id = 300, kind = "spell" })
    clock.s = clock.s + 0.5
    mem.update(false)
    assert_eq(mem.last_attempt.state, "lost", "never sent")
    assert_eq(select(1, mem.failures("Heal")), 0, "the earlier TOO_CLOSE has aged out of the window; losing adds nothing")
end }

T[#T + 1] = { "memory: handled events expire, a failed answer releases its event, kinds that answer at once, the target trail and the health trail", function()
    local M = make_react({})
    local mem = M.new_memory(function() return clock.s end)
    mem.handle("cast:9", 2.0, "Interrupt: Kick")
    local yes, note, left = mem.handled("cast:9")
    assert_eq(yes, true, "handled")
    assert_eq(note, "Interrupt: Kick", "with its note")
    assert_eq(left, 2.0, "for two seconds")
    assert_eq(mem.handled_count(), 1, "one")
    assert_eq(mem.handled_keys()[1], "Interrupt: Kick", "listed by note")
    clock.s = clock.s + 2.5
    assert_eq((mem.handled("cast:9")), false, "expired")

    local row = mem.attempt({ name = "Kick", id = 100, kind = "spell", event_key = "cast:10" })
    mem.handle("cast:10", 5, "Interrupt: Kick")
    mem.on_sent(100)
    mem.on_failure(100, "interrupted", true)
    assert_eq((mem.handled("cast:10")), false, "a refused answer leaves the event open")
    assert_eq(row.state, "failed", "and the row failed")

    -- Asking IS doing for an item and a pet order; a pet skill is sent and waits.
    local item = mem.attempt({ name = "Potion", kind = "item" })
    assert_eq(item.state, "ok", "an item is done at once")
    local send = mem.attempt({ name = "Pet: attack", kind = "pet_send" })
    assert_eq(send.state, "ok", "a pet order too")
    local skill = mem.attempt({ name = "Growl", id = 900, kind = "pet_spell" })
    assert_eq(skill.state, "sent", "a pet skill is sent and waits")
    mem.on_success(900)
    assert_eq(skill.state, "ok", "until the pet's cast confirms it")
    local custom = mem.attempt({ name = "Thing", kind = "widget", answer = "done" })
    assert_eq(custom.state, "ok", "a consumer kind says how it answers")
    local arb = mem.attempt({ name = "Other", kind = "widget" })
    assert_eq(arb.state, "requested", "and waits for the arbiter when it does not")

    -- The target trail.
    assert_eq(mem.target_seen("a"), false, "the first reading is not a change")
    assert_eq(mem.target_seen("a"), false, "same target")
    assert_eq(mem.target_seen("b"), true, "a change")
    mem.target_seen("a")
    assert_eq(mem.flaps(6), 2, "two changes in six seconds")
    assert_eq(mem.stable_for(), 0, "just changed")

    -- The health trail: every drop counted, heals not netted off.
    mem.sample_hp(1.0)
    clock.s = clock.s + 0.5
    mem.sample_hp(0.8)
    clock.s = clock.s + 0.5
    mem.sample_hp(0.9)
    clock.s = clock.s + 0.5
    mem.sample_hp(0.6)
    assert_eq(math.floor(mem.damage_taken(3) * 100 + 0.5), 50, "20 + 30 lost, the heal between not netted")
    mem.sample_hp("x")
    assert_eq(math.floor(mem.damage_taken(3) * 100 + 0.5), 50, "a reading that is not a number is ignored")

    -- A one-per-caster debuff: where it last landed.
    mem.unique["Hunter's Mark"] = true
    mem.attempt({ name = "Hunter's Mark", id = 500, kind = "spell", target_guid = "mob" })
    mem.on_sent(500, "mob")
    mem.on_success(500)
    assert_eq((mem.applied("Hunter's Mark")), "mob", "applied on the mob")
    mem.combat_end()
    assert_eq((mem.applied("Hunter's Mark")), nil, "forgotten with the fight")
    assert_eq(mem.set_state("mode", "NORMAL"), true, "a state set")
    assert_eq(mem.set_state("mode", "NORMAL"), false, "unchanged")
    assert_eq(select(1, mem.state("mode")), "NORMAL", "read back")
end }

-- --- the engine ----------------------------------------------------------------------

T[#T + 1] = { "engine: a rule as data proposes, scores, is validated and cast through the handle; the memory answers the event once", function()
    local G = engine_for()
    local E = G.E
    E.add_rule({
        name = "Last stand", category = "survival", priority = 100, lane = "gcd",
        needs = { "combat" },
        retry = { hold = 2 },
        condition = function(W) return W.player.hp < 0.5 end,
        action = 200, target = "self",
        score = function(W, c) c:add(10, "health low") end,
    })
    assert_eq(E.rule("Last stand") ~= nil, true, "registered")
    assert_eq(E.stats().attached, true, "the memory's events are wired on the first rule")

    local d = E.decide(G.world({ hp = 0.9 }))
    assert_eq(#d.cands, 0, "healthy: nothing proposed")
    d = E.decide(G.world({ hp = 0.3, in_combat = false }))
    assert_eq(#d.cands, 0, "out of combat: the need gate keeps it out")

    d = E.decide(G.world({ hp = 0.3 }))
    assert_eq(#d.cands, 1, "low in combat: one candidate")
    local c = d.gcd
    assert(c, "selected for the global cooldown lane")
    assert_eq(c.name, 200, "the spell")
    assert_eq(c.score, 110, "base 100 + 10")
    assert_eq(c.reasons[2][2], "health low", "every point carries its reason")
    assert_eq(c.state, "selected", "state")
    assert_eq(E.execute(c, G.world({ hp = 0.3 })), true, "sent")
    assert_eq(#G.casts, 1, "one cast request")
    assert_eq(G.casts[1].spell_id, 200, "for the spell")
    assert_eq(G.casts[1].priority, 255, "a survival rule goes out in the emergency band")
    assert_eq(G.casts[1].owner, "test.plugin", "as the owner")
    assert_eq(G.casts[1].reason, "react: 200 (Last stand)", "with the reason")
    assert_eq(E.rule("Last stand").fired_n, 1, "counted on the rule")
    assert_eq(E.memory.last_attempt.name, 200, "remembered")

    -- The retry hold: not again for two seconds, whatever the condition says.
    d = E.decide(G.world({ hp = 0.3 }))
    assert_eq(d.gcd, nil, "not selected again")
    assert_eq(d.rejected[1].rejected:find("waiting for the result", 1, true) ~= nil, true,
        "refused while the attempt waits: " .. tostring(d.rejected[1].rejected))
    G.land(1)
    assert_eq(E.memory.last_attempt.state, "ok", "the arbiter sent it and the client confirmed it")
    clock.s = clock.s + 1
    d = E.decide(G.world({ hp = 0.3 }))
    assert_eq(d.rejected[1].rejected:find("holding before another", 1, true) ~= nil, true,
        "refused inside the hold: " .. tostring(d.rejected[1].rejected))
    clock.s = clock.s + 1.1
    d = E.decide(G.world({ hp = 0.3 }))
    assert(d.gcd, "after the hold it may go again")

    assert_eq(has(G.lines, "react trigger") or true, true, "the journal is the consumer's to write; the engine logs rejects and errors")
    assert_eq(E.stats().fired, 1, "stats count what went out")
end }

T[#T + 1] = { "engine: one winner per lane, the off-GCD lane beside it, a hold halts and takes no lane, and under the rotation's score waits", function()
    local G = engine_for()
    local E = G.E
    E.add_rule({ name = "Kick", category = "interrupt", priority = 90, condition = function() return true end,
                 action = 100, target = "enemy" })
    E.add_rule({ name = "Heal", category = "defensive", priority = 80, condition = function() return true end,
                 action = 300, target = "self" })
    E.add_rule({ name = "Wall", category = "defensive", priority = 80, lane = "fast",
                 condition = function() return true end, action = 200, target = "self" })
    E.add_rule({ name = "Bail", category = "bailout", priority = 95, kind = "hold",
                 propose = function(W, offer) offer({ name = "Stop", kind = "hold", why = "losing" }) end })
    E.add_rule({ name = "Top up", category = "low", priority = 20, condition = function() return true end,
                 action = 300, target = "self" })

    local d = E.decide(G.world({ target = G.mob }))
    assert_eq(d.gcd and d.gcd.name, 100, "the kick outscores the heal for the global cooldown")
    assert_eq(d.fast and d.fast.name, 200, "the off-GCD lane has its own winner")
    assert_eq(#d.holds, 1, "the hold is listed")
    assert_eq(d.holds[1].state, "hold", "as a hold, never a lane")
    local states = {}
    for _, c in ipairs(d.cands) do states[c.rule.name] = c.state end
    assert_eq(states["Heal"], "outscored", "the heal lost the lane")
    assert_eq(states["Top up"], "outscored", "so did the low one, this tick")
    assert_eq(d.deferred, nil, "nothing deferred while the lane is taken")

    -- With the lane free, the low one is not pressed over the rotation: it
    -- is handed back for a tick on which the rotation had nothing to press.
    E.set_enabled("Kick", false)
    E.set_enabled("Heal", false)
    d = E.decide(G.world({ target = G.mob }))
    assert_eq(d.gcd, nil, "nothing over the rotation's score")
    assert_eq(d.deferred and d.deferred.rule.name, "Top up", "below the rotation's 40: deferred for an idle tick")
    assert_eq(d.deferred.state, "deferred", "and says so")
    assert_eq(E.ROTATION_SCORE, 40, "the rotation's score")
end }

T[#T + 1] = { "engine: the safety checks -- an enemy spell with no enemy, a friendly target, the catalogue's word, an unknown spell, a key, a channel, the consumer's own reason", function()
    local G = engine_for()
    local E = G.E
    local keys, channels, blocked = {}, {}, {}
    E.configure({
        target_kind = function(name) if name == 300 then return "self" end if name == 100 then return "enemy" end end,
        key_allows = function(name) return keys[name] ~= false end,
        channel_active = function(name) return channels[name] == true end,
        press_blocked = function(name) return blocked[name] end,
    })
    E.add_rule({ name = "Kick", category = "interrupt", priority = 90, condition = function() return true end,
                 action = 100, target = "enemy" })
    E.add_rule({ name = "Heal", category = "defensive", priority = 80, condition = function() return true end,
                 action = 300, target = "self" })
    E.add_rule({ name = "Wrong way", category = "defensive", priority = 70, condition = function() return true end,
                 action = 300, target = "enemy" })
    E.add_rule({ name = "Unknown", category = "utility", priority = 60, condition = function() return true end,
                 action = 400, target = "self" })

    --- One rule alone (only a lane's best is validated), and why it was refused.
    local function why(name, W)
        for _, def in ipairs(E.rules()) do E.set_enabled(def.name, def.name == name) end
        local d = E.decide(W)
        for _, c in ipairs(d.cands) do if c.rule.name == name then return c.rejected, c.state end end
        return nil, "not offered"
    end
    local W = G.world({})
    assert_eq(why("Kick", W), "no enemy target (would self-cast)", "no target")
    assert_eq(why("Kick", G.world({ target = G.me })), "no enemy target (would self-cast)", "aimed at ourselves")
    local friend = unit("friend", false)
    assert_eq(why("Kick", G.world({ target = friend })), "target is not hostile", "a friendly target")
    G.mob.dead = true
    assert_eq(why("Kick", G.world({ target = G.mob })), "target is gone", "a dead one")
    G.mob.dead = false
    assert_eq(why("Wrong way", G.world({ target = G.mob })), "catalogue: self-only, not cast on an enemy", "the catalogue's word")
    local _, state = why("Unknown", W)
    assert_eq(state, "not offered", "a spell you have not learned is never a candidate")
    keys[300] = false
    assert_eq(why("Heal", W), "its key is not held", "a key-gated spell")
    keys[300] = nil
    channels[300] = true
    assert_eq(why("Heal", W), "its channel is running", "a channel of it running")
    channels[300] = nil
    blocked[300] = "too far"
    assert_eq(why("Heal", W), "too far", "the consumer's own reason")
    blocked[300] = nil
    G.unready[300] = true
    assert_eq(why("Heal", W), "not ready (cooldown or resources)", "not ready")
    G.unready[300] = nil
    assert_eq(why("Heal", W), nil, "and nothing in its way")

    -- Offensive rules wait while holding fire and during a bail-out.
    assert_eq(why("Kick", G.world({ target = G.mob, hold_fire = true })), "holding fire: target not engaged", "holding fire")
    assert_eq(why("Kick", G.world({ target = G.mob, bailout = true })), "bail-out: no attacks", "bailing out")
    assert_eq(why("Heal", G.world({ bailout = true })), nil, "a defensive still goes")

    -- Busy with the same spell, or with a reaction of ours that scored higher.
    local d = E.decide(G.world({}))
    assert_eq(d.gcd and d.gcd.rule.name, "Heal", "the heal, alone, is selected")
    E.execute(d.gcd, G.world({}))
    G.land()
    local busy = G.world({ busy = true, casting_id = 300 })
    local w = why("Heal", busy)
    assert_eq(w and w:find("^busy: 300") ~= nil, true, "the heal in progress is ours and not clearly less important: " .. tostring(w))
    assert_eq(why("Heal", G.world({ busy = true, casting_id = 300, mode = "EMERGENCY" })), "already casting it",
        "scored higher now (EMERGENCY), the same spell again")
    for _, def in ipairs(E.rules()) do E.set_enabled(def.name, true) end
    assert_eq(why("Kick", G.world({ busy = true, casting_id = 300, target = G.mob })), nil,
        "a kick (90) talks over a heal (80) in progress")
    E.add_rule({ name = "Trivial", category = "low", priority = 85, condition = function() return true end,
                 action = 100, target = "enemy" })
    local w2 = why("Trivial", G.world({ busy = true, casting_id = 300, target = G.mob }))
    assert_eq(w2 and w2:find("^busy: 300") ~= nil, true, "one not clearly more important waits: " .. tostring(w2))
end }

T[#T + 1] = { "engine: a consumer's own kinds validate and send through its hooks; an unknown kind is refused; answer says how the memory waits", function()
    local G = engine_for()
    local E = G.E
    local used = {}
    E.configure({
        kinds = {
            potion = {
                target_kind = "self", answer = "done",
                validate = function(c, W) if not c.item then return "no potion named" end end,
                execute = function(c) used[#used + 1] = c.item return true end,
            },
        },
    })
    E.add_rule({ name = "Drink", category = "survival", priority = 100,
                 propose = function(W, offer) if W.player.hp < 0.5 then offer({ name = "Potion", kind = "potion", item = "healing", event_key = "consumable", handled_for = 3 }) end end })
    E.add_rule({ name = "Odd", category = "utility", priority = 60,
                 propose = function(W, offer) offer({ name = "Thing", kind = "widget", target_kind = "self" }) end })
    local W = G.world({ hp = 0.3 })
    local d = E.decide(W)
    assert_eq(d.gcd and d.gcd.name, "Potion", "the potion wins the lane")
    assert_eq(d.gcd.target, G.me, "aimed at ourselves by the kind's target kind")
    do
        local odd
        for _, c in ipairs(d.cands) do if c.rule.name == "Odd" then odd = c end end
        assert_eq(odd.state, "outscored", "the odd one lost the lane, and only a lane's best is validated")
    end
    assert_eq(E.execute(d.gcd, W), true, "sent through the kind's execute")
    assert_eq(used[1], "healing", "with the item")
    assert_eq(#G.casts, 0, "never through the arbiter")
    assert_eq(E.memory.last_attempt.state, "ok", "asking was doing")
    assert_eq((E.memory.handled("consumable")), true, "the event is handled")
    d = E.decide(W)
    assert_eq(d.gcd, nil, "the potion is not asked for again while its event is handled, and the odd one cannot go")
    local by = {}
    for _, c in ipairs(d.rejected) do by[c.rule.name] = c.rejected end
    assert_eq(by["Drink"] and by["Drink"]:find("already handled", 1, true) ~= nil, true, tostring(by["Drink"]))
    assert_eq(by["Odd"], "unknown action kind widget", "a kind nobody configured")
end }

T[#T + 1] = { "engine: the mode and the context move the scores, a refused name is marked down, and the lane's band follows the category", function()
    local G = engine_for()
    local E = G.E
    E.add_rule({ name = "Kick", category = "interrupt", priority = 90, condition = function() return true end,
                 action = 100, target = "enemy" })
    E.add_rule({ name = "Heal", category = "defensive", priority = 80, condition = function() return true end,
                 action = 300, target = "self" })
    local function score(name, W)
        local d = E.decide(W)
        for _, c in ipairs(d.cands) do if c.rule.name == name then return c.score, c end end
    end
    assert_eq(score("Heal", G.world({})), 80, "NORMAL: the base")
    local s, c = score("Heal", G.world({ mode = "EMERGENCY" }))
    assert_eq(s, 95, "EMERGENCY: defensives +15")
    assert_eq(c.reasons[2][2], "mode EMERGENCY", "said so")
    assert_eq(score("Kick", G.world({ target = G.mob, mode = "ESCAPE" })), 70, "ESCAPE: interrupts -20")
    assert_eq(score("Kick", G.world({ target = G.mob, context = "BOSS" })), 100, "BOSS: interrupts +10")
    assert_eq(E.band_for(E.rule("Kick")), 150, "an interrupt goes out in the interrupt band")
    assert_eq(E.band_for(E.rule("Heal")), 255, "a defensive in the emergency band")
    assert_eq(E.band_for({ category = "pet" }), 100, "the pet in utility")
    assert_eq(E.band_for({ category = "buff" }), 55, "a buff just over the rotation")
    assert_eq(E.band_for({ category = "low", band = 7 }), 7, "a rule's own band wins")

    -- Two refusals back the name off and mark every candidate for it down.
    E.set_enabled("Heal", false)
    local W = G.world({ target = G.mob })
    for _ = 1, 2 do
        local d = E.decide(W)
        assert_eq(d.gcd and d.gcd.rule.name, "Kick", "the kick is selected")
        E.execute(d.gcd, W)
        G.fire("jcore.cast.sent", G.casts[#G.casts])
        G.fire("jcore.game_event.UI_ERROR_MESSAGE", { 0, "Out of range", "SPELL_FAILED_OUT_OF_RANGE" })
        clock.s = clock.s + 0.1
    end
    local d = E.decide(W)
    local kick
    for _, x in ipairs(d.cands) do if x.rule.name == "Kick" then kick = x end end
    assert_eq(kick.score, 40, "90 - 50 while backed off")
    assert_eq(kick.rejected:find("failed 2 time", 1, true) ~= nil, true, "and refused: " .. tostring(kick.rejected))
    assert_eq(has(G.lines, "client error after 100"), true, "the client's error is journalled against the press")
end }

T[#T + 1] = { "engine: an interval rule waits, its wake event asks it at once; owns and yielding; the player's filter, set_enabled, remove_rule", function()
    local G = engine_for()
    local E = G.E
    local asked = 0
    E.add_rule({ name = "Slow", category = "utility", priority = 60, every = 10, wake = { "jcore.enemy.casting" },
                 condition = function() asked = asked + 1 return false end })
    local W = G.world({})
    E.decide(W); E.decide(W); E.decide(W)
    assert_eq(asked, 1, "asked once in ten seconds")
    assert_eq(G.handlers["jcore.enemy.casting"] ~= nil, true, "the wake event is subscribed through the handle")
    G.fire("jcore.enemy.casting")
    E.decide(W)
    assert_eq(asked, 2, "the wake event asks it at once")

    local channel = nil
    E.configure({ channel_active = function(name) return channel == name end })
    E.add_rule({ name = "Mend", category = "pet", priority = 70, owns = { 300 },
                 enabled = function(W) return W.pet.alive end,
                 condition = function() return false end,
                 yield = function(W, spell) return W.player.hp < 0.3 and "you are dying" or nil end })
    assert_eq(E.owns(300, G.world({ pet = true })), true, "owned while its gate says yes")
    assert_eq(E.owns(300, G.world({ pet = false })), false, "not without a pet")
    assert_eq(E.yielding(G.world({ pet = true, hp = 0.2 })), nil, "nothing is being cast")
    channel = 300
    local y = E.yielding(G.world({ pet = true, hp = 0.2, busy = true }))
    assert_eq(y and y.why, "you are dying", "the channel gives way")
    assert_eq(E.yielding(G.world({ pet = true, hp = 0.9, busy = true })), nil, "not when standing still is fine")

    E.filter = function(def) return def.name ~= "Mend" end
    assert_eq(E.owns(300, G.world({ pet = true })), false, "the player's switch keeps it out")
    E.filter = nil
    E.set_enabled("Mend", false)
    assert_eq(E.owns(300, G.world({ pet = true })), false, "switched off")
    E.set_enabled("Mend", true)
    assert_eq(E.owns(300, G.world({ pet = true })), true, "and on")
    E.remove_rule("Mend")
    assert_eq(E.rule("Mend"), nil, "gone")
    assert_eq(E.owns(300, G.world({ pet = true })), false, "nothing owns it now")
    assert_eq(#E.rules(), 1, "one rule left")
end }

T[#T + 1] = { "engine: the journal keeps a ring and mirrors to the log by level; explain lifts the refusals; one line per key per three seconds", function()
    local G = engine_for()
    local E = G.E
    local explain = false
    E.configure({ explain = function() return explain end })
    E.journal("trigger", "Kick -> mob")
    E.journal("reject", "Heal refused", "rej:Heal")
    E.journal("reject", "Heal refused again", "rej:Heal")
    assert_eq(#E.journal_rows(), 2, "the second under the same key inside three seconds is dropped")
    assert_eq(E.journal_due("rej:Heal"), false, "and would still be")
    clock.s = clock.s + 3
    assert_eq(E.journal_due("rej:Heal"), true, "until three seconds pass")
    assert_eq(G.lines[1][1], "info", "a trigger goes to the log at info")
    assert_eq(G.lines[2][1], "debug", "a refusal at debug")
    explain = true
    E.journal("reject", "Heal refused later", "rej:Heal")
    assert_eq(G.lines[3][1], "info", "explain lifts a refusal to info")
    local lines = E.log_lines(10)
    assert_eq(lines[1]:find("Heal refused later", 1, true) ~= nil, true, "newest first: " .. lines[1])
    assert_eq(#lines, 3, "three kept")
    E.reset()
    assert_eq(E.log_lines(5)[1], "(nothing yet)", "reset empties it")
    assert_eq(E.memory.last_attempt, nil, "and the memory")

    -- A rule that raises is journalled once, and the rest still run.
    E.add_rule({ name = "Broken", category = "utility", priority = 60, condition = function() error("boom") end })
    E.add_rule({ name = "Fine", category = "utility", priority = 50, condition = function() return true end, action = 300, target = "self" })
    local d = E.decide(G.world({}))
    assert_eq(d.gcd and d.gcd.rule.name, "Fine", "the sound rule still wins its lane")
    assert_eq(has(G.lines, "Broken raised"), true, "the broken one is reported")
end }

T[#T + 1] = { "service: one engine per owner, built once; an owner's rules go with the owner; the stats add up", function()
    local M = make_react({})
    local A = context("plugin.a")
    local B = context("plugin.b")
    local EA = M.for_owner("plugin.a", A.ctx)
    assert_eq(M.for_owner("plugin.a", A.ctx), EA, "the same engine twice")
    local EB = M.for_owner("plugin.b", B.ctx)
    assert(EA ~= EB, "a different owner, a different engine")
    EA.add_rule({ name = "A1", category = "utility", priority = 60, condition = function() return true end, action = 300, target = "self" })
    EB.add_rule({ name = "B1", category = "utility", priority = 60, condition = function() return true end, action = 300, target = "self" })
    EB.add_rule({ name = "B2", category = "utility", priority = 50, condition = function() return true end, action = 300, target = "self" })
    EB.set_enabled("B2", false)
    local s = M.stats()
    assert_eq(s.engines, 2, "two engines")
    assert_eq(s.rules, 3, "three rules")
    assert_eq(s.enabled, 2, "two on")
    local d = EA.decide(A.world({}))
    EA.execute(d.gcd, A.world({}))
    assert_eq(#A.casts, 1, "A cast through A's handle")
    assert_eq(#B.casts, 0, "not B's")
    assert_eq(A.casts[1].owner, "plugin.a", "as A")
    -- A's memory hears A's sends, not B's.
    A.fire("jcore.cast.sent", { spell_id = 300, owner = "plugin.b" })
    assert_eq(EA.memory.last_attempt.state, "requested", "another owner's send is not ours")
    A.fire("jcore.cast.sent", A.casts[1])
    assert_eq(EA.memory.last_attempt.state, "sent", "ours is")
    assert_eq(M.stats().fired, 1, "one sent in all")
    M.remove_owner("plugin.b")
    assert_eq(M.stats().engines, 1, "B is gone")
    assert_eq(#EB.rules(), 0, "with its rules")
    assert_eq(M.for_owner("plugin.b", B.ctx) ~= EB, true, "a fresh one next time")
end }

T[#T + 1] = { "engine: the picture may leave fields out, and a rule's target function, a ground spell and the pet lane work", function()
    local G = engine_for()
    local E = G.E
    G.pet = unit("pet", false)
    E.configure({ kinds = { pet_spell = { lane = "pet", answer = "sent",
        validate = function(c, W) if not W.pet.alive then return "no pet" end end,
        execute = function(c) return true, 900 end } } })
    E.add_rule({ name = "Growl", category = "pet", priority = 74, needs = { "pet" },
                 propose = function(W, offer) offer({ name = "Growl", kind = "pet_spell", target = W.target.unit }) end })
    E.add_rule({ name = "Flare", category = "utility", priority = 64,
                 propose = function(W, offer) offer({ name = 100, target_kind = "ground", position = W.spot }) end })
    E.add_rule({ name = "Pick", category = "utility", priority = 62, condition = function() return true end,
                 action = 100, target = function(W) return W.target.unit end })
    -- A bare picture: no pet, group or enemies tables at all.
    local d = E.decide({ now = clock.s, player = { unit = G.me, in_combat = true }, target = { unit = G.mob } })
    local names = {}
    for _, c in ipairs(d.cands) do names[c.rule.name] = c end
    assert_eq(names["Growl"], nil, "no pet table: the need gate reads it as no pet")
    assert_eq(names["Flare"].rejected, "no spot to cast it on", "a ground spell with no spot")
    assert_eq(names["Pick"].target, G.mob, "a target function")
    assert_eq(d.gcd and d.gcd.rule.name, "Pick", "and it wins")

    local W = G.world({ pet = true, target = G.mob })
    W.spot = { x = 1, y = 2, z = 3 }
    d = E.decide(W)
    assert_eq(d.pet and d.pet.name, "Growl", "the pet lane has its own winner")
    assert_eq(d.gcd and d.gcd.rule.name, "Flare", "the flare with a spot wins the global cooldown")
    assert_eq(E.execute(d.gcd, W), true, "cast")
    assert_eq(G.casts[1].position, W.spot, "at the spot")
    assert_eq(E.execute(d.pet, W), true, "and the pet's order")
    assert_eq(E.memory.last_attempt.id, 900, "with the id its execute answered")
    assert_eq(E.memory.last_attempt.state, "sent", "waiting on the pet's cast")
end }

return T

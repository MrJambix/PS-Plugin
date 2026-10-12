-- Jambix AIO / pvphunter -- the PvP hunter's read of the fight (1.7.6, ALPHA/TEST).
--
-- The user, 2026-10-10: "Look up all PVP hunter for forever guides and
-- Rotations and lets make an unstoppable PVP hunter where it can detect its
-- in pvp mode and react instantly... know what to do what the player is
-- doing how to Cast CC and kill".
--
-- Three answers live here, shared by the hunter's PvP profile
-- (classes/hunter.lua), its PvP reactions (react/rules/hunter_pvp.lua), the
-- pet (pet.lua) and the legs (kite.lua):
--
--   PVP MODE     on, with the class option "PvP hunter (ALPHA/TEST)", while
--                your target is an enemy player, an enemy player within 40
--                yd is on you or your pet, or you are in a battleground with
--                one that close. Held 4 s past the last sign, so a Vanish or
--                a click on a mob mid-fight does not flip the rotation back
--                to its PvE list and straight back again.
--   OUR CONTROL  is this player held by a control of ours that damage
--                breaks -- a Freezing Trap, a Scatter Shot, a Wyvern Sting --
--                and for how long. Nothing shoots it while it is; the pet is
--                kept off it (pet.lua asks the reactions' out_of_fight).
--   THE RESET    a player frozen in our trap is time to walk away in: the
--                step out (kite.lua) keeps going to this many yards, so the
--                next opener (Aimed Shot, then the rest) starts from range
--                and the player has the whole distance to cover again.
--
-- What it says it is doing goes on the class window's line under the switch.

return function(P)
    local ctx, units, log = P.ctx, P.units, P.log

    local M = {}

    local huge = math.huge

    M.SWITCH = "rot_hunter_pvp_alpha"
    local REACH = 40             -- yards: a player this close and on you is a fight
    local HOLD = 4               -- seconds the mode outlasts its last sign
    local READ_EVERY = 0.1       -- seconds between reads of the signs
    local RESET_MIN_LEFT = 3     -- seconds of trap left that make a walk worth starting
    -- Yards the step out walks from a trapped player: Intercept and Charge
    -- reach 25. Its slider went (2026-10-10: the PvP hunter is one option).
    local RESET_YARDS = 25

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function clock() return core.time() end
    local function game_ms()
        local ok, v = pcall(core.game_time)
        return ok and tonumber(v) or nil
    end

    local function name_of(unit)
        local n = unit and units.name and try(units.name, unit) or nil
        if type(n) ~= "string" or n == "" then n = unit and try(unit.get_name, unit) or nil end
        return (type(n) == "string" and n ~= "") and n or "a player"
    end

    --- The class option is on, and we are a hunter.
    ---@return boolean
    function M.enabled()
        if not (P.opt and P.opt(M.SWITCH, false) == true) then return false end
        local rot = P.rotation
        local cls = rot and rot.active_class and try(rot.active_class) or nil
        return cls ~= nil and cls.key == "hunter"
    end

    local function is_player(unit)
        return unit ~= nil and try(unit.is_player, unit) == true
    end

    local function hostile(unit)
        local me = units.player and units.player() or nil
        return me ~= nil and try(me.can_attack, me, unit) == true
    end

    local function dead(unit)
        return try(unit.is_dead, unit) == true
    end

    M.is_player = is_player

    --- An enemy player: a player we can attack, alive.
    ---@param unit game_object|nil
    ---@return boolean
    function M.enemy_player(unit)
        return unit ~= nil and is_player(unit) and hostile(unit) and not dead(unit)
    end

    -- ==========================================================================
    -- PVP MODE
    -- ==========================================================================

    local seen_at, said_why = -huge, nil
    local read_at, on_now = -huge, false
    local announced = false

    local function in_battleground()
        local targeting = P.targeting
        local here = targeting and targeting.context and try(targeting.context) or nil
        return here == "pvp"
    end

    --- Why this is a PvP fight right now, or nil.
    local function signs()
        local combat = P.combat
        local target = combat and combat.target and try(combat.target) or nil
        if target and M.enemy_player(target) then
            return "your target is " .. name_of(target)
        end
        local en = ctx and ctx.enemies
        local rows = en and en.all and try(en.all) or nil
        if type(rows) ~= "table" then return nil end
        local bg = nil
        for i = 1, #rows do
            local r = rows[i]
            if type(r) == "table" and r.obj and (tonumber(r.dist) or huge) <= REACH and is_player(r.obj)
                and not dead(r.obj) then
                if r.targeting_me or r.targeting_pet then
                    return name_of(r.obj) .. (r.targeting_me and " is on you" or " is on your pet")
                end
                if bg == nil then bg = in_battleground() end
                if bg then return "a battleground, " .. name_of(r.obj) .. " is near" end
            end
        end
        return nil
    end

    --- Is this a fight with another player? The second value says why (or
    --- why it was, during the hold).
    ---@return boolean
    ---@return string|nil
    function M.mode()
        if not M.enabled() then
            on_now = false
            return false, "switched off"
        end
        local now = clock()
        if (now - read_at) >= READ_EVERY then
            read_at = now
            local why = signs()
            if why then seen_at, said_why = now, why end
            local on = (now - seen_at) <= HOLD
            if on and not announced then
                announced = true
                if log then log.fmt("info", "PvP hunter: PvP mode -- %s", tostring(said_why)) end
            elseif not on and announced then
                announced = false
                if log then log.fmt("info", "PvP hunter: back to the PvE rotation") end
            end
            on_now = on
        end
        return on_now, said_why
    end

    -- ==========================================================================
    -- OUR CONTROL ON A PLAYER
    -- ==========================================================================

    -- The debuffs of ours that damage breaks, by the name the client shows.
    local OURS = {
        ["Freezing Trap Effect"] = "trap", ["Freezing Trap"] = "trap",
        ["Scatter Shot"] = "scatter", ["Wyvern Sting"] = "sting",
    }
    M.OURS = OURS

    local function left_on(aura, now_ms)
        local expires = tonumber(aura.expire_time)
        if not expires or expires <= 0 or not now_ms then return huge end
        return math.max(0, (expires - now_ms) / 1000)
    end

    --- Whose an aura is: "yes" (its caster is us), "other" (another unit's),
    --- or "unknown" (the row carries no caster, or one that gives no guid).
    --- JCore's aura_is_mine fails open the same way; the PvP intelligence's
    --- control plan reads "unknown" as ours at a lower confidence.
    ---@param aura table
    ---@return string who
    local function caster_of(aura)
        local caster = type(aura) == "table" and aura.caster or nil
        if caster == nil then return "unknown" end
        local ok, guid = pcall(function() return caster:get_guid() end)
        if not ok or type(guid) ~= "string" or guid == "" then return "unknown" end
        local me = units.player and try(units.player) or nil
        local mine = me and units.guid and try(units.guid, me) or nil
        if type(mine) ~= "string" or mine == "" then return "unknown" end
        return guid == mine and "yes" or "other"
    end
    M.caster_of = caster_of

    --- Held by a control of ours that damage breaks: its kind ("trap",
    --- "scatter", "sting"), seconds left, and whose the aura is ("yes": its
    --- caster is us; "unknown": no caster to read); nil when it is not.
    --- Another hunter's trap (a caster that is not us) does not count
    --- (2026-10-11: until then any trap read as ours, PVP_INTEL_PLAN.md
    --- §1.13 defect 10).
    ---@param unit game_object|nil
    ---@return string|nil kind
    ---@return number left
    ---@return string|nil ours "yes" or "unknown"
    function M.held(unit)
        if not unit then return nil, 0, nil end
        local index = units.aura_index and try(units.aura_index, unit) or nil
        if type(index) ~= "table" then
            local list = try(unit.get_debuffs, unit)
            index = type(list) == "table" and list or nil
        end
        if not index then return nil, 0, nil end
        local now_ms = game_ms()
        local kind, left, ours = nil, 0, nil
        for _, aura in pairs(index) do
            local k = type(aura) == "table" and OURS[aura.buff_name or ""] or nil
            if k then
                local who = caster_of(aura)
                if who ~= "other" then
                    local l = left_on(aura, now_ms)
                    if not kind or l > left then kind, left, ours = k, l, who end
                end
            end
        end
        return kind, left, ours
    end

    --- Yards the step out keeps walking to from this target: a player
    --- frozen in our trap with time left on it. nil: the usual step, out
    --- of the dead zone and no further.
    ---@param unit game_object|nil
    ---@return number|nil
    function M.reset_to(unit)
        if not unit or not M.mode() or not is_player(unit) then return nil end
        local kind, left = M.held(unit)
        if kind ~= "trap" or left < RESET_MIN_LEFT then return nil end
        return RESET_YARDS
    end

    -- ==========================================================================
    -- WHAT IT SAYS
    -- ==========================================================================

    local note, note_at = nil, -huge
    local NOTE_KEEP = 8

    --- The last thing the PvP reactions did, for the class window's line.
    ---@param text string
    function M.note(text)
        note, note_at = text, clock()
    end

    --- One line for the class window: off, waiting, or what it is facing
    --- and the last thing it did about it.
    ---@return string
    function M.status()
        if not (P.opt and P.opt(M.SWITCH, false) == true) then return "PvP hunter (ALPHA/TEST): off" end
        local on, why = M.mode()
        if not on then return "PvP hunter (ALPHA/TEST): on, waiting for an enemy player" end
        local text = "PvP: " .. tostring(why or "a player")
        local combat = P.combat
        local target = combat and combat.target and try(combat.target) or nil
        local pvp = P.react and P.react.pvp
        if target and pvp and pvp.foe then
            local f = try(pvp.foe, target)
            if f then text = text .. " -- " .. pvp.foe_text(f) end
            local kind, left = M.held(target)
            if kind then text = text .. string.format(", in your %s for %.0fs", kind, math.min(left, 99)) end
        end
        if note and (clock() - note_at) <= NOTE_KEEP then text = text .. "; last: " .. note end
        return text
    end

    function M.stats()
        local on, why = M.mode()
        return { enabled = M.enabled(), on = on, why = why, note = note }
    end

    return M
end

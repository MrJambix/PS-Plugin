-- Jambix AIO / weave -- the shot between the steps.
--
-- WHAT IT DOES
-- A ranged auto attack -- a hunter's Auto Shot, a caster's wand -- keeps its
-- swing timer running while you move, but the shot itself only goes out
-- while you are STANDING for the half-second aim. This module follows that
-- swing: when the last real shot went out, and when the next is due. It is
-- a readout, for the debug page and for anything that wants to know whether
-- a shot is imminent.
--
-- WHAT IT NEVER DOES
-- It never touches the character. Two earlier revisions held the player
-- still for the aim through the client's movement lock, and one of them
-- turned the player to face the target as well. Both made a hunter feel
-- jerky: a stop every weapon speed, and a character that came out of the
-- stop running somewhere else. Weaving is the player's: the rotation
-- presses Auto Shot the moment it detects it can (standing, at range, the
-- toggle not already running -- see the Auto Shot rule in classes/hunter),
-- and the shot goes out on its own whenever the player stands. This module
-- takes no input lease and holds nothing.
--
-- HOW IT KNOWS WHEN
-- Only from REAL shots. The core's cast callback reports each one, and the
-- swing timer addon reports the last swing and the next due when it is
-- loaded; the weapon's speed fills in the period otherwise.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat
    local book = P.spellbook

    local M = {}

    local DEFAULT_PERIOD = 2.5     -- a starter bow, until something says
    local DEFAULT_AIM = 0.5        -- the stand-still aim, until the addon says
    local ADDON_READ_EVERY = 0.25  -- seconds between swing timer addon reads

    local repeat_name = nil        -- "Auto Shot" | "Shoot" | nil
    local period = DEFAULT_PERIOD
    local aim = DEFAULT_AIM
    local period_read_at = 0
    local addon_read_at = 0
    local addon_last_swing = nil   -- the addon's last_swing as last seen

    local last_shot = 0            -- a REAL shot: the event or the addon said so
    local next_due = 0             -- when the next shot is expected; 0 = unknown
    local shots = 0

    -- --- what to follow -----------------------------------------------------

    --- The ranged auto attack this character has, or nil.
    local function repeat_spell()
        -- The catalogue's answer first: the trained damage toggle that needs
        -- a ranged weapon. That is Auto Shot for a hunter, and it will be the
        -- same question for any class file that describes one.
        local catalog = P.catalog
        if catalog then
            local toggles = catalog.with_role("toggle", true)
            for i = 1, #toggles do
                local row = toggles[i]
                if row.kind == "toggle" and catalog.has_role(row.name, "damage") then
                    return row.name
                end
            end
        end
        local class_module = P.rotation and P.rotation.active_class()
        if class_module and class_module.key == "hunter" and book.known("Auto Shot") then
            return "Auto Shot"
        end
        if P.opt("rot_use_wand", true) and book.known("Shoot") then
            return "Shoot"
        end
        return nil
    end

    -- --- a shot happened ----------------------------------------------------

    ---@param at number when the shot went out
    local function on_shot(at)
        last_shot = at
        next_due = at + period
        shots = shots + 1
    end

    --- The swing timer addon, when it is loaded: the aim length, the
    --- period, and when the last shot went out and the next is due. Read a
    --- few times a second, not every frame: it is two native calls.
    ---@param now number
    local function read_addon(now)
        if (now - addon_read_at) < ADDON_READ_EVERY then return end
        addon_read_at = now

        local addons = core.addons
        local st = type(addons) == "table" and addons.swing_timer or nil
        if not (type(st) == "table" and type(st.is_loaded) == "function"
            and type(st.get_player_ranged_info) == "function") then
            return
        end
        local ok, loaded = pcall(st.is_loaded)
        if not ok or not loaded then return end
        local ok_i, info = pcall(st.get_player_ranged_info)
        if not ok_i or type(info) ~= "table" then return end

        local a = info.auto_shot_cast_time
        if type(a) == "number" and a > 0.1 and a < 2 then aim = a end

        local swing, due = info.last_swing, info.expiration_time
        if type(swing) ~= "number" or type(due) ~= "number" then return end
        local p = due - swing
        if p > 0.5 and p < 10 then period = p end

        -- A new last_swing is a real shot. When the addon's clock is ours
        -- (its last swing is within a few swings of now), its figures are
        -- used as they are; otherwise the change itself is the shot and it
        -- is stamped with our clock.
        if addon_last_swing ~= nil and swing ~= addon_last_swing then
            if math.abs(now - swing) < period * 4 then
                on_shot(swing)
                if due > now then next_due = due end
            else
                on_shot(now)
            end
        end
        addon_last_swing = swing
    end

    --- Seconds between shots from the weapon, read every few seconds: it
    --- changes when the weapon does. The addon's figure, when it has one,
    --- overrides this in read_addon.
    ---@param player game_object
    ---@return number
    local function read_period(player)
        local now = core.time()
        if (now - period_read_at) < 3 then return period end
        period_read_at = now
        local ok, info = pcall(player.get_unit_ranged_damage, player)
        if ok and type(info) == "table" and type(info.speed) == "number"
            and info.speed > 0.5 and info.speed < 10 then
            period = info.speed
        end
        return period
    end

    -- --- the shot -----------------------------------------------------------

    ctx.on("jcore.spell.cast", function(data)
        if type(data) ~= "table" or not repeat_name then return end
        local ids = book.ids(repeat_name)
        if not ids then return end
        local hit = false
        for i = 1, #ids do
            if ids[i] == data.spell_id then hit = true break end
        end
        if not hit then return end

        local player = units.player()
        if not player then return end
        if data.caster then
            local ok_a, a = pcall(data.caster.get_guid, data.caster)
            local ok_b, b = pcall(player.get_guid, player)
            if ok_a and ok_b and a ~= b then return end
        end

        on_shot(core.time())
        log.fmt("trace", "weave: %s went out", repeat_name)
    end)

    ctx.on("jcore.combat.leave", function()
        last_shot, next_due = 0, 0
    end)

    -- --- the tick -----------------------------------------------------------

    local function tick()
        if not P.master_on() or not P.opt("rot_enabled", false) or not P.rotation_active() then
            repeat_name = nil
            return
        end
        repeat_name = repeat_spell()
        if not repeat_name then return end
        if not combat.in_combat() then return end
        local player = units.player()
        if not player then return end
        period = read_period(player)
        read_addon(core.time())
    end

    -- A few times a second is plenty for a readout; nothing here acts.
    ctx.tick(tick, { interval = 0.2, priority = 55 })

    -- --- readouts -----------------------------------------------------------

    --- Kept for callers from the holding revisions: nothing is ever held.
    ---@return boolean
    function M.holding() return false end

    --- Seconds until the next shot is due, math.huge when unknown.
    ---@return number
    function M.next_shot_in()
        if next_due == 0 then return math.huge end
        return math.max(0, next_due - core.time())
    end

    --- When the last real shot went out, 0 when none has been seen.
    ---@return number
    function M.last_shot_at() return last_shot end

    function M.stats()
        return {
            spell = repeat_name,
            period = period,
            aim = aim,
            shots = shots,
            timed = next_due > 0,
        }
    end

    return M
end

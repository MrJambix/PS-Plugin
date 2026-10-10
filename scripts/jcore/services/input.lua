-- JCore / input -- acting on the world, with the shared controls arbitrated.
--
-- Depends on: util, log, cache, events, units, cast.
--
-- Casting already has an arbiter because two plugins wanting the same global
-- cooldown is an obvious conflict. Movement is the same problem and is
-- usually left unsolved: a follow plugin holding move-forward and an evade
-- plugin strafing left produce a character that walks diagonally into a wall,
-- and neither plugin is wrong on its own.
--
-- So the exclusive controls are leased. A plugin acquires a channel at a
-- priority, holds it for as long as it keeps asking, and is preempted by
-- anything that outranks it. Losing a lease is normal and needs no handling --
-- but a plugin that WAS holding movement keys down when it lost gets those
-- keys released for it, because a preempted plugin that never runs again would
-- otherwise leave the character running into terrain for ever.
--
-- CHANNELS
--   movement  -- the direction keys and the movement enable/disable flag
--   facing    -- look_at, turning, pitch
--   target    -- set_target and set_focus
--   camera    -- cursor capture and camera state
--
-- Reads (key state, cursor position) and one-shot world interactions (loot,
-- skin, interact) are NOT leased. They do not conflict with each other the way
-- a held key does, and putting them behind a lease would mean a plugin has to
-- take movement just to loot a corpse.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local events = rt.events
    local units = rt.units
    local log = rt.log.for_tag("JCore/input")

    local try = cache.try
    local try_bool = cache.try_bool

    local M = {}

    M.PRIORITY = rt.cast.PRIORITY

    M.CHANNEL = {
        MOVEMENT = "movement",
        FACING   = "facing",
        TARGET   = "target",
        CAMERA   = "camera",
    }

    -- A lease with no renewal is dropped after this long. It is the safety net
    -- for a plugin that acquires movement and then errors before releasing:
    -- without it, that channel is held for the rest of the session.
    local LEASE_TIMEOUT = 1.0

    local leases = {}      -- channel -> { owner, priority, until_time, reason }
    local held_keys = {}   -- owner -> { key_name -> true }, what we pressed

    -- --- leases -------------------------------------------------------------

    local function expire(channel)
        local lease = leases[channel]
        if lease and core.time() > lease.until_time then
            M.release(channel, lease.owner)
            return nil
        end
        return lease
    end

    --- Who holds a channel right now, or nil.
    ---@param channel string
    ---@return table|nil
    function M.holder(channel)
        return expire(channel)
    end

    --- Takes a channel, or renews it if already held by this owner.
    ---
    --- Call it every tick you want the channel. The lease expires on its own
    --- if you stop, which is what makes a crashed or unloaded plugin give
    --- movement back rather than keeping it for ever.
    ---@param channel string
    ---@param owner string
    ---@param priority? number
    ---@param reason? string
    ---@return boolean granted
    function M.acquire(channel, owner, priority, reason)
        priority = priority or M.PRIORITY.ROTATION
        local now = core.time()
        local lease = expire(channel)

        if lease and lease.owner ~= owner then
            -- Strictly greater, so a tie leaves the incumbent in place. Equal
            -- priorities alternating every frame would make the channel
            -- useless to both of them.
            if priority <= lease.priority then return false end

            log.fmt("debug", "%s preempted %s on %s (p%d over p%d)",
                owner, lease.owner, channel, priority, lease.priority)
            M.release(channel, lease.owner)
        end

        leases[channel] = {
            owner      = owner,
            priority   = priority,
            reason     = reason,
            until_time = now + LEASE_TIMEOUT,
        }
        return true
    end

    --- Gives a channel back. Releasing one you do not hold is a no-op, not an
    --- error, so a plugin can release unconditionally in its teardown.
    ---@param channel string
    ---@param owner string
    function M.release(channel, owner)
        local lease = leases[channel]
        if not lease then return end
        if owner and lease.owner ~= owner then return end

        leases[channel] = nil

        if channel == M.CHANNEL.MOVEMENT then
            M._release_keys(lease.owner)
            M._unhold(lease.owner)
        end

        events.emit("jcore.input.released", channel, lease.owner)
    end

    --- Drops every lease an owner holds. Called on unregister.
    ---@param owner string
    function M.release_all(owner)
        for channel, lease in pairs(leases) do
            if lease.owner == owner then M.release(channel, owner) end
        end
        M._release_keys(owner)
    end

    ---@param channel string
    ---@param owner string
    ---@return boolean
    function M.holds(channel, owner)
        local lease = expire(channel)
        return lease ~= nil and lease.owner == owner
    end

    -- --- movement keys ------------------------------------------------------
    --
    -- Every held key is recorded against its owner so a preemption can undo
    -- it. The stop call is paired with the start call by name; getting that
    -- mapping wrong is how a character ends up permanently strafing.

    local KEY_STOP = {
        forward    = core.input.move_forward_stop,
        backward   = core.input.move_backward_stop,
        left       = core.input.strafe_left_stop,
        right      = core.input.strafe_right_stop,
        turn_left  = core.input.turn_left_stop,
        turn_right = core.input.turn_right_stop,
        up         = core.input.move_up_stop,
        down       = core.input.move_down_stop,
        descend    = core.input.descend_stop,
    }

    local KEY_START = {
        forward    = core.input.move_forward_start,
        backward   = core.input.move_backward_start,
        left       = core.input.strafe_left_start,
        right      = core.input.strafe_right_start,
        turn_left  = core.input.turn_left_start,
        turn_right = core.input.turn_right_start,
        up         = core.input.move_up_start,
        down       = core.input.move_down_start,
        descend    = core.input.descend_start,
    }

    --- Releases every key an owner is holding. Internal; called on lease loss.
    ---@param owner string
    function M._release_keys(owner)
        local held = held_keys[owner]
        if not held then return end
        for key in pairs(held) do
            try(KEY_STOP[key])
        end
        held_keys[owner] = nil
    end

    --- Presses or releases a movement key, if the owner holds movement.
    ---@param owner string
    ---@param key string One of the KEY_START names.
    ---@param down boolean
    ---@return boolean acted
    function M.set_key(owner, key, down)
        if not M.holds(M.CHANNEL.MOVEMENT, owner) then return false end

        local fn = down and KEY_START[key] or KEY_STOP[key]
        if type(fn) ~= "function" then return false end

        local held = held_keys[owner]
        if down then
            if not held then
                held = {}
                held_keys[owner] = held
            end
            -- Re-pressing a key that is already down is at best wasted and at
            -- worst a stutter, so the held set doubles as a dedupe.
            if held[key] then return true end
            held[key] = true
        elseif held then
            if not held[key] then return true end
            held[key] = nil
        end

        try(fn)
        return true
    end

    ---@param owner string
    function M.stop_moving(owner)
        M._release_keys(owner)
    end

    -- --- the movement lock --------------------------------------------------
    --
    -- Pressing keys moves the character; this is the other direction, holding
    -- it STILL against the player's own keys for a moment -- the half-second
    -- an Auto Shot needs. It lives behind the movement lease like the keys
    -- do, so losing the lease lifts the lock, and the lock can never outlive
    -- the plugin that took it.

    local holding_owner = nil

    --- Lifts the lock if this owner holds it. Internal; called on lease loss.
    ---@param owner string
    function M._unhold(owner)
        if holding_owner ~= owner then return end
        holding_owner = nil
        try(core.input.enable_movement)
    end

    --- Holds the character still (on) or lets it move again (off). Needs the
    --- movement lease. The client keeps the player's keys: movement resumes
    --- on release without them being pressed again.
    ---@param owner string
    ---@param on boolean
    ---@return boolean acted
    function M.hold(owner, on)
        if on then
            if not M.holds(M.CHANNEL.MOVEMENT, owner) then return false end
            if holding_owner == owner then return true end
            holding_owner = owner
            try(core.input.disable_movement, true)
            return true
        end
        if holding_owner ~= owner then return false end
        M._unhold(owner)
        return true
    end

    ---@return string|nil owner
    function M.holding()
        return holding_owner
    end

    --- Everything stops, every lease drops. The panic button, and what the
    --- core calls when the player dies.
    function M.stop_all()
        if holding_owner then
            holding_owner = nil
            try(core.input.enable_movement)
        end
        for owner in pairs(held_keys) do
            M._release_keys(owner)
        end
        for channel, lease in pairs(leases) do
            M.release(channel, lease.owner)
        end
        try(core.input.cancel_spells)
    end

    -- --- facing -------------------------------------------------------------

    ---@param owner string
    ---@param point vec3
    ---@return boolean acted
    function M.look_at(owner, point)
        if not point then return false end
        if not M.holds(M.CHANNEL.FACING, owner) then return false end
        try(core.input.look_at, point)
        return true
    end

    ---@param owner string
    ---@param point vec3
    ---@return boolean acted
    function M.look_at_3d(owner, point)
        if not point then return false end
        if not M.holds(M.CHANNEL.FACING, owner) then return false end
        try(core.input.look_at_3d, point)
        return true
    end

    ---@param owner string
    ---@param unit game_object
    ---@return boolean acted
    function M.face(owner, unit)
        local pos = units.position(unit)
        if not pos then return false end
        return M.look_at(owner, pos)
    end

    ---@param owner string
    ---@param radians number
    ---@return boolean acted
    function M.set_pitch(owner, radians)
        if not M.holds(M.CHANNEL.FACING, owner) then return false end
        try(core.input.set_pitch, radians)
        return true
    end

    -- --- targeting ----------------------------------------------------------

    ---@param owner string
    ---@param unit game_object
    ---@return boolean acted
    function M.set_target(owner, unit)
        if not unit then return false end
        if not M.holds(M.CHANNEL.TARGET, owner) then return false end
        -- Setting the target to what it already is still costs a round trip
        -- and can interrupt a targeting animation, so skip the no-op.
        local current = rt.player and rt.player.target()
        if current == unit then return true end
        try(core.input.set_target, unit)
        return true
    end

    ---@param owner string
    ---@param unit game_object
    ---@return boolean acted
    function M.set_focus(owner, unit)
        if not unit then return false end
        if not M.holds(M.CHANNEL.TARGET, owner) then return false end
        try(core.input.set_focus, unit)
        return true
    end

    -- --- unleased actions ---------------------------------------------------
    --
    -- One-shot interactions with the world. Two plugins looting the same
    -- corpse is a duplicate call, not a conflict, so none of these takes a
    -- lease.

    ---@param unit game_object
    ---@param auto_loot? boolean
    function M.loot(unit, auto_loot)
        return try(core.input.loot_object, unit, auto_loot ~= false)
    end

    ---@param unit game_object
    function M.skin(unit) return try(core.input.skin_object, unit) end

    ---@param object game_object
    function M.use_object(object) return try(core.input.use_object, object) end

    ---@param object game_object
    function M.interact(object) return try(core.input.interact_with_object, object) end

    function M.jump() return try(core.input.jump) end
    function M.dismount() return try(core.input.dismount) end
    function M.stop_attack() return try(core.input.stop_attack) end
    function M.cancel_spells() return try(core.input.cancel_spells) end
    function M.clear_afk() return try(core.input.clear_afk) end
    function M.release_spirit() return try(core.input.release_spirit) end
    function M.resurrect() return try(core.input.resurrect_corpse) end

    ---@param mount_index integer
    function M.mount(mount_index) return try(core.input.mount, mount_index) end

    --- False when the client cannot cancel an aura this way. On Forever a core
    --- before 2026-10-06 looks the aura up through UnitBuff, which that client
    --- does not have, so it would silently do nothing; saying so lets a caller
    --- fall back (or stop waiting for the aura to drop). From that core on it
    --- works there (world.client().cancel_buff) and the native is called.
    ---@param buff_ptr any From a unit's aura row.
    ---@return boolean|nil
    function M.cancel_buff(buff_ptr)
        local world = rt.world
        if world and world.client and not world.client().cancel_buff then
            log.once("warn", "cancel_buff_forever",
                "cancel_buff does nothing on this client (Forever has no UnitBuff, and this core is older than 2026-10-06); auras are left on")
            return false
        end
        return try(core.input.cancel_buff, buff_ptr)
    end

    -- --- pet ----------------------------------------------------------------

    M.pet = {}

    ---@param target game_object
    function M.pet.attack(target) return try(core.input.pet_attack, target) end

    ---@param spell_id integer
    ---@param target game_object
    function M.pet.cast(spell_id, target)
        return try(core.input.pet_cast_target_spell, spell_id, target)
    end

    ---@param spell_id integer
    ---@param position vec3
    function M.pet.cast_position(spell_id, position)
        return try(core.input.pet_cast_position_spell, spell_id, position)
    end

    ---@param position vec3
    function M.pet.move_to(position) return try(core.input.pet_move_position, position) end

    function M.pet.follow()    return try(core.input.set_pet_follow) end
    function M.pet.wait()      return try(core.input.set_pet_wait) end
    function M.pet.passive()   return try(core.input.set_pet_passive) end
    function M.pet.defensive() return try(core.input.set_pet_defensive) end
    function M.pet.aggressive() return try(core.input.set_pet_aggressive) end
    function M.pet.assist()    return try(core.input.set_pet_assist) end

    -- --- reads --------------------------------------------------------------

    ---@param key integer Virtual key code.
    ---@return boolean
    function M.is_key_pressed(key)
        return try_bool(core.input.is_key_pressed, key)
    end

    --- True while a text box has focus. Check it before reacting to any key:
    --- a user typing in chat should not trigger a keybind.
    ---@return boolean
    function M.is_typing()
        return try_bool(core.is_textbox_focused)
    end

    ---@return vec2|nil
    function M.cursor_position()
        return try(core.get_cursor_position)
    end

    ---@return number
    function M.mouse_wheel_delta()
        return try(core.get_mouse_wheel_delta) or 0
    end

    -- --- lifecycle ----------------------------------------------------------

    --- Expires stale leases. Called once per tick by the runtime, so a lease
    --- times out even when nobody asks about that channel.
    function M._poll()
        for channel in pairs(leases) do
            expire(channel)
        end
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local rows = {}
        for channel, lease in pairs(leases) do
            rows[#rows + 1] = {
                channel   = channel,
                owner     = lease.owner,
                priority  = lease.priority,
                reason    = lease.reason,
                remaining = lease.until_time - core.time(),
            }
        end
        util.stable_sort_by(rows, function(row) return row.channel end)
        return { leases = rows, holding_keys = util.count(held_keys) }
    end

    return M
end

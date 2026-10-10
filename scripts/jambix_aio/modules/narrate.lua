-- Jambix AIO / narrate -- tell the player what happened and WHY.
--
-- ON "VOICE": there is no text-to-speech anywhere in this API. The whole
-- audio surface is core.play_sound_by_id, which plays a sound KIT by numeric
-- id -- a fixed set of existing game sounds, with no way to synthesise
-- speech or play an arbitrary file. Spoken narration is therefore not
-- possible from inside a plugin, and pretending otherwise would mean shipping
-- something that silently does nothing.
--
-- What IS possible, and is what this module does:
--   * an on-screen notification carrying the reason, via
--     core.graphics.add_notification -- the same channel the core uses
--   * a distinct sound CUE per severity, so danger and information do not
--     sound alike and the screen does not have to be read to know which
--     arrived
--
-- WHY A REASON AND NOT JUST AN EVENT
-- "Cast Taunt" tells you nothing you could not see. "Taunt: Mob B is hitting
-- the healer" tells you whether the plugin was right. Every narration carries
-- the reason the decision was made, because a rotation you cannot audit is
-- one you have to trust blindly.

return function(P)
    local ctx, log = P.ctx, P.log

    local M = {}

    -- Severity decides the colour, the sound and whether it can be silenced.
    -- `danger` is deliberately not rate-limited into silence: the one that
    -- matters must not be swallowed because three others arrived first.
    local SEVERITY = {
        danger  = { rgb = { 235,  70,  70 }, sound = 8959, window = 0.0, duration = 6 },
        warn    = { rgb = { 240, 180,  60 }, sound = 8959, window = 3.0, duration = 5 },
        action  = { rgb = { 120, 200, 255 }, sound = nil,  window = 2.0, duration = 3 },
        info    = { rgb = { 180, 180, 190 }, sound = nil,  window = 5.0, duration = 3 },
    }

    local last_at = {}      -- key -> time
    local history = {}      -- recent lines, for the debug page
    local HISTORY_MAX = 12

    local function colour(rgb)
        return P.color(rgb[1], rgb[2], rgb[3], 255)
    end

    --- Says one thing.
    ---
    --- `key` is the throttle bucket: several sources reporting the same kind
    --- of thing share one, so a fight with four adds does not produce four
    --- identical banners.
    ---
    ---@param severity string  danger | warn | action | info
    ---@param title string     short, shown as the notification label
    ---@param why string       the reason. This is the point of the module.
    ---@param key? string      throttle bucket, defaults to the title
    ---@return boolean said
    function M.say(severity, title, why, key)
        if not P.opt("narrate_enabled", true) then return false end

        -- An unrecognised severity is NORMALISED, not merely styled as info.
        -- The switches below test the severity string, so a caller passing
        -- anything not in the table used to land in the "no switch matches"
        -- gap and produce a banner that no setting could turn off.
        if not SEVERITY[severity] then severity = "info" end
        local style = SEVERITY[severity]

        -- Each severity has its own switch, because the useful setting is
        -- "warn me about danger but stop telling me every ability".
        if severity == "action" and not P.opt("narrate_actions", false) then return false end
        if severity == "info" and not P.opt("narrate_info", false) then return false end
        if severity == "warn" and not P.opt("narrate_warnings", true) then return false end

        local now = core.time()
        local bucket = key or title
        if style.window > 0 and last_at[bucket]
            and (now - last_at[bucket]) < style.window then
            return false
        end
        last_at[bucket] = now

        local ok = pcall(core.graphics.add_notification,
            "jambix_" .. bucket,          -- unique id, so it replaces its own
            title,
            why,
            style.duration,
            colour(style.rgb))

        if not ok then
            -- The notification surface is the only output; if it is missing
            -- the log still carries the reason, which is better than losing it.
            log.fmt("info", "%s: %s", title, why)
        end

        if style.sound and P.opt("narrate_sound", true) then
            pcall(core.play_sound_by_id, style.sound)
        end

        history[#history + 1] = { at = now, severity = severity, title = title, why = why }
        if #history > HISTORY_MAX then table.remove(history, 1) end

        ctx.emit("jambix.aio.narrated", { severity = severity, title = title, why = why })
        return true
    end

    function M.history()
        return history
    end

    --- Recent lines, newest first, for the debug readout.
    ---@param limit? integer
    ---@return string[]
    function M.recent(limit)
        local out = {}
        local n = math.min(limit or 6, #history)
        for i = #history, #history - n + 1, -1 do
            local row = history[i]
            out[#out + 1] = string.format("%5.0fs  [%s] %s -- %s",
                core.time() - row.at, row.severity, row.title, row.why)
        end
        return out
    end

    -- --- wiring -------------------------------------------------------------
    --
    -- Everything below turns an existing decision into an explanation. None of
    -- these events were added for narration; they already existed because the
    -- modules that make the decisions publish them.

    ctx.on("jambix.aio.sense", function(observation)
        if type(observation) ~= "table" then return end
        M.say(observation.severity or "warn",
            observation.title or "Notice",
            observation.why or "", observation.kind)
    end)

    ctx.on("jambix.aio.threat", function(data)
        if type(data) ~= "table" then return end
        M.say("danger", data.reason or "Threat",
            string.format("%s (level %d) is %.0f yards away",
                data.name or "?", data.level or 0, data.distance or 0),
            "threat")
    end)

    ctx.on("jambix.aio.hc_adds", function(count)
        M.say("danger", "Adds",
            string.format("%d enemies engaged -- more than the pull started with", count),
            "adds")
    end)

    ctx.on("jambix.aio.hc_breath", function(fraction)
        M.say("danger", "Drowning",
            string.format("breath at %.0f%%", (fraction or 0) * 100), "breath")
    end)

    ctx.on("jambix.aio.hc_item", function(data)
        if type(data) ~= "table" then return end
        M.say("warn", "Emergency item",
            string.format("used a %s: %s", data.kind or "?", data.reason or ""), "hc_item")
    end)

    ctx.on("jambix.aio.rotation_stuck", function(name)
        M.say("warn", "Ability skipped",
            string.format("%s said it was castable but never fired; backing off", name),
            "stuck")
    end)

    ctx.on("jambix.aio.pet_designated", function(data)
        if type(data) ~= "table" then return end
        M.say("action", "Pet", "sent in to " .. (data.reason or "attack"), "pet")
    end)

    ctx.on("jambix.aio.target_switched", function()
        M.say("action", "Target", "switched to a better target", "target")
    end)

    ctx.on("jambix.aio.rest", function(data)
        if type(data) ~= "table" then return end
        M.say("info", "Resting",
            data.kind == "drink" and "drinking to refill mana" or "eating to heal up",
            "rest")
    end)

    ctx.on("jambix.aio.class_detected", function(name)
        M.say("info", "Class", tostring(name) .. " rotation loaded", "class")
    end)

    -- The cast log, when the player asks for that much detail. Off by default
    -- because it narrates every global cooldown.
    ctx.on("jcore.cast.sent", function(request)
        if type(request) ~= "table" then return end
        if request.owner ~= ctx.id then return end
        M.say("action", request.reason or "Cast",
            "priority " .. tostring(request.priority), "cast")
    end)

    return M
end

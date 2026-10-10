-- Jambix AIO / world -- gathering, looting, and the loot window.
--
-- What to DRAW and what to TOUCH were always two halves of this file, and only
-- the second half is left. The overlay's half moved into modules/esp/, which
-- walks units and objects once and publishes the lists this file consumes.
--
-- They are separate settings on purpose. Seeing every herb on the map is
-- useful on its own; walking up and clicking them is a different decision with
-- a different risk profile, so "show herbs" never implies "gather herbs" --
-- which is why the collector fills the node list whether or not the node mark
-- is switched on.

return function(P)
    local ctx, log = P.ctx, P.log
    local actions = P.actions

    local M = {}

    -- --- classification (delegated) -----------------------------------------

    --- Which category a world object belongs to, or nil for noise.
    ---
    --- Kept here because the debug dump calls it by this name. The answer, and
    --- the cache behind it, live in modules/esp/classify.lua.
    ---@param obj game_object
    ---@param guid string
    ---@return string|nil kind
    ---@return string name
    function M.classify_object(obj, guid)
        return P.esp_classify.object(obj, guid)
    end

    -- --- automation ---------------------------------------------------------

    --- Nearest candidate from a list that is in reach and ready to retry.
    -- skip_skin: a corpse listed only because it can be skinned (its loot
    -- taken already) is left alone while skinning is off (1.55.4). Pressed
    -- as "loot" it had nothing to give -- on Forever that right-click starts
    -- Skinning instead -- and three presses later it was given up on.
    local function nearest_actionable(list, reach, skip_skin)
        local best, best_distance = nil, math.huge
        for i = 1, #list do
            local entry = list[i]
            if entry.distance <= reach
                and entry.distance < best_distance
                and not (skip_skin and entry.skinnable)
                and actions.is_ready(entry.guid) then
                best, best_distance = entry, entry.distance
            end
        end
        return best
    end

    --- One automation step. Deliberately does AT MOST ONE thing per call: the
    --- game accepts one interaction at a time, and the ordering below is the
    --- priority when several are possible.
    -- Where JCore's API recorder runs (Forever): every few seconds that a
    -- corpse is listed for looting and none is being looted, one line says
    -- why -- blocked (in combat, moving, casting, a window open), out of
    -- reach, or waiting on a retry or the blacklist (1.55.1).
    -- Read live (1.60.0): the recorder is Jambix Debug's, which may attach
    -- after this module loads, and JCore then sets the flag on the same table.
    local client_flags = nil
    do
        local world = ctx and ctx.world
        local ok, c = pcall(function() return world and world.client and world.client() end)
        if ok and type(c) == "table" then client_flags = c end
    end
    local why_at = -1e9
    local function why_not(reason, reach)
        if not (client_flags and client_flags.recording == true) or (core.time() - why_at) < 5 then return end
        local list = P.opt("autoloot_on", false) and P.esp.corpses() or {}
        local skin = P.opt("autoloot_skin", false)
        local nearest, ready, listed = nil, 0, 0
        for i = 1, #list do
            local e = list[i]
            if skin or not e.skinnable then
                listed = listed + 1
                if not nearest or e.distance < nearest.distance then nearest = e end
                if actions.is_ready(e.guid) then ready = ready + 1 end
            end
        end
        if listed == 0 then return end
        why_at = core.time()
        pcall(ctx.emit, "jcore.recorder.trace", string.format(
            "auto-loot: %d corpse(s) listed, nearest %.1f yd (reach %.1f), %d ready; not looting: %s",
            listed, nearest and nearest.distance or -1, reach or 0, ready, reason))
    end

    local function automation_tick()
        if not P.master_on() then return end
        local blocked = actions.blocked_reason()
        if blocked then
            why_not(blocked, P.opt("interact_range", 4.5))
            return
        end

        -- Interact range is ~5 yards in game. Anything larger just produces
        -- failed attempts that count toward the blacklist.
        local reach = P.opt("interact_range", 4.5)

        -- 1. Loot corpses. Highest priority: loot despawns, nodes do not.
        if P.opt("autoloot_on", false) then
            local corpse = nearest_actionable(P.esp.corpses(), reach, not P.opt("autoloot_skin", false))
            if corpse then
                if corpse.skinnable and P.opt("autoloot_skin", false) then
                    actions.perform(corpse.obj, "skin", "skin")
                else
                    actions.perform(corpse.obj, "loot", "corpse")
                end
                return
            end
            why_not("none within reach and ready", reach)
        end

        -- 2. Gathering nodes.
        local wants = {}
        if P.opt("gather_herbs", false) then wants.herb = true end
        if P.opt("gather_ore", false) then wants.ore = true end
        if P.opt("gather_containers", false) then wants.container = true end

        if next(wants) then
            local candidates = {}
            local visible = P.esp.nodes()
            for i = 1, #visible do
                local entry = visible[i]
                -- Not a node your skill is short of (1.88.0: the ESP marks it
                -- "Requires Skill N"; one you cannot gather at all is not listed).
                if wants[entry.kind] and not entry.requires then candidates[#candidates + 1] = entry end
            end
            local node = nearest_actionable(candidates, reach)
            if node then
                actions.perform(node.obj, "use", node.name)
                return
            end
        end
    end

    -- Runs in the render phase, after the collector that populates the two
    -- lists, so the handles it acts on were collected this same frame.
    -- Throttled by the scheduler rather than a timestamp check in here.
    ctx.render(automation_tick, { interval = 0.1, priority = 180 })

    -- --- loot before the next pull (1.57.1) ---------------------------------
    --
    -- The 1.57.0 trace (Forever, 2026-10-03): a Crag Boar's corpse was
    -- pressed at 444.5 and nothing opened; by 447.6 the rotation had opened on
    -- a Large Crag Boar 33 yd off with Serpent Sting -- a hunter pulls what is
    -- in shot range the moment it is out of combat (the class's may_open) --
    -- and the second press, made under that pull, brought nothing either. The
    -- corpse opened at the first press after that fight. A cast cancels the
    -- interaction under way, and the new fight blocks auto-loot ("in combat")
    -- until it is over. So while auto-loot has a corpse to work -- one in
    -- reach it will press, or a press still waiting on its window -- the
    -- rotation starts no new fight (rotation.may_engage_unit asks this, and
    -- the pet rides that). A mob that comes for us is a fight anyway, and the
    -- engage key still pulls. The hold ends with the corpse: looted, given up
    -- on after its three tries, out of reach, auto-loot blocked for a reason
    -- that will not pass by itself (mounted, typing) -- and LOOTING_MAX
    -- seconds after it began on one corpse, whatever the reason.
    local LOOTING_MAX = 10.0
    local TRANSIENT = { moving = true, casting = true, channelling = true, ["loot window open"] = true }
    local held = nil          -- { guid, since }: the corpse the hold is for

    --- Is auto-loot working a corpse the rotation should not pull over?
    ---@return boolean
    function M.looting()
        if not P.master_on() or not P.opt("autoloot_on", false) then
            held = nil
            return false
        end
        local jloot_open = ctx.loot
        if jloot_open and jloot_open.opening then
            local ok, waiting = pcall(jloot_open.opening)
            if ok and waiting then return true end
        end
        local reach = P.opt("interact_range", 4.5)
        local skin = P.opt("autoloot_skin", false)
        local list = P.esp.corpses()
        local best = nil
        for i = 1, #list do
            local e = list[i]
            if e.distance <= reach and (skin or not e.skinnable) and not actions.is_blacklisted(e.guid)
                and (not best or e.distance < best.distance) then
                best = e
            end
        end
        if not best then
            held = nil
            return false
        end
        local blocked = actions.blocked_reason()
        if blocked and not TRANSIENT[blocked] then
            held = nil
            return false
        end
        local now = core.time()
        if not held or held.guid ~= best.guid then held = { guid = best.guid, since = now } end
        return (now - held.since) <= LOOTING_MAX
    end

    -- --- loot window drain --------------------------------------------------
    --
    -- loot_object with auto-loot true normally empties the window itself. It
    -- does not when a bind-on-pickup confirmation is raised, and the window
    -- then sits open blocking every further interaction until something
    -- answers it -- which is exactly the "auto-loot stopped working after a
    -- while" failure. The core latches the slot for us; confirm it.

    ctx.on("jcore.game_event.LOOT_BIND_CONFIRM", function(args)
        if not P.master_on() or not P.opt("autoloot_on", false) then return end
        if not P.opt("autoloot_confirm_bop", true) then return end

        -- LOOT_BIND_CONFIRM reports WoW's 1-based slot while confirm_loot_slot
        -- takes the 0-based index the rest of the loot API uses.
        local slot = args and args[1]
        if type(slot) ~= "number" then return end
        pcall(core.input.confirm_loot_slot, slot - 1)
        log.fmt("debug", "confirmed BoP loot in slot %d", slot)
    end)

    --- A loot window left open past this long is stuck. Closing it costs
    --- nothing when it was going to close anyway and unblocks everything when
    --- it was not.
    ---
    --- FOREVER (1.54.2): THE WINDOW OPENS AND NOTHING IS TAKEN. loot_object
    --- does open the corpse there (it walks the character up to it first),
    --- and LOOT_OPENED even says auto-loot -- but the items stay. In session
    --- 31 (2026-10-03) one corpse's window opened five times with its Rough
    --- Stone still in it the second and third time, and a nameless slot
    --- (coins: get_loot_is_gold answers false for everything there) on every
    --- one; the closer below shut it each time, the corpse kept its loot, and
    --- the retries ran into the blacklist. So on Forever the slots are taken
    --- here, with loot_item, in two passes (about 0.3 s and 1.3 s after the
    --- window opened: it is not filled on the frame that opens it), before the
    --- closer. Slots 0 to the count minus 1, as the contract numbers them
    --- (1.78.2): the slot at the count holds nothing on Forever, and
    --- loot_item raised "specified invalid slot" for it.
    --- Each pass, and how the window ended, goes to the recorder trace as a
    --- "loot window:" line. Era: unchanged, no extra read.
    local loot_open_since = 0
    local took = 0            -- passes over the open window so far
    -- JCore says whether a window needs its slots taken by hand (Forever,
    -- 1.6.0) and takes them; elsewhere it says no and nothing changes.
    local jloot = ctx.loot
    local function needs_taking()
        if not (jloot and jloot.window_needs_taking) then return false end
        local ok, yes = pcall(jloot.window_needs_taking)
        return ok and yes == true
    end

    local function trace(text)
        pcall(ctx.emit, "jcore.recorder.trace", text)
    end

    local function slot_names(count)
        local names = {}
        for index = 0, count - 1 do
            local ok, name = pcall(core.game_ui.get_loot_item_name, index)
            if ok and type(name) == "string" and name ~= "" then names[#names + 1] = name end
        end
        -- A slot with no name is the coins (get_loot_is_gold answers false
        -- for everything on Forever), so the line says so (1.55.4).
        local unnamed = count - #names
        if unnamed == 1 then
            names[#names + 1] = "coins"
        elseif unnamed > 1 then
            names[#names + 1] = unnamed .. " unnamed (coins?)"
        end
        return #names > 0 and (": " .. table.concat(names, ", ")) or ""
    end

    ctx.tick(function()
        if not P.master_on() or not P.opt("autoloot_on", false) then return end
        local forever = needs_taking()
        if not forever and not P.opt("autoloot_force_close", true) then return end

        local ok, count = pcall(core.game_ui.get_loot_item_count)
        if not ok or not count or count == 0 then
            if forever and took > 0 then
                trace(string.format("loot window: emptied after %d pass(es)", took))
            end
            loot_open_since, took = 0, 0
            return
        end

        local now = core.time()
        if loot_open_since == 0 then
            loot_open_since = now
            return
        end
        local open_for = now - loot_open_since

        if forever and took < 2 and open_for >= 0.3 + took then
            took = took + 1
            local names = slot_names(count)
            pcall(jloot.take_window)
            trace(string.format("loot window: %d slot(s)%s; took slots 0-%d (pass %d)", count, names, count - 1, took))
            return
        end

        if not P.opt("autoloot_force_close", true) then return end
        if open_for > P.opt("autoloot_window_timeout", 3.0) then
            pcall(core.input.close_loot)
            if forever then
                trace(string.format("loot window: closed with %d slot(s) left after %d pass(es)", count, took))
            end
            loot_open_since, took = 0, 0
            log.debug("closed a stuck loot window")
        end
    end, { interval = 0.5, deferrable = true })

    -- --- diagnostics --------------------------------------------------------

    --- Kept in the shape the debug page expects. The numbers come from the
    --- collector, which is the one that counted them.
    function M.stats()
        local s = P.esp.stats()
        return {
            nodes = s.nodes,
            corpses = s.corpses,
            by_kind = s.nodes_by_kind or {},
            cached = s.cached_objects or 0,
        }
    end

    return M
end

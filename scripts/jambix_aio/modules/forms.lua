-- Jambix AIO / forms -- stances and shapeshifts, for the classes that have them.
--
-- Generalised from the warrior-only stance module. Warrior stances and druid
-- forms are the same mechanism: an ordered bar of mutually exclusive states,
-- some of which gate abilities.
--
-- DETECTION
-- get_shapeshift_form answers a 1-BASED BAR INDEX, not an identity, and the
-- bar only holds forms you have LEARNED. A level 12 warrior has Battle and
-- Defensive, so Defensive is index 2; Berserker arrives at 30 as index 3. A
-- druid's bar grows the same way. Reading index 2 as "Defensive" is right by
-- luck, not by construction, so the bar is reconstructed from what is trained.
--
-- SWITCHING
-- A warrior stance change destroys rage above a cap. A druid form change costs
-- mana and drops you out of whatever you were in. Neither is free, so the
-- default everywhere is to enter the profile's form once and stay.

return function(P)
    local ctx, log = P.ctx, P.log
    local units = P.units
    local book = P.spellbook

    local M = {}

    -- Ordered list for the active class, installed by the class module.
    local ORDER = {}

    local bar_index, index_name = {}, {}
    local last_switch, last_target = 0, nil

    local function rebuild_bar()
        bar_index, index_name = {}, {}
        local slot = 0
        for i = 1, #ORDER do
            local name = ORDER[i]
            if book.known(name) then
                slot = slot + 1
                bar_index[name] = slot
                index_name[slot] = name
            end
        end
    end

    --- Installs the class's form order. Called when the class is resolved.
    ---@param list string[]|nil
    function M.set_order(list)
        ORDER = list or {}
        rebuild_bar()
    end

    ctx.on("jambix.aio.spellbook_refreshed", rebuild_bar)

    -- FOREVER: A FORM THE CLIENT MAY NOT NAME (1.50.1). get_shapeshift_form
    -- was never seen answering on Forever: the JCore API recorder never
    -- caught a call, because only warriors and druids ask and only a rogue
    -- and a hunter have been played there. If it answers 0 with a form up,
    -- "None" sends maintain() to cast the profile's form every 1.2 s. A
    -- warrior presses the stance it is already in. A druid's form spell is a
    -- TOGGLE, so the druid leaves the form it just entered, every time, and
    -- does nothing else (aio_forever_class_druid_test caught it). So JCore's
    -- player.shapeshift_index() (1.6.0) says nil, "unknown", on Forever until
    -- the read has named a form at least once, and only then believes a 0.
    -- While it says unknown, the form is read from the player's auras (a
    -- form's spell is the aura it puts up), and failing that from our own last
    -- successful form cast, which is watched from the first "unknown" on. On
    -- Era JCore never says unknown: none of this runs, and the read is as it
    -- always was.
    local remembered = nil       -- the form our own last form cast left us in
    local watching = false

    --- A druid form spell leaves the form when cast in it; a stance does not.
    local function toggles(name)
        return name:sub(-5) == " Form"
    end

    local function form_of_spell(spell_id)
        for i = 1, #ORDER do
            local ids = book.ids(ORDER[i])
            if ids then
                for j = 1, #ids do
                    if ids[j] == spell_id then return ORDER[i] end
                end
            end
        end
        return nil
    end

    local function form_from_auras()
        local player = units.player()
        if not player then return nil end
        for i = 1, #ORDER do
            local name = ORDER[i]
            local ids = bar_index[name] and book.ids(name)
            if ids then
                local ok, up = pcall(units.has_aura, player, ids)
                if ok and up then return name end
            end
        end
        return nil
    end

    --- From the first time JCore cannot say: remember our own form casts.
    local function watch()
        if watching or not ctx.on then return end
        watching = true
        ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
            if type(args) ~= "table" or args[1] ~= "player" or #ORDER == 0 then return end
            local name = form_of_spell(tonumber(args[3]))
            if not name then return end
            if toggles(name) and remembered == name then
                remembered = nil
            else
                remembered = name
            end
        end)
        -- Death drops a druid out of its form and a warrior back to its first
        -- stance: what we remembered no longer holds.
        ctx.on("jcore.game_event.PLAYER_DEAD", function() remembered = nil end)
    end

    ---@return string|nil
    function M.current()
        if #ORDER == 0 then return nil end
        local index, unknown = nil, false
        local player_service = ctx.player
        if player_service and player_service.shapeshift_index then
            local ok, i = pcall(player_service.shapeshift_index)
            if ok then index, unknown = i, i == nil end
        else
            local ok, i = pcall(core.spell_book.get_shapeshift_form, false)
            if ok then index = i end
        end
        if unknown then
            watch()
            local seen = form_from_auras() or remembered
            if seen then return seen end
        end
        if not index or index == 0 then
            -- No form active. For a druid that is caster form and is a real
            -- answer; for a warrior it means the API is unavailable, since a
            -- warrior is always in some stance once one is trained.
            return "None"
        end
        return index_name[index]
    end

    ---@param name string
    function M.is(name) return M.current() == name end

    ---@param name string
    function M.known(name) return bar_index[name] ~= nil end

    --- Rage destroyed by switching right now. Zero for classes whose form
    --- change does not burn a resource this way.
    ---@return number
    function M.switch_cost()
        if not P.class_uses_rage or not P.class_uses_rage() then return 0 end
        -- RAGE KEPT THROUGH A STANCE CHANGE (1.80.0). Era: 5 per point of
        -- Tactical Mastery and none without it; this counted 25 more, so a
        -- dance looked 25 rage cheaper than it was. Forever: Tactical Mastery
        -- is a trained passive keeping 10, and the talent (Improved Tactical
        -- Mastery, Era's spell 12295) adds 5 a point.
        local retained
        if P.forever then
            retained = (book.known("Tactical Mastery") and 10 or 0)
                + P.talents.rank("Improved Tactical Mastery") * 5
        else
            retained = P.talents.rank("Tactical Mastery") * 5
        end
        return math.max(0, P.rage() - retained)
    end

    --- Requests a form change through the cast gateway, so it is arbitrated
    --- with everything else and inherits the core's safety handling. Off-GCD:
    --- putting it in the GCD lane would cost an ability every switch.
    ---@param name string
    ---@param reason? string
    function M.switch_to(name, reason)
        if not name or name == "None" or M.is(name) then return false end
        if not M.known(name) then return false end

        local now = core.time()
        if (now - last_switch) < 1.2 then return false end

        local id = book.id(name)
        if not id then return false end

        last_switch, last_target = now, name
        log.fmt("debug", "form -> %s (%s)", name, reason or "rotation")

        return ctx.cast({
            spell_id = id,
            target = units.player(),
            priority = ctx.PRIORITY.UTILITY,
            reason = "form: " .. (reason or name),
            fast = true,
        })
    end

    ---@param desired string
    ---@param acceptable table<string, boolean>|nil
    ---@param allow_dance boolean
    function M.maintain(desired, acceptable, allow_dance)
        local current = M.current()
        if not current then return false end
        if current == desired then return false end

        if acceptable and acceptable[current] then
            if not allow_dance then return false end
            if M.switch_cost() > 10 then return false end
        end

        return M.switch_to(desired, "profile")
    end

    function M.stats()
        local names = {}
        for i = 1, #ORDER do
            if bar_index[ORDER[i]] then
                names[#names + 1] = string.format("%s=%d", ORDER[i]:sub(1, 4), bar_index[ORDER[i]])
            end
        end
        return {
            current = M.current() or "none",
            bar = table.concat(names, " "),
            cost = M.switch_cost(),
            last_target = last_target,
        }
    end

    return M
end

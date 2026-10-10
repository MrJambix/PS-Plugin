-- Jambix AIO / esp -- the overlay package.
--
-- Assembles the four halves of the ESP and presents them as one module:
--
--   roles      what a player does -- tank, healer, damage -- and how sure
--   fight      how a unit fights -- melee, ranged, caster -- learned from
--              what mobs are seen casting, and kept across sessions
--   classify   what a thing is, cached by guid
--   collect    one walk of the world per frame -> entities, threats,
--              corpses, nodes
--   elements   what each entity looks like, one row per mark
--   panels     proximity alerts, the threat panel, off-screen arrows
--
-- Each is loaded through the plugin's own loader and handed the same bundle,
-- with the pieces it depends on already on it -- so the assignment order below
-- is the dependency graph, exactly as in main.lua.

return function(P)
    local ctx = P.ctx

    P.esp_roles    = P.load("modules/esp/roles")(P)
    P.esp_fight    = P.load("modules/esp/fight")(P)
    P.esp_classify = P.load("modules/esp/classify")(P)
    P.esp_collect  = P.load("modules/esp/collect")(P)
    P.esp_elements = P.load("modules/esp/elements")(P)
    P.esp_panels   = P.load("modules/esp/panels")(P)

    local classify = P.esp_classify
    local collect = P.esp_collect
    local elements = P.esp_elements
    local panels = P.esp_panels

    local M = {}

    -- --- Forever has its own ESP -------------------------------------------
    --
    -- The classic ESP was cleared from Forever at the user's request
    -- (2026-10-02, 1.41.0): on Forever it draws nothing and walks nothing --
    -- no marks, alerts, threat panel or arrows, and no per-frame unit pass,
    -- so the lists it publishes stay empty (quest tags, auto-loot and
    -- gathering have nothing to act on there). esp/forever.lua (1.42.0) is
    -- the overlay there instead, built only on reads the API recorder saw
    -- answering on Forever. The modules above are still built, so everything
    -- that holds a reference to them keeps working. Decided once; every other
    -- client runs the classic ESP and never loads esp/forever.lua.
    local off = false
    do
        local world = ctx and ctx.world
        if type(world) == "table" and type(world.client) == "function" then
            local ok, client = pcall(world.client)
            off = ok and type(client) == "table" and client.forever == true
        end
    end
    M.off = off
    local forever = off and P.load("modules/esp/forever")(P) or nil
    M.forever = forever

    local function nothing() end

    -- --- the frame ----------------------------------------------------------

    --- Collects, then paints. One call, because the entity list is only valid
    --- within the frame that built it: the handles in it came from this
    --- frame's sweep, not the last one.
    ---@param visuals boolean Whether the ESP is shown. Collection happens either way.
    ---@param master number Master range, in yards.
    ---@param quest_visuals? boolean With the ESP off: whether the quest and
    ---  guide marks still are (the Quests page's own switches, 1.73.0).
    function M.render(visuals, master, quest_visuals)
        -- RESTEDXP ONLY (1.61.0): the guide's marks and nothing else. The
        -- Forever ESP has no guide marks, so there it draws nothing at all
        -- (it still collects what the automation acts on).
        local rxp_only = P.opt("rxp_only", false) == true
        if off then
            if forever then
                forever.render(visuals and not rxp_only, master, quest_visuals == true and not rxp_only)
            end
            return
        end

        -- Applied here rather than at declaration so a slider moved mid-session
        -- takes effect on the next frame.
        P.draw.set_budget(P.opt("esp_draw_budget", 0))
        P.draw.set_los_budget(P.opt("esp_los_budget", 0))

        -- QUESTS APART FROM THE ESP (1.73.0): with the ESP off, the quest
        -- and guide marks are still drawn when the Quests page has them on,
        -- and nothing else is.
        local quests_only = not visuals and quest_visuals == true
        collect.run(visuals or quests_only, master)
        if not visuals and not quests_only then return end

        elements.begin_frame(quests_only)

        local list = collect.entities()
        for i = 1, collect.count() do
            -- With its rank: the more relevant mark paints on top.
            local e = list[i]
            local cat = e.category
            if rxp_only then
                if cat == "guide" then elements.draw_entity(e, i) end
            elseif not quests_only or cat == "quest" or cat == "guide" then
                elements.draw_entity(e, i)
            end
        end
    end

    -- --- passthroughs -------------------------------------------------------

    -- On Forever the alerts, the threat panel and the arrows are the Forever
    -- ESP's own (esp/forever.lua): the classic ones read the classic
    -- collector's list, which is empty there.
    M.alert_check = off and (forever and forever.alert_check or nothing) or panels.alert_check
    M.draw_threat_panel = off and (forever and forever.draw_threat_panel or nothing) or panels.draw_threat_panel
    M.draw_threat_arrows = off and (forever and forever.draw_threat_arrows or nothing) or panels.draw_threat_arrows
    M.bearing_arrow = off and nothing or panels.bearing_arrow

    -- On Forever the quest paths read the Forever ESP's quest targets
    -- (1.55.4): the classic list is empty there, and no path was drawn.
    M.entities = (off and forever and forever.entities) or collect.entities
    M.count = (off and forever and forever.count) or collect.count
    M.explain = collect.explain
    -- On Forever the classic collector never runs, so the automation's lists
    -- are the Forever ESP's (1.54.0); before that auto-loot and gathering
    -- were handed empty lists there and never acted.
    M.nodes = (off and forever and forever.nodes) or collect.nodes
    M.corpses = (off and forever and forever.corpses) or collect.corpses
    M.detail = collect.detail
    M.classify = classify.unit
    M.fight = P.esp_fight
    M.classify_object = classify.object

    --- The live threat list. A FIELD rather than a function because the old
    --- unit module published one and callers read it directly; it is the same
    --- table every frame, rebuilt in place.
    M.threats = collect.threats

    --- Drops the cached classifications. Quest and guide membership is asked
    --- per frame and never cached, but level, rank and creature type are, and
    --- a unit that levelled or a guide step that advanced should not have to
    --- wait for a zone change.
    function M.invalidate()
        classify.invalidate()
    end

    -- --- diagnostics --------------------------------------------------------

    --- Kept in the shape the debug page expects: `threats` and `cached`.
    function M.stats()
        -- On Forever the page's counters are the Forever ESP's: the classic
        -- collector walks nothing there. It has no detail tiers, so every
        -- mark counts as near. (1.48.0)
        if off and forever and forever.stats then
            local ok, s = pcall(forever.stats)
            if ok and type(s) == "table" then
                return {
                    entities = s.marks or 0, threats = s.threats or 0, nodes = s.nodes or 0,
                    by_lod = { full = s.marks or 0, mid = 0, far = 0 }, cached = 0,
                    forever = s,
                }
            end
        end
        local c = collect.stats()
        local k = classify.stats()
        c.cached = k.cached
        c.cached_units = k.units
        c.cached_objects = k.objects
        return c
    end

    return M
end

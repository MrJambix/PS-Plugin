-- Jambix AIO / esp/collect -- one walk of the world, one list, per frame.
--
-- WHAT THIS REPLACES
-- The unit pass and the world pass each walked their own list and decided,
-- inline, what to draw for each thing they found. Every new mark meant another
-- branch in the middle of the walk, and every mark anyone had ever added was
-- paid for on every unit whether it was switched on or not.
--
-- So the walk now produces DATA and nothing else: one entity per thing worth
-- drawing, sorted by distance, tagged with a detail tier. elements.lua decides
-- what each one looks like. Adding a mark no longer touches this file.
--
-- FOUR OUTPUTS, ONE PASS
--   entities  what the overlay draws
--   threats   what the alerts and the threat panel read
--   corpses   what the loot automation reads
--   nodes     what the gathering automation reads
-- Splitting those into separate passes would mean four walks and four sets of
-- native calls for one answer. They are separate LISTS because they answer
-- different questions -- a node is collected even when its mark is switched
-- off, because hiding the overlay must not silently stop gathering.
--
-- DETAIL TIERS
-- A unit forty yards away and a unit at the edge of a 150-yard rare range are
-- not worth the same number of native calls. `lod` is "full", "mid" or "far",
-- and an element declares the tier it needs. The tiers are ranges, not ranks:
-- turning the falloff off makes everything "full", which is what the overlay
-- did before this file existed.

return function(P)
    local ctx, cfg = P.ctx, P.cfg
    local units = P.units
    local classify = P.esp_classify

    local M = {}

    -- Entity tables are pooled and reused. A forty-unit pull would otherwise
    -- allocate forty tables a frame for values that are rewritten a frame
    -- later, and the collector is the one place in this plugin where that
    -- actually shows up in a profile.
    local pool = {}
    local entities = {}
    local count = 0

    local threats = {}
    local corpses = {}
    local nodes = {}

    M.threats = threats

    -- --- "why is that mob not marked?" --------------------------------------
    --
    -- The overlay has four independent reasons to skip something -- its
    -- category is off, it is beyond that category's range, it is beyond the
    -- master range, or the core's sweep never saw it -- and none of them used
    -- to leave a trace. A field of unmarked mobs looked identical to a broken
    -- overlay, and the only way to tell was to guess at settings.
    --
    -- Off by default because answering it costs a position read for every unit
    -- that was skipped, which is exactly the work skipping them avoided.

    local skipped = { category_off = 0, out_of_range = 0, unclassified = 0 }
    local nearest_skip = { distance = math.huge }

    local function note_skip(name, distance, reason)
        if distance >= nearest_skip.distance then return end
        nearest_skip.distance = distance
        nearest_skip.name = name
        nearest_skip.reason = reason
    end

    local function acquire()
        count = count + 1
        local e = pool[count]
        if not e then
            e = {}
            pool[count] = e
        end
        entities[count] = e
        return e
    end

    local function clear(list)
        for i = #list, 1, -1 do list[i] = nil end
    end

    -- --- detail reads -------------------------------------------------------
    --
    -- What a unit is DOING -- casting, at whom, in combat, crowd-controlled --
    -- as opposed to what it IS, which classify answers on a slow clock.
    --
    -- FIRST FROM THE ENEMIES SERVICE. JCore already reads exactly this for
    -- every attackable unit in the sweep, every tick, nearest first, on its
    -- own budget -- the rotation depends on it, so it is running whether the
    -- overlay asks or not. Reading those rows costs no native call at all,
    -- where reading the unit again would cost six or seven a unit to learn
    -- what the core learned a few milliseconds earlier. Every hostile mark
    -- the overlay draws is in that list, so this is nearly every answer.
    --
    -- THEN OUR OWN READ, for what that service does not track: a unit it
    -- filters out (blacklisted, untargetable) or has not reached yet. Read on
    -- demand, cached briefly, and rationed: the first `reads_left` askers of
    -- a frame get a fresh answer and the rest get the last one.

    local enemies = ctx.enemies
    local detail_cache = {}
    local reads_left = 0
    local DETAIL_TTL = 0.2

    -- The clock for this pass, read once at the top of run(). Every mark used
    -- to read it for itself -- the classifier once per unit, the detail once
    -- per mark -- a native call each, fifty to a hundred a frame in a town.
    local frame_now = 0
    local function clock()
        if frame_now > 0 then return frame_now end
        local ok, t = pcall(core.time)
        return (ok and type(t) == "number") and t or 0
    end

    -- What a corpse holds, by guid, for half a second. Asked of every corpse
    -- in the sweep every frame -- three or four native calls each, mostly to
    -- hear "nothing" from one already looted -- while the answer changes once,
    -- when somebody loots or skins it.
    local loot_cache = {}
    local LOOT_TTL = 0.5

    local function reset(into)
        into.casting = false
        into.channel = false
        into.spell_id = nil
        into.cast_start = nil
        into.cast_end = nil
        into.interruptible = false
        into.target_guid = nil
        into.targeting_me = false
        into.targeting_pet = false
        into.in_combat = false
        into.control = nil
    end

    --- The enemies service's row, in the shape the marks read. Copied rather
    --- than handed out, because a row is rewritten in place by the next poll
    --- and the shape differs; a dozen field copies are free next to a native.
    local function from_row(row, into)
        reset(into)
        into.at = row.detailed_at
        into.source = "enemies"

        local cast = row.casting
        if cast then
            into.casting = true
            into.channel = cast.channel == true
            into.spell_id = cast.spell_id
            into.cast_start = cast.start_at
            into.cast_end = cast.end_at
            into.interruptible = cast.interruptible == true
        end

        into.target_guid = row.target_guid
        into.targeting_me = row.targeting_me == true
        into.targeting_pet = row.targeting_pet == true
        into.in_combat = row.in_combat == true
        -- Loss of control: { spell_id, type, remaining }. The service reads
        -- it four times a second, which is what a "do not break the sheep"
        -- line needs and no more.
        into.control = row.control
        return into
    end

    local function read_detail(entity, into)
        local unit = entity.obj
        reset(into)
        into.at = clock()
        into.source = "own"

        local ok, value

        ok, value = pcall(unit.is_casting_spell, unit)
        if ok and value then
            into.casting = true
            ok, value = pcall(unit.get_active_spell_id, unit)
            if ok then into.spell_id = value end
            ok, value = pcall(unit.get_active_spell_cast_start_time, unit)
            if ok then into.cast_start = value end
            ok, value = pcall(unit.get_active_spell_cast_end_time, unit)
            if ok then into.cast_end = value end
            ok, value = pcall(unit.is_active_spell_interruptable, unit)
            if ok then into.interruptible = value == true end
        else
            ok, value = pcall(unit.is_channelling_spell, unit)
            if ok and value then
                into.casting = true
                into.channel = true
                -- The contract has no interruptible flag for a channel, and
                -- nearly every channel can be kicked. The enemies service
                -- assumes the same; a channel left at false here drew every
                -- Drain Life and Arcane Missiles as "do not bother".
                into.interruptible = true
                ok, value = pcall(unit.get_active_channel_spell_id, unit)
                if ok then into.spell_id = value end
                ok, value = pcall(unit.get_active_channel_cast_start_time, unit)
                if ok then into.cast_start = value end
                ok, value = pcall(unit.get_active_channel_cast_end_time, unit)
                if ok then into.cast_end = value end
            end
        end

        ok, value = pcall(unit.get_target, unit)
        if ok and value then
            local ok_guid, guid = pcall(value.get_guid, value)
            if ok_guid then
                into.target_guid = guid
                into.targeting_me = guid ~= nil and guid == M.player_guid
            end
        end

        ok, value = pcall(unit.is_in_combat, unit)
        if ok then into.in_combat = value == true end

        return into
    end

    --- Cast state, target and combat for an entity, or nil for one that has
    --- none (an object, a corpse). Cheap to call repeatedly: a hostile's
    --- answer is the enemies service's, and anything else is cached and
    --- rationed.
    ---@param entity table
    ---@return table|nil
    ---@param entity table
    ---@param free_only? boolean Answer only from what costs nothing -- the
    --- enemies service's row or an earlier read -- and never spend one of the
    --- frame's own reads. For a mark that is off screen: its ring and line
    --- want to know who it is after, its own block will not be seen.
    function M.detail(entity, free_only)
        if not entity or entity.kind ~= "unit" or entity.dead then return nil end
        local guid = entity.guid
        if not guid then return nil end

        local cached = detail_cache[guid]

        -- A row the service has never read in detail (one past its range,
        -- not reached yet) says nothing; fall through to our own read.
        local row = enemies and enemies.get and enemies.get(guid) or nil
        if row and (row.detailed_at or 0) > 0 then
            cached = cached or {}
            detail_cache[guid] = cached
            return from_row(row, cached)
        end

        local now = clock()
        if cached and cached.source == "own" and (now - cached.at) < DETAIL_TTL then return cached end
        if free_only or reads_left <= 0 then return cached end

        reads_left = reads_left - 1
        cached = cached or {}
        detail_cache[guid] = cached
        return read_detail(entity, cached)
    end

    ctx.on("jcore.unit.removed", function(guid)
        detail_cache[guid] = nil
        loot_cache[guid] = nil
    end)
    ctx.on("jcore.zone.changed", function()
        detail_cache = {}
        loot_cache = {}
    end)

    --- What a corpse holds: lootable, skinnable. See loot_cache.
    local function corpse_state(unit, guid, now)
        local c = loot_cache[guid]
        if c and (now - c.at) < LOOT_TTL then return c.lootable, c.skinnable end
        local lootable = select(2, pcall(unit.can_be_looted, unit)) == true
            or select(2, pcall(unit.has_loot, unit)) == true
        local skinnable = select(2, pcall(unit.can_be_skinned, unit)) == true
            and select(2, pcall(unit.has_skin, unit)) == true
        if c then
            c.at, c.lootable, c.skinnable = now, lootable, skinnable
        else
            loot_cache[guid] = { at = now, lootable = lootable, skinnable = skinnable }
        end
        return lootable, skinnable
    end

    --- Skinnable by YOUR skill (1.67.0): JCore 1.8.5's player.can_skin
    --- against the corpse's level. A corpse left with nothing is not marked
    --- and not handed to the automation (see esp/forever.lua, SKIN ONLY WHAT
    --- YOUR SKILL CAN). An older JCore, or no level, hides nothing.
    local function skin_ok(level)
        local me = ctx.player
        if not (me and me.can_skin) then return true end
        local ok, yes = pcall(me.can_skin, level)
        return not ok or yes == true
    end

    -- --- gathering by YOUR skill (1.88.0) -------------------------------------
    --
    -- The user, 2026-10-08: "Only Show Gatherables that I can Gather with my
    -- skills  If i Cannot then Write (Requires Skill # )". A herb or a vein is
    -- weighed by cfg.gather_verdict against JCore's player.skill:
    --   without the profession   not marked, and not handed to the gatherer
    --   short of what it asks    marked, dimmed, "(Requires Skill N)" on its
    --                            label, and handed on with `requires = N`
    --   enough                   as always
    -- `gather_skill_only` off, an older JCore with no player.skill, or a skill
    -- read that raised: every node as before. A skill is asked once a pass
    -- per profession; JCore keeps the answer five seconds besides.
    local skill_now = {}     -- profession -> level, false (none), or true (could not ask)
    local gather_filter = false
    local gather_hidden = 0

    local function skill_of(prof)
        local s = skill_now[prof]
        if s == nil then
            local ok, level = pcall(ctx.player.skill, prof)
            if not ok then
                s = true
            elseif type(level) == "number" then
                s = level
            else
                s = false
            end
            skill_now[prof] = s
        end
        -- A read that raised is no reason to hide a node: as enough.
        if s == true then return math.huge end
        return s or nil
    end

    --- "show", "requires" or "hide" for an object of this gathering kind,
    --- and the skill it asks for.
    local function gather_verdict(kind, name)
        if not gather_filter or (kind ~= "herb" and kind ~= "ore") then return "show", nil end
        return cfg.gather_verdict(kind, name, skill_of)
    end

    -- --- the pass -----------------------------------------------------------

    local function lod_for(distance, full_range, mid_range, enabled)
        if not enabled then return "full" end
        if distance <= full_range then return "full" end
        if distance <= mid_range then return "mid" end
        return "far"
    end

    --- Most relevant first, nearest first within the same relevance.
    ---
    --- This is the order everything downstream spends against: the detail
    --- budget refreshes from the top, the draw budget runs out at the bottom,
    --- and the mark limit cuts the tail. Sorting by distance alone would spend
    --- all three on whichever boar happened to be closest.
    --- WITHIN A RELEVANCE, BY THREE-YARD BAND, THEN BY GUID. Two mobs at
    --- nearly the same distance used to swap places every time one stepped
    --- past the other, and their blocks traded slots on screen with them --
    --- the flicker in a crowd. The band holds the order until one is clearly
    --- nearer; the guid settles a tie the same way every frame.
    local BAND = 3
    local function by_relevance(a, b)
        if a.prio ~= b.prio then return a.prio > b.prio end
        if a.band ~= b.band then return a.band < b.band end
        return a.guid < b.guid
    end

    --- Walks units and objects once and rebuilds every list.
    ---
    --- `visuals` only decides whether entities are collected for DRAWING. The
    --- automation lists are filled either way, for the same reason the node
    --- toggle and the gather toggle are separate settings.
    ---@param visuals boolean
    ---@param master number Master range, in yards.
    function M.run(visuals, master)
        for i = count, 1, -1 do entities[i] = nil end
        count = 0
        clear(threats)
        clear(corpses)
        clear(nodes)

        reads_left = P.opt("esp_detail_reads", 8)
        frame_now = 0
        frame_now = clock()
        M.now = frame_now
        if classify.begin_pass then classify.begin_pass() end

        for prof in pairs(skill_now) do skill_now[prof] = nil end
        local me = ctx.player
        gather_filter = P.opt("gather_skill_only", true) == true and cfg.gather_verdict ~= nil
            and me ~= nil and type(me.skill) == "function"
        gather_hidden = 0

        local auto_ranges = P.opt("auto_ranges", true)
        local explain = P.opt("esp_explain", false)
        if explain then
            skipped.category_off, skipped.out_of_range, skipped.unclassified = 0, 0, 0
            nearest_skip.distance = math.huge
            nearest_skip.name = nil
            nearest_skip.reason = nil
        end

        local player = units.player()
        if not player then return end

        local player_guid = player:get_guid()
        M.player_guid = player_guid

        local collecting = P.master_on() and P.opt("alerts_on", true)

        -- Your selected target goes first, ahead of every category: it is
        -- the mark you are reading, so it is the one whose block the
        -- overlay's declutter must never move or cut (marks are laid out in
        -- this order, and the first to claim a spot keeps it).
        local target_guid = nil
        local combat = P.combat
        if combat and type(combat.target) == "function" then
            local ok, target = pcall(combat.target)
            if ok and target then target_guid = units.guid(target) end
        end
        -- Published: "is this my target" is then a compare per mark, where
        -- it was a call into combat (and the client) per mark.
        M.target_guid = target_guid
        local lod_on = P.opt("lod_on", true)
        local full_range = P.opt("lod_full_range", 45)
        local mid_range = math.max(full_range, P.opt("lod_mid_range", 90))

        -- --- units ---
        local list = units.units()
        for i = 1, #list do
            local unit = list[i]
            -- Both answered from the sweep's snapshot: the guid is already
            -- recorded there and is_dead is cached for the tick. Asking the
            -- native again was two round trips per unit per frame for
            -- answers the core had just read.
            local guid = units.guid(unit)

            if guid and guid ~= player_guid then
                local dead = units.is_dead(unit)
                local info = classify.unit(unit, guid, player, frame_now)
                local category, badge = info.category, nil
                local quest_entries, guide_goal = nil, nil
                local lootable, skinnable = false, false

                if dead then
                    -- A corpse is categorised by what you can do with it, not
                    -- by what it was alive.
                    lootable, skinnable = corpse_state(unit, guid, frame_now)
                    if skinnable and not skin_ok(info.level) then skinnable = false end

                    if lootable or skinnable then
                        category = "corpse"
                        badge = skinnable and not lootable and "[skin]" or "[loot]"
                        local distance = units.distance(unit)
                        if distance <= math.min(P.opt("corpse_range", 80), master) then
                            corpses[#corpses + 1] = {
                                obj = unit, guid = guid, distance = distance,
                                skinnable = skinnable and not lootable,
                            }
                        end
                    else
                        category = nil
                    end
                elseif not info.is_player and not info.pet then
                    -- Quest and guide membership outrank the creature-type
                    -- category: the point of highlighting a quest mob is that
                    -- it stands out from the identical mobs around it. Asked
                    -- per frame, never cached -- the unit does not change, but
                    -- whether the guide wants it does, every time a step
                    -- advances.
                    --
                    -- The index answers WHICH quests want this unit and what
                    -- the progress on each is, so it is asked first: the guide
                    -- override still wins the category, but the entries ride
                    -- along either way and the mark can name the quest.
                    --
                    -- NEVER A PLAYER, NOR A PET. No quest or guide step targets
                    -- another player or anybody's pet, but both lookups could
                    -- match one: the index matches by NAME CONTAINMENT against
                    -- objective and guide text (a pet named "Boar" sits inside
                    -- "Bristleback Quilboar"), and by whatever id the client
                    -- reports for a unit, which the contract does not define
                    -- for a player. Seen on 2026-09-30 as "quest Kawahmwhaz"
                    -- over a level 22 player in the Crossroads.
                    local quests_on = P.opt("questie_on", true)
                    if quests_on then
                        -- false, not nil, when the classifier found no id:
                        -- it asked already, and nil would ask again every
                        -- frame.
                        quest_entries = P.quests.quest_entries(unit, info.name, info.npc_id or false)
                    end

                    local is_guide = false
                    if P.opt("guide_on", true) then
                        is_guide, guide_goal = P.quests.is_guide_target(unit, info.name, info.npc_id)
                    end
                    if is_guide then
                        category, badge = "guide", "[guide]"
                    elseif quest_entries then
                        category, badge = "quest", "[quest]"
                    elseif quests_on and P.quests.is_questie_id(info.npc_id) then
                        category, badge = "quest", "[quest]"
                    end
                end

                if category then
                    local definition = cfg.CATEGORY_BY_KEY[category]
                    if not P.opt(category .. "_on", definition.on) then
                        if explain then
                            note_skip(info.name, units.distance(unit),
                                definition.label .. " marks are switched off")
                            skipped.category_off = skipped.category_off + 1
                        end
                    else
                        -- Automatic ranges mean one number to think about --
                        -- the master range -- instead of fourteen. The
                        -- per-category sliders are still there for anyone who
                        -- wants "rares at 150 but boars at 40"; they are just
                        -- no longer the thing standing between a new install
                        -- and seeing anything.
                        local configured = auto_ranges and master
                            or P.opt(category .. "_range", definition.range)
                        local range = math.min(configured, master)
                        local distance = units.distance(unit)

                        if distance > range and explain then
                            skipped.out_of_range = skipped.out_of_range + 1
                            note_skip(info.name, distance, configured > master
                                and string.format("past the master range (%.0fy)", master)
                                or string.format("past the %s range (%.0fy)",
                                    definition.label:lower(), range))
                        end

                        if distance <= range then
                            if visuals then
                                local e = acquire()
                                e.obj = unit
                                e.guid = guid
                                e.kind = "unit"
                                e.info = info
                                e.name = info.name
                                e.category = category
                                e.badge = badge
                                e.distance = distance
                                e.range = range
                                e.dead = dead
                                e.lod = "full"
                                e.prio = (definition.prio or 0) + (guid == target_guid and 1000 or 0)
                                e.band = math.floor(distance / BAND)
                                e.quest_entries = quest_entries
                                e.guide_goal = guide_goal
                                e.lootable = lootable
                                e.skinnable = skinnable
                                e.requires = nil
                            end
                            if collecting and not dead then
                                threats[#threats + 1] = {
                                    guid = guid, unit = unit,
                                    info = info, distance = distance,
                                }
                            end
                        end
                    end
                end
            end
        end

        -- --- world objects ---
        local objects = units.objects()
        for i = 1, #objects do
            local obj = objects[i]
            local guid = units.guid(obj)
            if guid then
                local kind, name, entry_id = classify.object(obj, guid)

                -- THE QUEST INDEX IS ASKED ABOUT EVERY OBJECT, not only the
                -- ones the name rules kept. A quest pickup -- a pile of
                -- bones, a wanted poster, a crate to search -- is none of
                -- herb, ore or container and reports no loot, so it used to
                -- be dropped here before the index ever saw it. Asked per
                -- frame because the quest log changes; cheap because the
                -- index memoises by id and the id was read once above.
                local quest_entries, guide_goal, is_guide = nil, nil, false
                local category = kind
                -- A herb or vein you have not the profession for (1.88.0):
                -- nothing at all, not even a quest's mark -- you cannot
                -- gather it. One you are short of is marked, with what it
                -- asks for (e.requires, the node's `requires`).
                local verdict, need = gather_verdict(kind, name)
                if verdict == "hide" then
                    category = nil
                    gather_hidden = gather_hidden + 1
                else
                    if P.opt("questie_on", true) then
                        quest_entries = P.quests.quest_entries(obj, name, entry_id or false, true)
                    end
                    if P.opt("guide_on", true) and name ~= "" then
                        is_guide, guide_goal = P.quests.is_guide_target(obj, name, entry_id)
                    end
                    if is_guide then
                        category = "guide"
                    elseif quest_entries then
                        -- Outranks the gathering category for the same reason it
                        -- outranks a creature's: the point is that it stands out.
                        category = "quest"
                    end
                end
                local requires = verdict == "requires" and need or nil

                if category then
                    local definition = cfg.CATEGORY_BY_KEY[category]
                    local configured = auto_ranges and master
                        or P.opt(category .. "_range", definition.range)
                    local range = math.min(configured, master)
                    local distance = units.distance(obj)

                    if distance <= range then
                        if visuals and P.opt(category .. "_on", definition.on) then
                            local e = acquire()
                            e.obj = obj
                            e.guid = guid
                            e.kind = "object"
                            e.info = nil
                            e.name = name
                            e.category = category
                            e.badge = nil
                            e.distance = distance
                            e.range = range
                            e.dead = false
                            e.lod = "full"
                            e.prio = definition.prio or 0
                            e.band = math.floor(distance / BAND)
                            e.quest_entries = quest_entries
                            e.guide_goal = guide_goal
                            e.lootable = false
                            e.skinnable = false
                            e.requires = requires
                        end
                        -- Collected regardless of the visual toggle: hiding
                        -- the overlay must not turn gathering off behind the
                        -- user's back, and gathering has its own switch. The
                        -- kind here is the GATHERING kind, not the mark's
                        -- category: a herb that is also a quest target is
                        -- still a herb to the gatherer.
                        if kind then
                            nodes[#nodes + 1] = {
                                obj = obj, guid = guid, kind = kind,
                                name = name, distance = distance,
                                requires = requires,
                            }
                        end
                    end
                end
            end
        end

        table.sort(entities, by_relevance)

        local cap = P.opt("esp_max_marks", 60)
        if cap > 0 and count > cap then
            for i = count, cap + 1, -1 do entities[i] = nil end
            count = cap
        end

        for i = 1, count do
            local e = entities[i]
            e.lod = lod_for(e.distance, full_range, mid_range, lod_on)
        end
    end

    -- --- accessors ----------------------------------------------------------

    ---@return table[] entities Nearest first.
    function M.entities() return entities end

    ---@return integer
    function M.count() return count end

    --- { obj, guid, kind, name, distance, requires? }: `requires` is the
    --- skill a herb or vein asks for when yours is short of it (1.88.0).
    ---@return table[]
    function M.nodes() return nodes end

    ---@return table[]
    function M.corpses() return corpses end

    --- Why nearby things are not being marked, or nil when the explanation is
    --- switched off. `nearest` is the closest skipped unit, which is almost
    --- always the one the question was about.
    ---@return table|nil
    function M.explain()
        if not P.opt("esp_explain", false) then return nil end
        return {
            category_off = skipped.category_off,
            out_of_range = skipped.out_of_range,
            total = skipped.category_off + skipped.out_of_range,
            nearest = nearest_skip.name and {
                name = nearest_skip.name,
                distance = nearest_skip.distance,
                reason = nearest_skip.reason,
            } or nil,
            sweep_range = units.get_max_range and units.get_max_range() or nil,
        }
    end

    function M.stats()
        local by_kind, by_lod = {}, { full = 0, mid = 0, far = 0 }
        for i = 1, count do
            local e = entities[i]
            by_kind[e.category] = (by_kind[e.category] or 0) + 1
            by_lod[e.lod] = (by_lod[e.lod] or 0) + 1
        end

        -- Nodes are counted separately from entities: a node whose mark is
        -- switched off is still collected for the gatherer, so the two counts
        -- genuinely differ and the debug page reports the gatherer's.
        local nodes_by_kind = {}
        for i = 1, #nodes do
            local kind = nodes[i].kind
            nodes_by_kind[kind] = (nodes_by_kind[kind] or 0) + 1
        end

        local detailed = 0
        for _ in pairs(detail_cache) do detailed = detailed + 1 end

        return {
            entities = count,
            threats = #threats,
            nodes = #nodes,
            corpses = #corpses,
            by_kind = by_kind,
            nodes_by_kind = nodes_by_kind,
            by_lod = by_lod,
            detailed = detailed,
            reads_left = reads_left,
            -- Herbs and veins left out this pass for want of the profession
            -- (1.88.0): the answer to "why is that herb not marked".
            gather_hidden = gather_hidden,
        }
    end

    return M
end

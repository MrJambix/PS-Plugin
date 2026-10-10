-- Jambix AIO / hardcore -- the things that keep a one-life character alive.
--
-- Everything here exists because of a specific way hardcore characters die,
-- and each one is a documented cause rather than a general nicety:
--
--   * Fighting on through a fight already lost, because the rotation had no
--     opinion about when to stop.
--   * Adds arriving mid-fight and the health bar going from fine to dead in
--     the four seconds it took to notice.
--   * A consumable sitting unused in the bag through the whole thing.
--   * Drowning, which kills silently and gives a full warning nobody reads.
--   * Durability at zero, so the armour that was supposed to hold is not.
--
-- DESIGN RULE
-- Nothing here moves the character. Fleeing is the player's decision and the
-- plugin has no business steering it -- what it can do is buy the seconds in
-- which that decision is possible: break the fear, slow the pursuer, drink the
-- potion, stop feeding the rotation, and make the situation impossible to miss.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat, draw = P.units, P.combat, P.draw
    local book = P.spellbook

    local M = {}

    --- Resolves `core.<table>.<field>` as a callable, or nil.
    ---
    --- `pcall(core.inventory.get_items_in_bag, ...)` evaluates BOTH field
    --- lookups before pcall ever runs, so on a build without core.inventory
    --- the error escapes the pcall that was supposed to contain it and takes
    --- the plugin down at load. Every optional core surface below goes through
    --- here. (The same mistake in quests.lua is what made this worth a helper.)
    ---@param namespace string
    ---@param field string
    ---@return function|nil
    local function api(namespace, field)
        local group = core[namespace]
        if type(group) ~= "table" then return nil end
        local fn = group[field]
        if type(fn) ~= "function" then return nil end
        return fn
    end

    -- Item name fragments, matched lowercase against the bags. Names rather
    -- than ids for the same reason spells are: an id table would need every
    -- rank of every potion for two game versions. Same localisation limit.
    local ITEM_PATTERNS = {
        healthstone = { "healthstone" },
        soulstone   = { "soulstone" },
        soulshard   = { "soul shard" },
        potion      = { "healing potion", "rejuvenation potion" },
        bandage     = { "bandage" },
        hearthstone = { "hearthstone" },
        -- Mana: the reaction engine's "Restore mana". A gem first (its own
        -- cooldown), a potion second (shared with the healing potion).
        mana_gem    = { "mana agate", "mana jade", "mana citrine", "mana ruby", "mana emerald" },
        mana_potion = { "mana potion" },
    }

    -- FOREVER'S BAGS (1.73.2). Bag 0 there is the player's whole item array,
    -- sold items (the Buyback list) included, so the walk below counted a
    -- shard sold to a vendor, and the helper's rows put Buyback slots past the
    -- backpack, where a destroy found the wrong row. JCore's bag_rows() is
    -- the corrected list (bag 0 up to the backpack, bags 1 to 4); it counts
    -- and destroys there. Era keeps its walk.
    local forever_bags = false
    do
        local w = ctx and ctx.world
        local ok, c = pcall(function() return w and w.client and w.client() end)
        forever_bags = ok and type(c) == "table" and c.forever == true
    end

    local function inside_rows()
        if not forever_bags then return nil end
        local inv = ctx and ctx.inventory
        if not (inv and inv.bag_rows) then return nil end
        local ok, rows = pcall(inv.bag_rows)
        if ok and type(rows) == "table" then return rows end
        return nil
    end

    -- kind -> { id, name } resolved from the bags, refreshed on a timer.
    local found = {}
    local last_scan = 0
    local last_used = {}
    local last_destroy = 0

    -- --- bag scan -----------------------------------------------------------

    -- The shipped helper classifies consumables by FLAG (is_health_potion),
    -- not by name, so potions resolve on a non-English client where the name
    -- matching below does not. It does not know about healthstones, hearthstones
    -- or bandages, so both paths are needed.
    local inventory_helper
    do
        local ok, mod = pcall(require, "common/utility/inventory_helper")
        if ok then inventory_helper = mod end
    end

    local function scan_helper(fresh)
        if not inventory_helper then return end
        local ok, list = pcall(inventory_helper.get_current_consumables_list, inventory_helper)
        if not ok or type(list) ~= "table" then return end

        for i = 1, #list do
            local row = list[i]
            if row and row.is_health_potion and row.item and not fresh.potion then
                local ok_id, item_id = pcall(row.item.get_item_id, row.item)
                local ok_name, name = pcall(row.item.get_name, row.item)
                if ok_id and item_id and item_id > 0 then
                    fresh.potion = { id = item_id, name = (ok_name and name) or "health potion" }
                end
            end
        end
    end

    -- Everything carried, by name (1.79.0): the Reactions window's "Use an
    -- item by name" (a trinket, a Free Action Potion...). Bag 0 holds the
    -- worn gear too, so an equipped trinket is here as well.
    local carried, carried_names = {}, {}

    local function scan_bags()
        local fresh = {}
        local all = {}

        local get_bag = api("inventory", "get_items_in_bag")
        if not get_bag then
            log.once("warn", "no_inventory",
                "core.inventory is unavailable; emergency items are disabled")
            return
        end

        -- Bag 0 is the WHOLE player container: equipped gear at the low
        -- indices, then the backpack. Including it is how backpack items are
        -- found at all, and the cost is that worn gear is walked too. Harmless
        -- here because no equipped item is named "Healthstone", but it is why
        -- this loop starts at 0 rather than 1.
        for bag = 0, 4 do
            local ok, items = pcall(get_bag, bag)
            if ok and type(items) == "table" then
                for i = 1, #items do
                    local row = items[i]
                    local object = row and row.object
                    if object then
                        local ok_name, name = pcall(object.get_name, object)
                        local ok_id, item_id = pcall(object.get_item_id, object)
                        if ok_name and ok_id and name and item_id and item_id > 0 then
                            local lowered = name:lower()
                            if not all[lowered] then all[lowered] = { id = item_id, name = name } end
                            for kind, patterns in pairs(ITEM_PATTERNS) do
                                if not fresh[kind] then
                                    for p = 1, #patterns do
                                        if lowered:find(patterns[p], 1, true) then
                                            fresh[kind] = { id = item_id, name = name }
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Runs last so a flagged potion overrides whatever the name match
        -- happened to find.
        scan_helper(fresh)

        found = fresh
        carried = all
        local names = {}
        for _, row in pairs(all) do names[#names + 1] = row.name end
        table.sort(names)
        carried_names = names
        last_scan = core.time()
    end

    ctx.every(5.0, scan_bags)
    ctx.on("jcore.game_event.PLAYER_EQUIPMENT_CHANGED", scan_bags)
    scan_bags()

    -- --- generic bag utilities ----------------------------------------------
    --
    -- These live here because the bag scan does, not because they are about
    -- staying alive. Counting and destroying are the two things the emergency
    -- item lookup above could not express.

    --- How many items in the bags match this kind.
    ---
    --- Counted fresh rather than off the cached `found` table, which holds one
    --- item per kind by design -- it answers "do I have a healthstone", and a
    --- count is a different question.
    ---@param kind string
    ---@return integer
    -- kind -> { at, value }. A bag walk is five container reads plus a name
    -- read and a lowercased copy of it for every item, and the soul-shard
    -- rules were asking three times per frame -- the idle hook plus two stone
    -- rules -- which measured at fifteen container reads a frame while doing
    -- nothing, and a fresh string per item per walk for the collector to
    -- clear up. Bags change when something is looted, used or destroyed, not
    -- sixty times a second.
    local count_cache = {}
    local COUNT_TTL = 1.0

    local function invalidate_counts() count_cache = {} end
    M.invalidate_counts = invalidate_counts

    -- Registered here, after the function exists: a closure created above
    -- this line would capture the name as an undefined global.
    ctx.on("jcore.game_event.BAG_UPDATE", function() invalidate_counts() end)

    function M.count(kind)
        local now = core.time()
        local cached = count_cache[kind]
        if cached and (now - cached.at) < COUNT_TTL then return cached.value end

        local value = M.count_now(kind)
        count_cache[kind] = { at = now, value = value }
        return value
    end

    --- The uncached walk. Use M.count; this exists for the one caller that has
    --- just changed the bags and needs the truth now.
    function M.count_now(kind)
        local patterns = ITEM_PATTERNS[kind]
        if not patterns then return 0 end

        local rows = inside_rows()
        if rows then
            local total = 0
            for i = 1, #rows do
                local object = rows[i].item
                if object then
                    local ok_name, name = pcall(object.get_name, object)
                    if ok_name and type(name) == "string" then
                        local lowered = name:lower()
                        for p = 1, #patterns do
                            if lowered:find(patterns[p], 1, true) then
                                total = total + (tonumber(rows[i].stack_count) or 1)
                                break
                            end
                        end
                    end
                end
            end
            return total
        end

        local get_bag = api("inventory", "get_items_in_bag")
        if not get_bag then return 0 end

        local total = 0
        for bag = 0, 4 do
            local ok, items = pcall(get_bag, bag)
            if ok and type(items) == "table" then
                for i = 1, #items do
                    local object = items[i] and items[i].object
                    if object then
                        local ok_name, name = pcall(object.get_name, object)
                        if ok_name and name then
                            local lowered = name:lower()
                            for p = 1, #patterns do
                                if lowered:find(patterns[p], 1, true) then
                                    total = total + 1
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
        return total
    end

    --- Destroys ONE item of this kind, and answers whether it did.
    ---
    --- THIS IS IRREVERSIBLE AND THERE IS NO CONFIRMATION STEP. Blizzard's
    --- "type DELETE" box belongs to the default bag UI; going straight to the
    --- engine skips it entirely. So the guards are the only thing standing
    --- between a bug here and somebody's bags:
    ---
    ---   * The (bag, slot) pair comes from inventory_helper, which owns the
    ---     shift between the raw scan indices and what the destroy call
    ---     expects. Passing a raw slot_id from get_items_in_bag destroys the
    ---     item NEXT to the one you meant -- the API stub says so in as many
    ---     words, and that is the whole reason this does not use the scan
    ---     above.
    ---   * The name at that row is re-read and re-matched IMMEDIATELY before
    ---     the call, so a stale row cannot name a slot that now holds
    ---     something else.
    ---   * One per call, with a lockout, so no single frame can empty a bag.
    ---
    ---@param kind string
    ---@param reason string
    ---@return boolean destroyed
    -- A destroy the client said yes to, waiting to be seen in the bags; and
    -- whether destroying has been seen to do nothing on this client (1.73.2).
    local destroy_check, destroy_dead = nil, false

    function M.destroy_one(kind, reason)
        local patterns = ITEM_PATTERNS[kind]
        if not patterns then return false end
        if not inventory_helper then return false end

        local now = core.time()
        -- PROVEN, NOT ASSUMED: the last destroy must have left the bags one
        -- shorter. If it did not, nothing more is destroyed this session --
        -- and the warlock's Drain Soul already keeps under the limit.
        if destroy_check and (now - destroy_check.at) > 1.5 then
            local after = M.count_now(destroy_check.kind)
            if after >= destroy_check.before then
                destroy_dead = true
                log.fmt("warn", "destroying %s did nothing on this client (still %d): no more destroying this session",
                    destroy_check.name, after)
            end
            destroy_check = nil
        end
        if destroy_dead then return false end
        if last_destroy and (now - last_destroy) < 2 then return false end

        local destroy = api("input", "destroy_container_item")
        if not destroy then
            log.once("warn", "no_destroy",
                "this build cannot destroy bag items; nothing will be dumped")
            return false
        end

        local rows = inside_rows()
        if not rows then
            local ok, all = pcall(inventory_helper.get_character_bag_slots, inventory_helper)
            if not ok or type(all) ~= "table" then return false end
            rows = all
        end
        local before = M.count_now(kind)

        for i = 1, #rows do
            local row = rows[i]
            local object = row and row.item
            if object and row.bag_id and row.bag_slot then
                local ok_name, name = pcall(object.get_name, object)
                if ok_name and type(name) == "string" then
                    local lowered = name:lower()
                    for p = 1, #patterns do
                        if lowered:find(patterns[p], 1, true) then
                            last_destroy = now
                            local ok_gone, gone = pcall(destroy, row.bag_id, row.bag_slot)
                            if ok_gone and gone then
                                invalidate_counts()
                                destroy_check = { kind = kind, name = name, before = before, at = now }
                                log.fmt("warn", "destroyed %s (%s)", name, reason)
                                ctx.emit("jambix.aio.item_destroyed",
                                    { kind = kind, name = name, reason = reason })
                                return true
                            end
                            return false
                        end
                    end
                end
            end
        end
        return false
    end

    ---@param kind string
    ---@return integer|nil id
    ---@return string|nil name
    function M.item(kind)
        local row = found[kind]
        if not row then return nil end
        return row.id, row.name
    end

    --- Uses a bag item, with a per-item lockout so a failed use does not turn
    --- into a request every tick.
    ---@param kind string
    ---@param reason string
    ---@return boolean
    local function use_item(kind, reason)
        local id, name = M.item(kind)
        if not id then return false end

        local now = core.time()
        if last_used[kind] and (now - last_used[kind]) < 5 then return false end

        local is_usable = api("spell_book", "is_item_usable")
        if is_usable then
            local ok_usable, usable = pcall(is_usable, id)
            if ok_usable and usable == false then return false end
        end

        local use = api("input", "use_item")
        if not use then return false end

        last_used[kind] = now
        local ok = pcall(use, id)
        if ok then
            log.fmt("warn", "hardcore: used %s (%s)", name or kind, reason)
            ctx.emit("jambix.aio.hc_item", { kind = kind, id = id, reason = reason })
        end
        return ok
    end

    M.use_item = use_item

    --- Every item carried or worn, by name, sorted (1.79.0).
    ---@return string[]
    function M.carried() return carried_names end

    --- A carried item by its name (any case): its id and its name as the
    --- game spells it.
    ---@param name string
    ---@return integer|nil id
    ---@return string|nil name
    function M.named(name)
        if type(name) ~= "string" or name == "" then return nil end
        local row = carried[name:lower()]
        if not row then return nil end
        return row.id, row.name
    end

    --- Can a carried item be used now? false, and why, when it cannot.
    ---@return boolean
    ---@return string|nil
    function M.named_ready(name)
        local id = M.named(name)
        if not id then return false, "not carried" end
        local is_usable = api("spell_book", "is_item_usable")
        if is_usable then
            local ok, usable = pcall(is_usable, id)
            if ok and usable == false then return false, "not usable now" end
        end
        local inv = ctx and ctx.inventory
        if inv and inv.cooldown then
            local ok, left = pcall(inv.cooldown, id)
            if ok and type(left) == "number" and left > 0 then
                return false, string.format("on its cooldown (%.0fs)", left)
            end
        end
        return true
    end

    --- Uses a carried item by name, with the same lockout as the bag kinds.
    ---@return boolean
    function M.use_named(name, reason)
        local id, real = M.named(name)
        if not id then return false end
        local key = "named:" .. real:lower()
        local now = core.time()
        if last_used[key] and (now - last_used[key]) < 2 then return false end
        local use = api("input", "use_item")
        if not use then return false end
        last_used[key] = now
        local ok = pcall(use, id)
        if ok then log.fmt("info", "used %s (%s)", real, tostring(reason or "a reaction")) end
        return ok
    end

    -- --- guardrails ---------------------------------------------------------

    --- Should the rotation stop feeding this fight?
    ---
    --- Below the bail-out threshold, more damage is not the answer -- the
    --- character needs the global cooldowns for a potion and the player needs
    --- to be looking at the screen. Returning true stops the priority walk
    --- entirely; emergency() still runs.
    ---@param s table situation from warrior.lua
    ---@return boolean
    -- SAID WHEN IT STARTS AND STOPS. A bail-out stops the priority walk
    -- before the watch line runs, so from the log it looked exactly like the
    -- rotation hanging: fourteen seconds of nothing mid-fight, and no way to
    -- tell which it was.
    local bailing = false

    -- TWO LINES, NOT ONE. A bail-out entered at 20% used to end at 21%: one
    -- tick of a potion or a heal landing and the rotation was attacking again,
    -- the next hit put it back under, and it flipped every few frames. Once
    -- bailing, it holds until health is this far back above the line, or the
    -- fight is over.
    local BAIL_EXIT_MARGIN = 0.15

    -- THE LINES ARE NOT SETTINGS (1.32.0). The reaction engine owns the
    -- bail-out, the bag and the escapes; "Enable hardcore utilities" is the
    -- one switch, and these are the lines it works to.
    M.BAIL_LINE = 0.20
    M.POTION_LINE = 0.35
    M.HEARTH_LINE = 0.15

    function M.should_stop_fighting(s)
        local line = M.BAIL_LINE
        local exit_line = math.min(0.95, line + BAIL_EXIT_MARGIN)
        local stop = P.opt("hc_enabled", true)
            and s.in_combat and (s.hp <= line or (bailing and s.hp < exit_line)) or false
        if stop ~= bailing then
            bailing = stop
            if stop then
                log.fmt("warn", "hardcore: %.0f%% health in combat, under the bail-out line; "
                    .. "no attacks, only potions and escapes", (s.hp or 0) * 100)
            else
                log.fmt("info", "hardcore: bail-out over (%s); attacking again",
                    s.in_combat and string.format("%.0f%% health", (s.hp or 0) * 100)
                        or "combat ended")
            end
        end
        return stop
    end

    --- May the rotation start a NEW fight right now?
    ---
    --- Pulling at 40% health is how a routine fight becomes the last one. The
    --- rotation asks this before its opener.
    ---@return boolean
    function M.may_pull()
        if not P.opt("hc_enabled", true) then return true end
        if not P.opt("hc_block_pulls", true) then return true end

        local player = units.player()
        if not player then return false end
        if combat.in_combat() then return true end

        return units.health_fraction(player) >= P.optpct("hc_pull_hp", 70)
    end

    -- --- emergency ----------------------------------------------------------

    local last_hearth = 0

    --- Everything worth doing when the health bar says the fight is lost.
    ---
    --- Ordered by how many seconds each one buys. A consumable is instant and
    --- keeps you standing; a fear or a slow breaks contact; the hearthstone is
    --- a ten second channel and is therefore last, and only when something has
    --- already bought those ten seconds.
    ---@param s table
    function M.emergency(s)
        if not P.opt("hc_enabled", true) then return end

        local hp = s.hp

        if hp <= M.POTION_LINE then
            if use_item("healthstone", "critical health") then return end
            if use_item("potion", "critical health") then return end
        end

        if s.in_combat then
            -- The ESCAPE LIST COMES FROM THE CLASS. It used to be the two
            -- warrior shouts, hard-coded, so a mage in trouble was offered
            -- Intimidating Shout and got nothing -- the list resolved to
            -- nothing and the whole feature was silently warrior-only.
            --
            -- Order within a class list matters: a fear or a blink breaks
            -- contact with everything at once, a slow only helps against one
            -- pursuer, so each class lists its best first.
            local class_module = P.rotation and P.rotation.active_class()
            local escapes = (class_module and class_module.escapes) or {}

            -- The same key gate the rotation applies. An ability held back
            -- in the priority list and then fired automatically here would
            -- not be held back at all.
            local helpers = P.rotation and P.rotation.helpers
            for _, name in ipairs(escapes) do
                local allowed = not helpers or not helpers.key_allows
                    or helpers.key_allows(name)
                -- Wing Clip, Fear, Blind and the rest are cast on the enemy;
                -- the rotation's helper says which, and whether it is in
                -- reach. Nil skips to the next escape.
                local target = units.player()
                if helpers and helpers.escape_target then
                    target = helpers.escape_target(name, s)
                end
                if book.ready(name) and allowed and target then
                    ctx.cast({
                        spell_id = book.id(name),
                        target = target,
                        priority = ctx.PRIORITY.EMERGENCY,
                        reason = "hardcore escape",
                    })
                    log.fmt("warn", "hardcore: %s to break contact at %.0f%%", name, hp * 100)
                    return
                end
            end
        end

        if P.opt("hc_hearth", false) and hp <= M.HEARTH_LINE then
            local now = core.time()
            if (now - last_hearth) > 30 then
                last_hearth = now
                use_item("hearthstone", "last resort")
            end
        end
    end

    -- --- awareness ----------------------------------------------------------

    local engaged_peak = 0
    local peak_at = 0
    local warned_breath = false

    --- Watches for the things that change a fight's outcome without changing
    --- the health bar yet.
    local function watch()
        if not P.opt("hc_enabled", true) then return end

        local player = units.player()
        if not player then return end

        local now = core.time()

        -- Adds. A second mob arriving is the single most common way a routine
        -- fight turns fatal, and it is visible a few seconds before the health
        -- bar shows it.
        if P.opt("hc_warn_adds", true) and combat.in_combat() then
            local engaged = P.targeting.aoe_count(P.tune_secs("rot_target_range", 30))
            if engaged > engaged_peak then
                if engaged_peak > 0 and engaged >= P.opt("hc_add_threshold", 2) then
                    log.fmt("warn", "hardcore: %d enemies engaged (was %d)", engaged, engaged_peak)
                    ctx.emit("jambix.aio.hc_adds", engaged)
                    if P.opt("hc_sound", true) then pcall(core.play_sound_by_id, 8959) end
                end
                engaged_peak, peak_at = engaged, now
            elseif engaged == 0 or (now - peak_at) > 10 then
                engaged_peak = engaged
            end
        elseif not combat.in_combat() then
            engaged_peak = 0
        end

        -- Drowning. get_breath answers a 0..1 fraction of the breath bar and
        -- kills silently; a chat warning nobody reads is the whole problem.
        if P.opt("hc_warn_breath", true) then
            -- get_breath answers a TABLE, not a fraction:
            -- { active, value, max, scale, paused } with value and max in
            -- MILLISECONDS. Gate on `active` -- a player can swim on the
            -- surface indefinitely with no breath timer running at all, and
            -- treating "not drowning" as 0% would warn constantly.
            local get_breath = api("character", "get_breath")
            local ok, info = false, nil
            if get_breath then ok, info = pcall(get_breath) end

            if ok and type(info) == "table" and info.active
                and type(info.max) == "number" and info.max > 0 then
                local fraction = info.value / info.max
                if fraction <= P.optpct("hc_breath_warn", 40) then
                    if not warned_breath then
                        warned_breath = true
                        log.fmt("warn", "hardcore: breath at %.0f%% (%.0fs left)",
                            fraction * 100, info.value / 1000)
                        if P.opt("hc_sound", true) then pcall(core.play_sound_by_id, 8959) end
                        ctx.emit("jambix.aio.hc_breath", fraction)
                    end
                else
                    warned_breath = false
                end
            else
                warned_breath = false
            end
        end

        -- Durability. Armour at zero is armour that is not there, and it
        -- degrades slowly enough that nobody notices until a fight goes wrong.
        local get_durability = api("inventory", "get_item_durability")
        if P.opt("hc_warn_durability", true) and get_durability then
            local worst = 1.0
            -- Equipment slots are INVSLOT_* ids, 1 to 19. The call answers a
            -- TABLE { current, max }, not two values, and both are 0 for an
            -- empty slot or an item with no durability -- so a tabard divides
            -- by zero unless max is tested first.
            for slot = 1, 19 do
                local ok, info = pcall(get_durability, slot)
                if ok and type(info) == "table"
                    and type(info.max) == "number" and info.max > 0 then
                    local fraction = info.current / info.max
                    if fraction < worst then worst = fraction end
                end
            end
            if worst <= P.optpct("hc_durability_warn", 25) then
                log.once("warn", "durability",
                    string.format("hardcore: durability down to %.0f%%", worst * 100))
            end
        end
    end

    ctx.tick(watch, { interval = 0.5, deferrable = true })

    -- --- the banner ---------------------------------------------------------

    --- A full-width warning across the middle of the screen.
    ---
    --- Deliberately loud. Everything else this plugin draws is designed to sit
    --- quietly at the edge of attention; this one has to interrupt, because
    --- the failure mode it guards against is a player who is not looking at
    --- their health bar.
    local function render_banner()
        if not P.opt("hc_enabled", true) then return end
        if not P.opt("hc_banner", true) then return end
        if not P.master_on() then return end

        local player = units.player()
        if not player or player:is_dead() then return end

        local hp = units.health_fraction(player)
        local threshold = P.optpct("hc_banner_hp", 35)
        if hp > threshold then return end

        local screen_w, screen_h = draw.screen_size()
        if screen_w == 0 then return end

        -- Pulses so it cannot be mistaken for a static overlay element.
        local pulse = 0.55 + 0.45 * math.abs(math.sin(core.time() * 4))
        local alpha = math.floor(pulse * 230)
        local colour = P.color(235, 60, 60, alpha)

        local height = 54
        local y = screen_h * 0.30

        -- On JCore 1.15's plate (1.89.0): a soft shadow lifts it off the game.
        local band = P.color(40, 0, 0, math.floor(pulse * 150))
        if draw.plate_2d then
            draw.plate_2d({ x = 0, y = y }, screen_w, height, band, { layer = ctx.LAYER.TOOLTIP, rounding = 0 })
        else
            draw.rect_2d({ x = 0, y = y }, screen_w, height, band, { layer = ctx.LAYER.TOOLTIP, filled = true })
        end

        draw.text_2d({ x = screen_w * 0.5, y = y + 8 },
            string.format("HEALTH %.0f%%", hp * 100), colour,
            { layer = ctx.LAYER.TOOLTIP, size = 30, centered = true })

        local engaged = P.targeting.aoe_count(P.tune_secs("rot_target_range", 30))
        local note = engaged > 1
            and string.format("%d enemies engaged", engaged)
            or "disengage"
        draw.text_2d({ x = screen_w * 0.5, y = y + 34 },
            note, P.color(255, 220, 220, alpha),
            { layer = ctx.LAYER.TOOLTIP, size = 16, centered = true })
    end

    ctx.render(render_banner, { priority = 250 })

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local have = {}
        for kind in pairs(ITEM_PATTERNS) do
            local _, name = M.item(kind)
            have[#have + 1] = kind .. "=" .. (name and "yes" or "no")
        end
        table.sort(have)
        return {
            items = table.concat(have, " "),
            scanned = core.time() - last_scan,
            engaged_peak = engaged_peak,
            may_pull = M.may_pull(),
        }
    end

    return M
end

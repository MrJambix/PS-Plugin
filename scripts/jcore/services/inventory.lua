-- JCore / inventory -- bags, equipment, durability and gold.
--
-- Depends on: util, log, cache, units, player.
--
-- Walking the bags is the single most expensive read in this API. Six bags of
-- up to thirty-six slots each is over two hundred native calls, and a plugin
-- that asks "do I have a healthstone" per frame is paying all of it per frame.
--
-- So the bags are walked at most once per BAG_UPDATE, not per tick, and the
-- result is indexed by item id on the way through. Asking whether an item is
-- carried is then a single table lookup, and asking where it is costs the
-- same. The index rebuilds when the game says the bags changed, which is
-- exactly as often as it needs to and no more.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local units = rt.units
    local log = rt.log.for_tag("JCore/inventory")

    local try = cache.try
    local try_bool = cache.try_bool

    local M = {}

    -- Bag ids to scan. 0 is the backpack, 1..4 the equipped bags, 5 the
    -- reagent bag where the build has one. A bag that does not exist answers
    -- an empty list, so scanning one too many is free.
    local BAG_IDS = { 0, 1, 2, 3, 4, 5 }

    -- These are the events the client raises when the bags actually change.
    -- Binding the cache to them is what turns a per-frame scan into a per-loot
    -- scan.
    local BAG_EVENTS = {
        "BAG_UPDATE", "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED",
        "PLAYER_EQUIPMENT_CHANGED", "UNIT_INVENTORY_CHANGED",
        "BAG_CLOSED", "BAG_NEW_ITEMS_UPDATED",
    }

    local bags = cache.new("inventory.bags", { scope = "manual", events = BAG_EVENTS })
    local tick = cache.new("inventory.tick", { scope = "tick" })

    M.BAG_EVENTS = BAG_EVENTS

    -- --- Forever: no bag events, and bag 0 is every item (1.8.2) -------------
    --
    -- The user, 2026-10-04: fishing's "stop when bags are full" does not work
    -- on Forever, and the recording there has 80 "Inventory is full"
    -- refusals. Both reasons are Forever's:
    --
    -- NO BAG EVENTS. Of the 82 event types the recorder has seen there, the
    -- only one of BAG_EVENTS is PLAYER_EQUIPMENT_CHANGED, so a walk was kept
    -- until the next gear change. On Forever every bag answer also expires
    -- BAG_TTL seconds after it was read, and the next question reads again.
    --
    -- BAG 0 IS THE PLAYER'S WHOLE ITEM ARRAY (the .api): worn gear, and on
    -- Forever sold items too (forever_npc.lua saw them stay), come back with
    -- the backpack, and "used" counted all of it against the bags' slots. On
    -- Forever free_slots() counts the loader's inventory_helper rows, which
    -- know each build's backpack offset, and falls back to the count when it
    -- cannot answer. Each new answer is a trace line.
    --
    -- NOT PAST A BAG'S SIZE (1.8.4). The helper does not stop where the
    -- backpack does: the merchant's Buyback list comes back as bag 0 slots
    -- past it (forever_npc.lua 1.66.2: a sold Broken Boar Tusk offered as
    -- "bag 0 slot 39" on a 20-slot backpack). 1.8.2 took the helper's own
    -- free total, which counts those too, so every sale took a free slot
    -- away until the next reload. A row now counts only inside its bag.
    --
    -- Every other client keeps the event-only cache and the count, with no
    -- new reads.
    local BAG_TTL = 1.0
    local bags_read_at = nil
    local is_forever = nil

    local function forever()
        if is_forever ~= nil then return is_forever end
        local world = rt.world
        if type(world) ~= "table" or type(world.client) ~= "function" then return false end
        local ok, client = pcall(world.client)
        if not ok or type(client) ~= "table" then return false end
        is_forever = client.forever == true
        return is_forever
    end

    local function get(key)
        if bags_read_at and forever() and core.time() - bags_read_at > BAG_TTL then
            bags:clear()
            bags_read_at = nil
        end
        return bags:get(key)
    end

    local function put(key, value)
        if not bags_read_at and forever() then bags_read_at = core.time() end
        return bags:put(key, value)
    end

    local helper = nil              -- nil: not looked for yet; false: none
    local helper_said = nil         -- the last answer traced

    --- The loader's inventory_helper rows that sit inside the bags (1.8.4):
    --- bag 0 up to the backpack's size, bags 1 to 4 up to theirs, one row per
    --- slot. The Buyback list the helper puts past the backpack is left out.
    --- Rows as the helper gives them ({ item, bag_id, bag_slot, stack_count,
    --- ... }); (bag_id, bag_slot) is the pair use_container_item takes. Nil
    --- when the helper cannot answer.
    ---@return table[]|nil rows
    ---@return integer outside rows left out, past their bag
    ---@return integer capacity slots in the backpack and bags
    function M.bag_rows()
        local value, hit = get("bag_rows")
        if hit then
            if not value then return nil, 0, 0 end
            return value.rows, value.outside, value.cap
        end
        if helper == nil then
            local ok, mod = pcall(require, "common/utility/inventory_helper")
            helper = (ok and type(mod) == "table") and mod or false
        end
        local ok, rows = false, nil
        if helper then ok, rows = pcall(helper.get_character_bag_slots, helper) end
        if not ok or type(rows) ~= "table" then
            put("bag_rows", nil)
            return nil, 0, 0
        end
        -- Container 0 is the backpack, 1 to 4 the bags; bag_slots() is
        -- shifted one up (the .api).
        local size, cap = {}, 0
        for bag = 0, 4 do
            size[bag] = M.bag_slots(bag + 1)
            cap = cap + size[bag]
        end
        local inside, outside, taken = {}, 0, {}
        for i = 1, #rows do
            local row = rows[i]
            local bag = row and tonumber(row.bag_id)
            local slot = row and tonumber(row.bag_slot)
            if bag and slot and size[bag] and slot >= 1 and slot <= size[bag] then
                local key = bag * 1000 + slot
                if not taken[key] then
                    taken[key] = true
                    inside[#inside + 1] = row
                end
            elseif row then
                outside = outside + 1
            end
        end
        put("bag_rows", { rows = inside, outside = outside, cap = cap })
        return inside, outside, cap
    end

    --- Forever's free bag slots: the bags' sizes less the rows inside them,
    --- or nil when the helper cannot say.
    local function helper_free()
        local rows, outside, cap = M.bag_rows()
        if not rows or cap < 1 then return nil end
        local free = cap - #rows
        if free < 0 then return nil end
        local said = string.format("%d of %d", free, cap)
        if said ~= helper_said then
            helper_said = said
            if rt.events then
                pcall(rt.events.emit, "jcore.recorder.trace", string.format(
                    "inventory: %s bag slots free (inventory_helper; %d row(s) past the bags left out)",
                    said, outside))
            end
        end
        return free
    end

    -- --- the index ----------------------------------------------------------

    --- Walks every bag once and builds both views of the result: the flat list
    --- of rows, and an item_id -> { count, entries } index.
    local function build_index()
        local value, hit = get("index")
        if hit then return value end

        local t0 = core.cpu_time()
        local rows = {}
        local by_id = {}
        local n = 0

        for b = 1, #BAG_IDS do
            local bag_id = BAG_IDS[b]
            local items = try(core.inventory.get_items_in_bag, bag_id)
            if items then
                for i = 1, #items do
                    local item = items[i]
                    if item then
                        n = n + 1
                        rows[n] = item

                        -- Builds differ on where the id lives on the row, so
                        -- take whichever of these is present rather than
                        -- silently indexing nothing.
                        local id = item.item_id or item.id
                        if not id and item.get_item_id then
                            id = try(item.get_item_id, item)
                        end

                        if id then
                            local entry = by_id[id]
                            if not entry then
                                entry = { id = id, count = 0, entries = {} }
                                by_id[id] = entry
                            end
                            local stack = item.stack_count or item.count or 1
                            entry.count = entry.count + stack
                            entry.entries[#entry.entries + 1] = {
                                bag = bag_id, slot = item.slot or i, item = item,
                            }
                        end
                    end
                end
            end
        end

        local result = {
            rows  = rows,
            by_id = by_id,
            built = core.time(),
            ms    = (core.cpu_time() - t0) * 1e-6,
        }
        log.fmt("trace", "bag index rebuilt: %d items in %.2fms", n, result.ms)
        return put("index", result)
    end

    --- Forces the next read to rescan. The event bindings handle this on their
    --- own; call it only after an action the client does not announce.
    function M.invalidate()
        bags:clear()
    end

    --- Every item in the bags, flat.
    ---@return table[]
    function M.items()
        return build_index().rows
    end

    --- How many of an item are carried, counting partial stacks.
    ---@param item_id integer
    ---@return integer
    function M.count(item_id)
        local entry = build_index().by_id[item_id]
        return entry and entry.count or 0
    end

    ---@param item_id integer
    ---@return boolean
    function M.has(item_id)
        return build_index().by_id[item_id] ~= nil
    end

    --- Where an item sits, as bag and slot. Nil when it is not carried.
    ---@param item_id integer
    ---@return integer|nil bag
    ---@return integer|nil slot
    function M.locate(item_id)
        local entry = build_index().by_id[item_id]
        if not entry or #entry.entries == 0 then return nil, nil end
        local first = entry.entries[1]
        return first.bag, first.slot
    end

    --- The row for an item as the client reported it.
    ---@param item_id integer
    ---@return table|nil
    function M.find(item_id)
        local entry = build_index().by_id[item_id]
        if not entry or #entry.entries == 0 then return nil end
        return entry.entries[1].item
    end

    --- The first id from `item_ids` that is both carried and usable right now.
    --- The shape a "pop a healthstone, or a potion, or whatever I have" check
    --- wants, in one pass.
    ---@param item_ids integer[]
    ---@return integer|nil
    function M.first_usable(item_ids)
        local index = build_index().by_id
        for i = 1, #item_ids do
            local id = item_ids[i]
            if index[id] and M.is_usable(id) then return id end
        end
        return nil
    end

    -- --- free space ---------------------------------------------------------

    -- Forever only. The core reads the backpack's size off the player object
    -- at one classic offset that was never measured on that client (the .api
    -- says so), so an answer no backpack can have is replaced by the classic
    -- backpack's 16. Bags 2 to 5 come from the bag items and are left alone,
    -- and every other client keeps the raw read.
    local BACKPACK_ID = 1            -- get_num_bag_slots is shifted: 1 is the backpack
    local BACKPACK_SLOTS = 16
    local BACKPACK_MAX = 36

    ---@param bag_id integer
    ---@return integer
    function M.bag_slots(bag_id)
        local key = "slots." .. tostring(bag_id)
        local value, hit = get(key)
        if hit then return value or 0 end
        local slots = tonumber(try(core.inventory.get_num_bag_slots, bag_id)) or 0
        if bag_id == BACKPACK_ID and (slots < 1 or slots > BACKPACK_MAX) and forever() then
            log.once("warn", "forever_backpack",
                ("backpack size read %s on Forever; using %d"):format(tostring(slots), BACKPACK_SLOTS))
            slots = BACKPACK_SLOTS
        end
        return put(key, slots)
    end

    ---@return integer total
    ---@return integer used
    function M.space()
        local value, hit = get("space")
        if hit and value then return value.total, value.used end

        local total = 0
        for b = 1, #BAG_IDS do
            total = total + M.bag_slots(BAG_IDS[b])
        end

        local result = put("space", { total = total, used = #M.items() })
        return result.total, result.used
    end

    ---@return integer
    function M.free_slots()
        if forever() then
            local value, hit = get("free")
            if hit and value then return value end
            local free = helper_free()
            if free then return put("free", free) end
        end
        local total, used = M.space()
        local free = total - used
        return free > 0 and free or 0
    end

    ---@return boolean
    function M.is_full()
        return M.free_slots() <= 0
    end

    -- --- usability ----------------------------------------------------------
    --
    -- Tick-scoped rather than bag-scoped: whether an item is usable turns on
    -- its cooldown and on the player's state, both of which move between
    -- frames without any bag event firing.

    ---@param item_id integer
    ---@return boolean
    function M.is_usable(item_id)
        local key = "usable." .. tostring(item_id)
        local value, hit = tick:get(key)
        if hit then return value or false end
        return tick:put(key, try_bool(core.spell_book.is_item_usable, item_id))
    end

    ---@param item_id integer
    ---@param target game_object
    ---@return boolean
    function M.in_range(item_id, target)
        if not target then return false end
        if not try_bool(core.spell_book.has_item_range, item_id) then return true end
        return try_bool(core.spell_book.is_item_in_range, item_id, target)
    end

    --- Seconds of cooldown left on a carried item.
    ---@param item_id integer
    ---@return number
    function M.cooldown(item_id)
        local key = "cd." .. tostring(item_id)
        local value, hit = tick:get(key)
        if hit then return value or 0 end

        local p = units.player()
        if not p then return tick:put(key, 0) end
        local remaining = try(p.get_item_cooldown, p, item_id)
        return tick:put(key, remaining or 0)
    end

    ---@param item_id integer
    ---@return boolean
    function M.ready(item_id)
        return M.has(item_id) and M.is_usable(item_id) and M.cooldown(item_id) <= 0
    end

    -- --- equipment ----------------------------------------------------------

    ---@return table[]
    function M.equipped()
        local value, hit = bags:get("equipped")
        if hit then return value or {} end
        local p = units.player()
        if not p then return {} end
        return bags:put("equipped", try(p.get_equipped_items, p) or {})
    end

    ---@param slot integer
    ---@return table|nil
    function M.equipped_at(slot)
        local key = "equip." .. tostring(slot)
        local value, hit = bags:get(key)
        if hit then return value end
        local p = units.player()
        if not p then return nil end
        return bags:put(key, try(p.get_item_at_inventory_slot, p, slot))
    end

    ---@param slot integer
    ---@return inventory_item_durability|nil
    function M.durability(slot)
        local key = "dura." .. tostring(slot)
        local value, hit = bags:get(key)
        if hit then return value end
        return bags:put(key, try(core.inventory.get_item_durability, slot))
    end

    --- Worst durability across equipped slots, as 0..1. The one figure a
    --- "should I go repair" check needs, since the set is only as good as its
    --- weakest piece.
    ---@return number
    function M.worst_durability()
        local value, hit = bags:get("worst_dura")
        if hit then return value or 1 end

        local worst = 1.0
        for slot = 1, 19 do
            local row = M.durability(slot)
            if row and row.maximum and row.maximum > 0 then
                local fraction = (row.current or 0) / row.maximum
                if fraction < worst then worst = fraction end
            end
        end
        return bags:put("worst_dura", worst)
    end

    ---@return number
    function M.repair_cost()
        return try(core.inventory.get_total_repair_cost) or 0
    end

    ---@return boolean
    function M.can_repair_here()
        return try_bool(core.inventory.can_merchant_repair)
    end

    -- --- money --------------------------------------------------------------

    ---@return number copper
    function M.gold()
        local value, hit = tick:get("gold")
        if hit then return value or 0 end
        return tick:put("gold", try(core.inventory.get_gold) or 0)
    end

    --- Copper split into gold, silver and copper, for display.
    ---@param copper? number Defaults to what the player is carrying.
    ---@return integer g
    ---@return integer s
    ---@return integer c
    function M.split_money(copper)
        copper = math.floor(copper or M.gold())
        local g = math.floor(copper / 10000)
        local s = math.floor((copper % 10000) / 100)
        return g, s, copper % 100
    end

    -- --- actions ------------------------------------------------------------
    --
    -- These have side effects and are deliberately NOT cached. An item use
    -- that costs a global cooldown should go through ctx.cast with an item_id
    -- instead, so it is arbitrated against everything else competing for that
    -- cooldown; these are the direct path for the rest.

    ---@param bag integer
    ---@param slot integer
    function M.use_slot(bag, slot)
        M.invalidate()
        return try(core.input.use_container_item, bag, slot)
    end

    ---@param bag integer
    ---@param slot integer
    function M.pickup(bag, slot)
        return try(core.input.pickup_container_item, bag, slot)
    end

    ---@param bag integer
    ---@param slot integer
    function M.destroy(bag, slot)
        M.invalidate()
        return try(core.input.destroy_container_item, bag, slot)
    end

    ---@param use_guild_bank? boolean
    function M.repair_all(use_guild_bank)
        M.invalidate()
        return try(core.input.repair_all_items, use_guild_bank and true or false)
    end

    ---@param inventory_slot integer
    function M.equip_pending(inventory_slot)
        M.invalidate()
        return try(core.input.equip_pending_item, inventory_slot)
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local index = build_index()
        local total, used = M.space()
        return {
            items      = #index.rows,
            distinct   = util.count(index.by_id),
            slots      = total,
            used       = used,
            free       = M.free_slots(),
            gold       = M.gold(),
            durability = M.worst_durability(),
            scan_ms    = index.ms,
            scan_age   = core.time() - index.built,
        }
    end

    return M
end

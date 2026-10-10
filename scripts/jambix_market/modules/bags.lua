-- Jambix Market / bags -- what you carry, what it is worth, what to do with it.
--
-- Bag rows come from JCore's inventory.bag_rows(): the loader's
-- inventory_helper rows that sit inside the backpack and the four bags (on
-- Forever bag 0 is the player's whole item array, and the helper reads the
-- merchant's Buyback list past the backpack; bag_rows leaves both out).
-- Each row's (bag_id, bag_slot) is the pair core.auction_house.post_* take.
--
-- For every item the advice is one of:
--   post    the price pricing.post_price picks against the cheapest other
--           seller (a search under ten minutes old, else the last scan)
--   hand    a single item (gear, a bag, a recipe) worth more at the auction
--           house: Forever takes those only through its window, so YOU post
--           it -- the Gear tab prices it by roll (gear.lua). Auto never
--           posts or vendors gear it bought to resell
--   vendor  a vendor pays more than the auction house would, after its cut
--   keep    bound, a quest item, no price data, or the market is below
--           your floor -- with the reason

return function(M)
    local ctx, U, P, D, A, L = M.ctx, M.util, M.pricing, M.db, M.ah, M.ledger

    local B = {}

    local FRESH_SEARCH = 600
    local CLASS_QUEST = 12
    local BIND_ON_PICKUP = 1

    local cache, cache_at = nil, -math.huge
    local unpostable = {}         -- item id -> why, for this session

    function B.mark_unpostable(item_id, why) unpostable[item_id] = why end

    --- Every item stack in the bags: id -> { id, count, slots = { {bag, slot, stack, guid} } }.
    function B.read()
        local rows = U.try(ctx.inventory.bag_rows)
        local items, order = {}, {}
        if type(rows) ~= "table" then return items, order end
        for i = 1, #rows do
            local row = rows[i]
            local obj = row and row.item
            local id = tonumber(U.method(obj, "get_item_id"))
            if id and id > 0 then
                local stack = tonumber(row.stack_count) or tonumber(U.method(obj, "get_item_stack_count")) or 1
                local e = items[id]
                if not e then
                    e = { id = id, count = 0, slots = {} }
                    items[id] = e
                    order[#order + 1] = id
                end
                e.count = e.count + stack
                e.slots[#e.slots + 1] = { bag = row.bag_id, slot = row.bag_slot, stack = stack,
                    guid = U.method(obj, "get_guid") }
            end
        end
        return items, order
    end

    --- Where every item IN THE BAGS sits, read fresh: guid -> { at =
    --- "bag:slot", id, stack }. Posting and vendor selling check themselves
    --- with it (see trader.lua): the item meant must leave its place (or
    --- shrink, for part of a stack) and no other may move.
    ---
    --- Only the bags: on Forever the client's bag 0 is the player's whole
    --- item array, worn gear and the merchant's Buyback list included, and a
    --- sale that pushes the oldest Buyback entry out would read as the wrong
    --- item leaving (the review, 1.0.0). JCore's bag_rows leaves those out.
    function B.places()
        ctx.inventory.invalidate()
        local rows = U.try(ctx.inventory.bag_rows)
        if type(rows) ~= "table" then return nil end
        local out = {}
        for i = 1, #rows do
            local row = rows[i]
            local obj = row and row.item
            local guid = obj and U.method(obj, "get_guid")
            if type(guid) == "string" and guid ~= "" then
                out[guid] = { at = tostring(row.bag_id) .. ":" .. tostring(row.bag_slot),
                    id = tonumber(U.method(obj, "get_item_id")),
                    stack = tonumber(row.stack_count) or tonumber(U.method(obj, "get_item_stack_count")) }
            end
        end
        return out
    end

    --- Did an action on `guid` take it (gone, moved, or `shrunk` smaller), and
    --- did anything else of another item move? Returns took, intruder_id.
    --- `ignore(id)` may excuse an item that someone else moves on purpose.
    function B.check_moves(before, after, guid, item_id, ignore)
        for g, was in pairs(before) do
            if g ~= guid and was.id ~= item_id and not (ignore and was.id and ignore(was.id)) then
                local now_at = after[g] and after[g].at
                if now_at ~= was.at then return false, was.id or 0 end
            end
        end
        local was, now = before[guid], after[guid]
        if not now or not was then return true, nil end
        if now.at ~= was.at then return true, nil end
        if was.stack and now.stack and now.stack < was.stack then return true, nil end
        return false, nil
    end

    --- The cheapest other seller's unit price, and where that came from.
    function B.lowest(item_id)
        local r, age = A.last(item_id)
        if r and age <= FRESH_SEARCH then
            for i = 1, #r.rows do
                local row = r.rows[i]
                if not row.own and row.unit > 0 then return row.unit, "search", age end
            end
            return nil, "search", age     -- nobody else is selling
        end
        local rec = D.item(item_id)
        if rec and rec.n then return rec.n, "scan", rec.t and (U.now() - rec.t) or nil end
        return nil, rec and "scan" or "none"
    end

    --- Advice for one item. `count` is how many you carry.
    function B.advise(item_id, count)
        local info = D.info(item_id)
        local vendor = info and info.v or 0
        local out = { id = item_id, count = count, vendor = vendor }
        if not info then
            out.action, out.why = "keep", "item data not loaded yet"
            return out
        end
        out.name, out.quality = info.n, info.q
        if info.b == BIND_ON_PICKUP then
            out.action, out.why = (vendor > 0) and "vendor" or "keep", "soulbound"
        elseif info.c == CLASS_QUEST then
            out.action, out.why = "keep", "quest item"
        elseif unpostable[item_id] then
            out.action, out.why = (vendor > 0) and "vendor" or "keep", unpostable[item_id]
        elseif info.q == 0 then
            out.action, out.why = (vendor > 0) and "vendor" or "keep", "poor quality"
        end
        if out.action then
            out.value = (out.action == "vendor" and vendor or 0) * count
            return out
        end

        -- A single item: never posted by Auto (see the top). What it bought
        -- to resell is yours to post; what it bought for a vendor, the vendor's.
        local single = info.s ~= nil and info.s <= 1
        local mine = L.holding(item_id)
        if single and mine and (mine.qty or 0) > 0 then
            if mine.mode == "gear" then
                out.action, out.why = "hand", "bought to resell: post it yourself (Gear tab)"
                out.value = (M.gear and M.gear.bag_value(item_id)) or 0
                return out
            elseif mine.mode == "vendor" and vendor > 0 then
                out.action, out.why, out.value = "vendor", "bought for a vendor", vendor * count
                return out
            end
        end

        local rec = D.item(item_id)
        local market = D.reference(rec)
        local lowest, source = B.lowest(item_id)
        out.market, out.lowest, out.source = market, lowest, source
        out.per_day = D.per_day(rec)
        local cost = L.cost_basis(item_id)
        out.cost = cost
        -- Stock bought to resell is never posted above the cautious price it
        -- was judged at (the usual price and recent days' median): the
        -- chance it was bought on assumed that price, not the wall above it.
        local ceiling = nil
        local held = L.holding(item_id)
        if held and held.mode == "flip" then
            local risk = D.risk(rec)
            ceiling = risk and P.safe_reference(risk.usual, risk.median, nil) or nil
        end
        local price, why = P.post_price({
            market = market, lowest = lowest, vendor = vendor, cost = cost,
            cut_pct = M.policy.cut(), margin_pct = M.cfg("post_margin", 10),
            undercut = M.money("undercut"), ceiling_pct = M.cfg("post_ceiling", 200), ceiling = ceiling,
            below_floor = M.cfg("below_floor", 1) == 2 and "floor" or "hold",
        })
        out.why = why
        if price and single then
            -- Priced by roll in the Gear tab (this item's price mixes its rolls).
            out.action, out.why = "hand", "post it yourself: the Gear tab prices it by roll"
            out.value = (M.gear and M.gear.bag_value(item_id)) or P.net(price, M.policy.cut()) * count
        elseif price then
            out.action, out.price = "post", price
            out.value = P.net(price, M.policy.cut()) * count
        elseif vendor > 0 and (why == "worth more at a vendor" or not market) then
            out.action, out.value = "vendor", vendor * count
        else
            out.action, out.value = "keep", 0
        end
        return out
    end

    --- Advice for everything carried, most valuable first; cached two
    --- seconds (the window reads it every frame).
    function B.list()
        local t = core.time()
        if cache and t - cache_at < 2.0 then return cache end
        local items, order = B.read()
        local out = {}
        local min_value = M.money("sell_min_value")
        for i = 1, #order do
            local e = items[order[i]]
            local a = B.advise(e.id, e.count)
            a.slots = e.slots
            if (a.value or 0) >= min_value or a.action == "post" then out[#out + 1] = a end
        end
        table.sort(out, function(a, b) return (a.value or 0) > (b.value or 0) end)
        cache, cache_at = out, t
        return out
    end

    --- Every carried item a vendor buys, against the auction house (the
    --- user, 2026-10-07: "What Items in Bag to Vendor ... how much I'd get
    --- versus how much I bought or how much it would sell in AH"):
    ---   vendor  what a vendor pays for all of them
    ---   ah      what the auction house would bring for all of them, after its
    ---           cut, if they sell: at the price Auto would post, else the
    ---           cheapest other seller, else the market value (nil when it
    ---           cannot be listed, or there is no price to go on)
    ---   paid    what they cost, when bought here
    ---   best    "vendor" or "ah"; gain = the better of the two less paid
    --- Vendor-better first, most money first. Cached two seconds.
    local vcache, vcache_at = nil, -math.huge

    function B.vendor_list()
        local t = core.time()
        if vcache and t - vcache_at < 2.0 then return vcache end
        local items, order = B.read()
        local cut = M.policy.cut()
        local out = { rows = {}, vendor = 0, vendor_best = 0, vendor_best_n = 0, ah = 0 }
        for i = 1, #order do
            local e = items[order[i]]
            local a = B.advise(e.id, e.count)
            local vendor = (a.vendor or 0) * e.count
            if vendor > 0 then
                local each = a.price or a.lowest or a.market
                local ah = nil
                local no_ah = a.why == "soulbound" or a.why == "quest item"
                if each and each > 0 and not no_ah then ah = P.net(each, cut) * e.count end
                -- Gear: what its rolls would bring, roll by roll (gear.lua).
                if a.action == "hand" and M.gear and not no_ah then ah = M.gear.bag_value(e.id) or ah end
                local paid = a.cost and (a.cost * e.count) or nil
                local best = (not ah or vendor >= ah) and "vendor" or "ah"
                local row = { id = e.id, name = a.name, count = e.count, vendor = vendor, ah = ah, paid = paid,
                    best = best, why = a.why, no_ah = no_ah, auto = (L.holding(e.id) or {}).qty }
                local top = best == "vendor" and vendor or ah
                row.gain = paid and (top - paid) or nil
                out.rows[#out.rows + 1] = row
                out.vendor = out.vendor + vendor
                if ah then out.ah = out.ah + ah end
                if best == "vendor" then
                    out.vendor_best = out.vendor_best + vendor
                    out.vendor_best_n = out.vendor_best_n + 1
                end
            end
        end
        table.sort(out.rows, function(x, y)
            if (x.best == "vendor") ~= (y.best == "vendor") then return x.best == "vendor" end
            return x.vendor > y.vendor
        end)
        vcache, vcache_at = out, t
        return out
    end

    function B.invalidate() cache, vcache = nil, nil end

    --- What the bags would bring: posting what is worth posting at its
    --- advised price after the cut, vendoring the rest.
    function B.worth()
        local list = B.list()
        local total = 0
        for i = 1, #list do total = total + (list[i].value or 0) end
        return total
    end

    ctx.on("jambix.market.search", function() cache, vcache = nil, nil end)
    ctx.on("jambix.market.scan_done", function() cache, vcache = nil, nil end)

    return B
end

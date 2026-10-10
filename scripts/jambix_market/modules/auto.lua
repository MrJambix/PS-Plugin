-- Jambix Market / auto -- trading by itself, as long as it pays.
--
-- The user (2026-10-07): "Allow it to do everything automatically.. as long
-- as theres a profit that can be made... Buy, Sell, Cancel, Repost".
--
-- One switch: the AUTO button (auto_trade, off by default). Every part goes
-- through the trader's jobs (modules/trader.lua), so every check applies:
-- the fresh search, the server's quote re-checked against the plan, the
-- bag-slot check, and the money policy.lua allows.
--
-- While the auction house is open, once a second when nothing else is
-- running (no job, no search, no scan), the first of these that has work:
--
--   buy     the best deal (most profit per day it takes to sell), at the size
--           keeps gold above the reserve; each item at most every 5 minutes.
--           Gear deals too (gear.lua), which YOU post: never more than two
--           bought pieces waiting for you, and none once the game has left
--           two of its bids unanswered this session
--   post    what it bought (the ledger's holdings) that the Sell tab says to
--           post, no more than was bought and is not already up; with
--           auto_sell_all, anything else the Sell tab says to post as well
--   repost  every 5 minutes: read your auctions, search each item, and
--           cancel the undercut ones whose repost price still clears the
--           floor (vendor price, or cost plus margin) by more than the
--           cancel costs. The item comes back by mail, the mailbox part
--           collects it, and the post part posts it again. A post stays up
--           at least `repost_wait` minutes; `repost_max` reposts per item
--           per day.
--
-- Wherever you are:
--   collect when the mailbox is open: sale money, purchases, returned items
--   vendor  when a merchant window is open: what it bought that is worth more
--           to a vendor, one stack at a time, checked by where every item
--           sits (the same check as posting), recorded at the gold it brought

return function(M)
    local ctx, U, P, A, D, L, K, B, T, S =
        M.ctx, M.util, M.pricing, M.ah, M.db, M.ledger, M.deals, M.bags, M.trader, M.scanner

    local X = {}

    -- Declared here, set further down (the projection section): the loop above
    -- that section starts a session for Auto left on across a reload.
    local session, started

    local BUY_RETRY = 300
    local POST_RETRY = 600
    local REVIEW_EVERY = 300
    local OWNED_STALE = 300
    local COLLECT_GAP = 5
    local SELL_GAP = 0.8
    local SELL_SETTLE = 0.6
    local SELL_TIMEOUT = 3.0

    local CHECK_AGE = 120

    local tried_buy, tried_post, tried_check = {}, {}, {}
    local reposts = {}            -- item id -> { day, n }
    local review = { at = -math.huge, due = false, owned_asked = -math.huge }
    local stats = { buys = 0, posts = 0, cancels = 0, vendored = 0, vendor_gold = 0, collects = 0 }
    local last_collect = -math.huge
    local next_ah = 0
    local vendor_halted = nil
    local last_note = nil

    function X.active()
        return (M.cfg("enabled", true) and M.cfg("auto_trade", false)) and true or false
    end

    local function on(part) return X.active() and M.cfg(part, true) and true or false end

    local function note(text) last_note = { text = text, t = core.time() } end

    -- --- buy -------------------------------------------------------------------

    local function try_buy(t)
        if not on("auto_buy") then return false end
        -- What may be spent right now (policy.capital): the buy job plans
        -- within it and holds each deal to its Kelly share.
        local lim = T.limits()
        if lim.spend < math.max(1, M.policy.min_profit()) then
            note("waiting: " .. (lim.why or "too little gold free for any deal"))
            return false
        end
        -- Bought in the list's order: what each earns a day on the gold it
        -- ties up. Big money may use all a deal may get; any other deal only
        -- what keeps stock under half of capital (policy.capital: max_small).
        local deals = K.list()
        local held_back = nil
        -- Gear (gear.lua): bought like the rest, while no more than two
        -- pieces wait for you to post them and the game answers its bids.
        local gear_ok, gear_why = true, nil
        if M.gear then gear_ok, gear_why = M.gear.can_buy() end
        local gear_waits = false
        for i = 1, #deals do
            local d = deals[i]
            local key = d.key or d.item_id
            local tried = tried_buy[key]
            local spend = d.big and lim.spend or lim.spend_small
            if d.gear and not gear_ok then
                gear_waits = true
            else
                if not d.big and d.max_unit > spend and d.max_unit <= lim.spend then held_back = d end
                if (not tried or t - tried >= BUY_RETRY) and d.max_unit <= spend then
                    local plan = K.affordable(d, spend)
                    -- Big at the last look but not at what may be spent now: a
                    -- smaller deal, held to the half line (the review, 1.1.0).
                    if plan and d.big and not plan.big then
                        spend = lim.spend_small
                        plan = d.max_unit <= spend and K.affordable(d, spend) or nil
                        if not plan then held_back = held_back or d end
                    end
                    if plan then
                        tried_buy[key] = t
                        if T.buy(d.item_id, { auto = true, budget = spend, var = d.gear and d.var or nil }) then
                            stats.buys = stats.buys + 1
                            return true
                        end
                    end
                end
            end
        end
        if held_back then
            local cap = M.policy.capital()
            note(string.format("smaller deals wait: one more would take stock past half your money (%s of %s in "
                .. "stock); the rest is kept for big money (%s+)", U.money(cap.invested), U.money(cap.capital),
                U.money(M.policy.big_line(cap))))
        elseif gear_waits then
            note("gear deals wait: " .. tostring(gear_why))
        end
        return false
    end

    -- --- post ---------------------------------------------------------------------

    --- Units of each item up on the auction house now, from your auctions.
    local function listed_by_item()
        local list, at = T.owned()
        if not list then return nil end
        local out = {}
        for i = 1, #list do
            local a = list[i]
            if a.status ~= "sold" and a.item_id then out[a.item_id] = (out[a.item_id] or 0) + a.qty end
        end
        return out, at
    end

    --- How many of an item may be posted automatically right now.
    function X.postable(advice, listed)
        local h = L.holding(advice.id)
        if h and h.qty > 0 then
            -- Units Auto's posts sold whose mail is not collected are not in
            -- the bags any more: your own units of the item stay yours.
            local away = ((listed and listed[advice.id]) or 0) + T.pending_sold(advice.id)
            return math.min(advice.count, math.floor(h.qty - away))
        end
        if M.cfg("auto_sell_all", false) then return advice.count end
        return 0
    end

    local function try_sell(t)
        if not on("auto_sell") then return false end
        local listed, at = listed_by_item()
        if not listed or core.time() - at > OWNED_STALE then
            -- Know what is already up before posting more of it.
            if t - review.owned_asked >= 30 then
                review.owned_asked = t
                T.refresh_owned()
                return true
            end
            return false
        end
        local all = M.cfg("auto_sell_all", false)
        local items = B.read()
        for id, e in pairs(items) do
            local held = L.holding(id)
            -- Gear Auto bought is yours to post (Forever ignores post_item).
            if held and held.mode == "gear" then held = nil end
            if (held and held.qty > 0) or all then
                local a = B.advise(id, e.count)
                if a.action == "post" then
                    local limit = X.postable(a, listed)
                    local tried = tried_post[id]
                    if limit > 0 and (not tried or t - tried >= POST_RETRY) then
                        tried_post[id] = t
                        if T.post(id, { all = true, limit = limit, auto = true }) then
                            stats.posts = stats.posts + 1
                            return true
                        end
                    end
                elseif held and a.action == "keep" then
                    -- Held stock waiting on a price more than two minutes old:
                    -- look again, so stale data never parks it for good.
                    local _, age = A.last(id)
                    local checked = tried_check[id]
                    if age > CHECK_AGE and (not checked or t - checked >= CHECK_AGE) then
                        tried_check[id] = t
                        local rec = D.item(id)
                        A.search(id, { front = true, level = rec and rec.lv, reason = "auto-check" })
                        return true
                    end
                end
            end
        end
        return false
    end

    -- --- repost -----------------------------------------------------------------------

    --- Would cancelling this undercut auction and posting it again make a
    --- profit? Returns pays, the gain (copper), and the new price.
    function X.repost_pays(a)
        local advice = B.advise(a.item_id, a.qty)
        if advice.action ~= "post" or not advice.price then return false, 0, nil end
        if advice.price >= a.unit then return false, 0, advice.price end
        local cut = M.policy.cut()
        local cancel_cost = tonumber(A.call("get_cancel_cost", a.auction_id)) or 0
        -- Cancelling forfeits the deposit the post took (a sale would return
        -- it): the user's first live session, 2026-10-07, reposted for 1s a
        -- time when the API said a cancel cost nothing.
        local post = T.posts()[U.key(a.auction_id)]
        local forfeit = (post and tonumber(post.deposit)) or M.policy.deposit()
        local floor_unit = math.max(D.vendor(a.item_id) or 0, L.cost_basis(a.item_id) or 0)
        local gain = (P.net(advice.price, cut) - floor_unit) * a.qty - cancel_cost - forfeit
        return gain > 0, gain, advice.price
    end

    local function try_repost(t)
        if not on("auto_repost") then return false end
        if t - review.at >= REVIEW_EVERY then
            review.at, review.due = t, true
            T.refresh_owned()
            local list = T.owned()
            local seen = {}
            for i = 1, #(list or {}) do
                local a = list[i]
                if a.status ~= "sold" and a.item_id and not seen[a.item_id] then
                    seen[a.item_id] = true
                    local rec = D.item(a.item_id)
                    A.search(a.item_id, { front = true, level = rec and rec.lv, reason = "auto-review" })
                end
            end
            return true
        end
        -- The review runs on the first idle tick after its searches.
        if not review.due then return false end
        review.due = false
        local list = T.owned()
        if not list then return false end
        local all = M.cfg("auto_sell_all", false)
        local wait = M.cfg("repost_wait", 15) * 60
        local cap = M.cfg("repost_max", 3)
        local now, day = U.now(), U.day()
        local queued = false
        for i = 1, #list do
            local a = list[i]
            -- Only auctions this plugin posted: one you listed by hand is yours
            -- (the review, 1.0.0: yours were cancelled when Auto held the item),
            -- and so is gear you posted for it (Auto could not post it again).
            local post = T.posts()[U.key(a.auction_id)]
            if a.status == "undercut" and post and not post.hand and (all or L.holding(a.item_id)) then
                local r = reposts[a.item_id]
                if r and r.day ~= day then r = nil end
                if (not post or now - (post.t or 0) >= wait) and (not r or r.n < cap) then
                    local pays, gain, price = X.repost_pays(a)
                    if pays and T.cancel(a.auction_id, { item_id = a.item_id, auto = true }) then
                        reposts[a.item_id] = { day = day, n = (r and r.n or 0) + 1 }
                        -- It is posted again as soon as it is back in the bags.
                        tried_post[a.item_id] = nil
                        stats.cancels = stats.cancels + 1
                        queued = true
                        M.activity(string.format("Undercut: cancelling %s at %s to repost at %s (%s after the cancel)",
                            D.name(a.item_id), U.money(a.unit), U.money(price), U.signed(gain)))
                    end
                end
            end
        end
        return queued
    end

    -- --- mailbox -------------------------------------------------------------------------

    local function try_collect(t)
        if not on("auto_collect") or not L.mailbox_open() then return end
        local box = L.mailbox()
        if box and not box.collecting and L.mail_pending() > 0 and t - last_collect >= COLLECT_GAP then
            last_collect = t
            if L.collect() then stats.collects = stats.collects + 1 end
        end
    end

    -- --- vendor ------------------------------------------------------------------------------

    -- Jambix AIO's "sell junk" sells grey items at the same window, and both
    -- it and this check every sale by watching every carried item. So this
    -- waits while grey junk with a price is still carried (the AIO, or you,
    -- selling it), up to JUNK_WAIT after the window opens, and a grey item
    -- moving during one of these sales is not taken for a wrong sale.
    local JUNK_WAIT = 15

    local function is_junk(id)
        return D.quality(id) == 0 and (D.vendor(id) or 0) > 0
    end

    local function junk_carried(items)
        for id in pairs(items) do
            if is_junk(id) then return true end
        end
        return false
    end

    local shop = { open = false, skip = {} }

    ctx.on("jcore.game_event.MERCHANT_SHOW", function()
        shop = { open = true, skip = {}, opened = core.time(), next_at = core.time() + 1.0 }
    end)
    ctx.on("jcore.game_event.MERCHANT_CLOSED", function()
        -- A sale just made is still checked and recorded (vendor_tick).
        shop.open = false
    end)

    --- A stack of something bought here that a vendor pays more for, no
    --- bigger than what was bought (a stack merged with your own is left).
    local function next_vendor_stack(t)
        local items = B.read()
        if t - (shop.opened or 0) < JUNK_WAIT and junk_carried(items) then return nil end
        for id, e in pairs(items) do
            local h = L.holding(id)
            -- Gear bought to resell never goes to a vendor (it is held apart,
            -- by roll: this holding is a vendor flip or a resale).
            local mine = (h and h.mode ~= "gear") and (h.qty - T.pending_sold(id)) or 0
            if mine > 0 then
                local advice = B.advise(id, e.count)
                if advice.action == "vendor" then
                    -- A vendor flip of an item Auto also holds as gear: never a
                    -- slot of a roll it holds as gear, nor one whose roll cannot
                    -- be read (the review, 1.2.0: the gear piece was sold).
                    local guard = M.gear and M.gear.holds_gear(id)
                    for i = 1, #e.slots do
                        local sl = e.slots[i]
                        local skip = false
                        if guard then
                            local var = M.gear.slot_roll(sl.bag, sl.slot)
                            skip = var == nil or M.gear.holds_gear(id, var)
                        end
                        if not skip and sl.guid and not shop.skip[sl.guid] and sl.stack <= mine then return id, sl end
                    end
                end
            end
        end
        return nil
    end

    local function vendor_tick(t)
        local p = shop.pending
        if not p and (not shop.open or not on("auto_vendor") or vendor_halted) then return end
        if p then
            if t - p.at < SELL_SETTLE then return end
            local after = B.places()
            if not after then
                shop.pending = nil
                return
            end
            local took, intruder = B.check_moves(p.before, after, p.slot.guid, p.id, is_junk)
            if intruder then
                -- The item meant was sold too if it left its slot: record that.
                local g = L.gold_now()
                local gain = (g and p.gold0) and (g - p.gold0) or 0
                local was = p.before[p.slot.guid]
                if gain > 0 and (not after[p.slot.guid] or (was and after[p.slot.guid].at ~= was.at)) then
                    L.sold(p.id, p.slot.stack, gain, "vendor")
                end
                vendor_halted = string.format("%s left its bag slot instead of %s", D.name(intruder), D.name(p.id))
                M.log.fmt("warn", "VENDOR SELLING STOPPED: %s. Buy it back from the merchant's Buyback tab; "
                    .. "it stays off until the scripts are reloaded.", vendor_halted)
                shop.pending = nil
                return
            end
            local g = L.gold_now()
            local gain = (g and p.gold0) and (g - p.gold0) or 0
            if took or gain > 0 then
                if gain > 0 then
                    L.sold(p.id, p.slot.stack, gain, "vendor")
                    stats.vendor_gold = stats.vendor_gold + gain
                end
                stats.vendored = stats.vendored + 1
                shop.skip[p.slot.guid] = true
                shop.pending, shop.next_at = nil, t + SELL_GAP
            elseif t - p.at >= SELL_TIMEOUT then
                shop.skip[p.slot.guid] = true
                shop.pending = nil
            end
            return
        end
        if not shop.open or not on("auto_vendor") or vendor_halted then return end
        if t < (shop.next_at or 0) then return end
        ctx.inventory.invalidate()
        local id, slot = next_vendor_stack(t)
        if not id then
            shop.next_at = t + 2
            return
        end
        local before = B.places()
        if not before or not before[slot.guid] then
            shop.skip[slot.guid] = true
            return
        end
        local use = core.input and core.input.use_container_item
        if type(use) ~= "function" then
            vendor_halted = "core.input.use_container_item is missing"
            return
        end
        shop.pending = { id = id, slot = slot, before = before, gold0 = L.gold_now(), at = t }
        pcall(use, slot.bag, slot.slot)
    end

    -- --- the loop ----------------------------------------------------------------------------

    ctx.tick(function()
        local t = core.time()
        try_collect(t)
        vendor_tick(t)
        if X.active() and not session then started() end
        if not X.active() or not A.is_open() then return end
        if t < next_ah then return end
        next_ah = t + 1.0
        -- A quick scan's searches do not hold Auto up: its own go to the front.
        if T.busy() or S.busy() or A.pending_except("quick") > 0 or A.locked() then return end
        -- Away at the mailbox: nothing to trade until the auction house is open again.
        if M.errands and M.errands.running() then return end
        if try_buy(t) then return end
        if try_sell(t) then return end
        try_repost(t)
    end, { interval = 0.25 })

    ctx.on("jambix.market.ah_open", function()
        -- A fresh visit: review your auctions soon after the scan.
        review.at = core.time() - REVIEW_EVERY + 10
    end)

    -- --- the Auto button ----------------------------------------------------------------------
    --
    -- The user (2026-10-07): "add the Auto button on the UI where flips on and
    -- Goes ahead and start finding items". Starting records the gold the
    -- session budget is a share of, forgets every retry timer, reviews your
    -- auctions at once and, when the server allows one, starts a full scan.

    -- --- the projection -------------------------------------------------------------
    --
    -- The user (2026-10-07): "as the auto Start Trading ... it gives you a
    -- projection of how much money it identified in profits to be made so
    -- that way we see the number as it starts by itself".
    --
    --   identified  every deal on the list: the profit each would make
    --   projected   the deals Auto can actually buy now, best first, within
    --               the gold limits (trader.limits: the reserve, the deal
    --               limit, the stock share, Auto's budget), each counted at
    --               its profit times how sure it is (a deal bigger than the
    --               room left is counted in part, as it would be bought)
    --   stock       what the stock Auto holds is expected to make
    --   total       projected + stock: the number shown as "Projected profit"
    --
    -- Worked out at most once a second (the window reads it every frame).

    local proj, proj_at = nil, -math.huge
    session = nil                     -- { at, gold, start_total, announced }

    function X.projection()
        local t = core.time()
        if proj and t - proj_at < 1.0 then return proj end
        -- Exactly what Auto would spend: each deal its policy.size share
        -- (quarter Kelly), best expected profit per day first, until the free
        -- money and the stock room run out.
        local cap = M.policy.capital()
        local room = math.max(0, math.min(cap.free, cap.stock_room))
        local p = { identified = 0, identified_n = 0, projected = 0, projected_n = 0, spend = 0, stock = 0 }
        local deals = K.list()
        local least = M.policy.min_profit(cap)
        local small_room = math.max(0, math.min(room, cap.small_room))
        p.big_n, p.big = 0, 0
        -- Gear: only as many pieces as Auto may still buy ahead of you, and
        -- none while gear buying waits (the review, 1.2.0).
        local gear_room = 0
        if M.gear and M.gear.can_buy() then gear_room = M.gear.room() end
        for i = 1, #deals do
            local d = deals[i]
            p.identified, p.identified_n = p.identified + d.profit, p.identified_n + 1
            local counted = not d.gear or gear_room >= 1
            if counted and room >= least and d.cost > 0 and (d.big or small_room >= least) then
                -- Planned again at the size Auto may spend on it (a resale
                -- cannot be bought in part of a listing; the review, 1.0.0:
                -- a pro-rata share counted deals Auto could never buy).
                local plan = K.affordable(d, math.min(d.big and room or small_room, cap.max_deal))
                if plan and plan.cost > 0 and plan.cost <= room then
                    if d.gear then gear_room = gear_room - (plan.units or 1) end
                    p.projected = p.projected + (plan.expected or plan.profit * (plan.confidence or 1))
                    p.projected_n = p.projected_n + 1
                    if plan.big then p.big_n, p.big = p.big_n + 1, p.big + (plan.expected or 0) end
                    p.spend = p.spend + plan.cost
                    room = room - plan.cost
                    small_room = math.max(0, small_room - plan.cost)
                end
            end
        end
        p.stock = L.summary().stock_expected or 0
        p.total = p.projected + p.stock
        proj, proj_at = p, t
        return p
    end

    --- The session since Auto was switched on: when, the projection then, and
    --- what has been made since (the ledger's actual profit over that time).
    function X.session()
        if not session then return nil end
        local since = math.max(1, U.now() - session.at)
        return { since = since, start_total = session.start_total,
            made = L.auto_made(session.at) }
    end

    local function projection_line(p)
        return string.format("projected profit %s: %d deal(s) it can afford now (%s, spending %s)%s; "
            .. "%d deal(s) found in all worth %s", U.signed(p.total), p.projected_n, U.signed(p.projected),
            U.money(p.spend), p.stock ~= 0 and (", stock held " .. U.signed(p.stock)) or "",
            p.identified_n, U.signed(p.identified))
    end

    --- Says the projection: when Auto starts, and after each scan while it runs
    --- (the toast only the first time it has a number, and when it moves by a
    --- quarter or more; the activity list whenever it moves by 5% or more).
    local function announce(why)
        if not X.active() or not session then return end
        proj_at = -math.huge
        local p = X.projection()
        local last = session.announced
        if p.identified_n == 0 and p.stock == 0 then
            if not session.waiting then
                session.waiting = true
                M.activity("Auto: no profit found yet -- " .. why)
            end
            return
        end
        local moved = not last or math.abs(p.total - last) > math.max(100, math.abs(last) * 0.05)
        if not moved then return end
        local big = not last or math.abs(p.total - last) >= math.max(100, math.abs(last) * 0.25)
        session.announced = p.total
        if not session.start_total then session.start_total = p.total end
        M.activity("Auto: " .. projection_line(p))
        if big then M.toast("Projected profit " .. U.signed(p.total), "success") end
    end

    started = function()
        local gold = L.gold_now()
        T.set_auto_base(gold)
        tried_buy, tried_post, tried_check = {}, {}, {}
        if M.gear then M.gear.reset_bids() end
        review.at, review.owned_asked = -math.huge, -math.huge
        session = { at = U.now(), gold = gold }
        local cap = M.policy.capital()
        M.activity(string.format("Auto ON with %s: keeps %s, free to spend %s, one deal up to %s (sized to how sure it is)",
            U.money(gold or 0), U.money(cap.reserve), U.money(cap.free), U.money(cap.max_deal)))
        if A.is_open() then
            S.cycle_now()
        else
            M.activity("Auto: open the auction house to start trading")
        end
        announce(A.is_open() and "scanning the auction house now" or "open the auction house to scan")
    end

    M.ctx.on("jambix.market.scan_done", function() announce("the full scan found nothing worth buying") end)
    M.ctx.on("jambix.market.quick_done", function() announce("the quick scan found nothing worth buying") end)

    function X.start()
        if M.cfg("auto_trade", false) then return started() end
        M.menu:set("auto_trade", true)      -- the on_change below does the rest
    end

    function X.stop()
        M.menu:set("auto_trade", false)
    end

    function X.toggle()
        if X.active() then X.stop() else X.start() end
    end

    M.menu:on_change("auto_trade", function(on_now)
        if on_now then
            started()
        else
            T.stop_auto()
            local sess = X.session()
            M.activity("Auto OFF" .. (sess and string.format(" after %s: made %s", U.ago(sess.since),
                U.signed(sess.made)) or ""))
            session = nil
        end
    end)

    function X.stats() return stats end
    function X.vendor_halted() return vendor_halted end

    --- One line for the window.
    function X.status()
        if not X.active() then return "Automatic trading is off" end
        local parts = {}
        for _, p in ipairs({ { "auto_buy", "buy" }, { "auto_sell", "post" }, { "auto_repost", "repost" },
            { "auto_collect", "collect" }, { "auto_vendor", "vendor" } }) do
            if M.cfg(p[1], true) then parts[#parts + 1] = p[2] end
        end
        local cap = M.policy.capital()
        local line = string.format("Auto ON (%s). Free to spend %s; one deal up to %s, sized to how sure it is.",
            table.concat(parts, ", "), U.money(cap.free), U.money(cap.max_deal))
        if vendor_halted then line = line .. " Vendor selling stopped: " .. vendor_halted end
        if last_note and core.time() - last_note.t < 30 then line = line .. " " .. last_note.text .. "." end
        return line
    end

    return X
end

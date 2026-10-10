-- Jambix Market / trader -- buying, posting, cancelling. One thing at a time.
--
-- Everything that spends gold or lists an item is a JOB, run one at a time
-- from a queue, each holding the ah lock so no search is sent in the middle.
--
-- BUY. The deal is planned again on a search made right now (deals.plan_for,
-- the same function the list used), within: the most per deal, your gold
-- above the reserve, and for automatic buys what is left of the session's
-- budget. Then:
--   commodity  start_commodities_purchase -> COMMODITY_PRICE_UPDATED gives
--              the server's quote; confirmed only when it is within what the
--              plan was allowed to spend and what is free now, and the deal
--              still makes its least profit and is still as sure as the bar
--              (T.quote_ok); cancelled otherwise
--   item       place_bid at each planned auction's full buyout, one at a
--              time; each counted when the gold drops by its price
--   gear       an item purchase of ONE ROLL (gear.lua): the search must say
--              each auction's roll (its link), and only that roll's
--              auctions are planned and bid on. Bought gear is posted by you
--              (Forever ignores post_item); your post of it is taken into
--              the lot when your auctions are read (adopt, below)
--
-- POST. The price is pricing.post_price against a search made just before.
-- One bag slot per post. The slot comes from inventory_helper, the same
-- (bag, slot) pair Jambix AIO sells to vendors with, and like the AIO this
-- checks every post by where each carried item sits (by guid) before and
-- after: the item meant must leave its place and no other item may. If a
-- different item leaves, posting STOPS for the session and says what went,
-- so it can be cancelled from the Auctions tab.
--
-- CANCEL. cancel_auction, confirmed by AUCTION_CANCELED. The deposit is lost
-- (counted as a fee).

return function(M)
    local ctx, U, P, A, D, L, K, B = M.ctx, M.util, M.pricing, M.ah, M.db, M.ledger, M.deals, M.bags

    local T = {}

    local QUOTE_TIMEOUT = 5.0
    local CONFIRM_TIMEOUT = 8.0
    local BID_TIMEOUT = 4.0
    local POST_TIMEOUT = 6.0
    local POST_SETTLE = 1.0
    local CANCEL_TIMEOUT = 5.0
    local STEP_GAP = 0.6
    local SEARCH_FRESH = 20.0
    local OWNED_EVERY = 120

    local queue, job = {}, nil
    local halted = nil
    local auto_spent = 0
    local last = nil              -- { ok, text, t }

    local posts_store = ctx.store("posts")
    local posts = posts_store:all()   -- auction id -> { id, qty, unit, t }

    -- --- events ----------------------------------------------------------------

    local ev = {}
    -- AUCTION_CANCELED names the auction, and it fires for others' auctions
    -- too: every commodity purchase ends some (the user's recorder,
    -- 2026-10-07). A cancel is done when ITS auction is named.
    local cancelled = {}          -- auction id key -> core.time()
    ctx.on("jcore.game_event.AUCTION_CANCELED", function(args)
        local id = args and tonumber(args[1])
        if id then cancelled[U.key(id)] = core.time() end
    end)
    local WATCH = {
        "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
        "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_MULTISELL_FAILURE",
        "AUCTION_CANCELED", "UI_ERROR_MESSAGE",
    }
    for i = 1, #WATCH do
        local name = WATCH[i]
        ctx.on("jcore.game_event." .. name, function(args)
            ev[name] = { t = core.time(), args = args or {} }
        end)
    end

    local function fired(name, since)
        local e = ev[name]
        if e and e.t >= since then return e end
        return nil
    end

    --- An auction house refusal since `since`, as text, or nil.
    local function refusal(since)
        local e = fired("UI_ERROR_MESSAGE", since)
        if not e then return nil end
        local id, text = e.args[3], e.args[2]
        if type(id) == "string" and (id:find("AUCTION", 1, true) or id:find("BID", 1, true)
            or id == "ERR_NOT_ENOUGH_MONEY" or id == "ERR_ITEM_NOT_FOUND") then
            return tostring(text or id)
        end
        if type(text) == "string" and text:lower():find("auction", 1, true) then return text end
        return nil
    end

    -- --- jobs ----------------------------------------------------------------------

    local function finish(j, ok, text)
        A.unlock("trader")
        if job == j then job = nil end
        last = { ok = ok, text = text, t = core.time(), kind = j.kind }
        M.activity(text)
        if not ok and j.manual then M.toast(text, "warning") end
        if j.kind == "post" or j.kind == "cancel" then
            B.invalidate()
            T.owned_due = core.time() + 1.5
        end
    end

    local function in_queue(kind, key, value)
        if job and job.kind == kind and job[key] == value then return true end
        for i = 1, #queue do
            if queue[i].kind == kind and queue[i][key] == value then return true end
        end
        return false
    end

    --- Queues a purchase of an item's deal. opts: { auto, manual, budget,
    --- var = the roll, for a gear deal }.
    function T.buy(item_id, opts)
        opts = opts or {}
        if not A.is_open() then return false, "the auction house is closed" end
        if in_queue("buy", "item_id", item_id) then return false, "already buying it" end
        queue[#queue + 1] = { kind = "buy", item_id = item_id, auto = opts.auto, manual = opts.manual,
            budget = opts.budget, var = opts.var, step = "search" }
        return true
    end

    --- The name a job's item goes by: the roll's, for gear.
    local function job_name(j)
        if j.var ~= nil and M.gear then return M.gear.name(j.item_id, j.var) end
        return D.name(j.item_id)
    end

    --- Queues posting one stack of an item. opts: { all = every stack of it,
    --- limit = at most this many units in all, auto, manual }.
    function T.post(item_id, opts)
        opts = opts or {}
        if halted then return false, "posting is stopped: " .. halted end
        if not A.is_open() then return false, "the auction house is closed" end
        if in_queue("post", "item_id", item_id) then return false, "already posting it" end
        if opts.limit and opts.limit <= 0 then return false, "nothing to post" end
        queue[#queue + 1] = { kind = "post", item_id = item_id, manual = opts.manual, all = opts.all,
            limit = opts.limit, auto = opts.auto, skip = opts.skip or {}, step = "search" }
        return true
    end

    --- Queues every item the bags advise posting.
    function T.post_all()
        local list = B.list()
        local n = 0
        for i = 1, #list do
            if list[i].action == "post" and T.post(list[i].id, { all = true }) then n = n + 1 end
        end
        return n
    end

    function T.cancel(auction_id, opts)
        opts = opts or {}
        if not A.is_open() then return false, "the auction house is closed" end
        if in_queue("cancel", "auction_id", auction_id) then return false, "already cancelling it" end
        queue[#queue + 1] = { kind = "cancel", auction_id = auction_id, item_id = opts.item_id,
            manual = opts.manual, auto = opts.auto, step = "send" }
        return true
    end

    function T.clear_queue()
        queue = {}
    end

    --- Auto went off: its queued jobs go; a running one stops at its next
    --- step (run_buy, run_post and run_cancel check stopped()).
    function T.stop_auto()
        local kept = {}
        for i = 1, #queue do if not queue[i].auto then kept[#kept + 1] = queue[i] end end
        queue = kept
    end

    --- Anything running or waiting?
    function T.busy() return job ~= nil or #queue > 0 end
    function T.auto_spent() return auto_spent end

    -- --- buy ---------------------------------------------------------------------------

    -- --- what may be spent ----------------------------------------------------------
    --
    -- Decided by policy.lua from your gold and what Auto holds (the user,
    -- 2026-10-07: "automatically Know what to spend when to spend it and not
    -- relying on my Limits"). T.limits is that, in the shape the window and
    -- the projection read:
    --   reserve / above_reserve  the 10% always kept / what is free above it
    --   per_deal                 the most any one deal could get (half of capital)
    --   stock / stock_room       what Auto holds at cost / room under the 70% cap
    --   spend                    the most one deal may get right now; each deal
    --                            gets its own Kelly-sized share of it

    function T.set_auto_base() end

    function T.limits()
        local cap = M.policy.capital()
        return { gold = cap.gold, reserve = cap.reserve, above_reserve = cap.free,
            per_deal = cap.capital * 0.5, stock = cap.invested, stock_room = cap.stock_room,
            session = math.huge, spend = cap.max_deal, spend_small = cap.max_small, capital = cap.capital, why = cap.why }
    end

    local function buy_budget(j)
        local o = K.options()
        local lim = T.limits()
        local budget = lim.spend
        if j.budget then budget = math.min(budget, j.budget) end
        -- Planned on what may be spent now, then held to what this deal
        -- deserves (policy.size: quarter Kelly).
        o.budget, o.size = budget, true
        return o, budget, lim
    end

    --- Does the server's quote still make the deal worth it? The whole
    --- profit is checked at the quoted total -- not a tolerance on the price,
    --- which on a thin deal could still let it lose -- and a resale must
    --- still be as sure as the setting asks at that cost.
    function T.quote_ok(plan, total)
        if not plan or not total or total <= 0 then return false end
        -- Never more than the plan was allowed to spend, nor than is free now
        -- (the review, 1.0.0: a quote 25% over a plan made right up to the
        -- money free was confirmed, spending under the reserve).
        if plan.budget and plan.budget < math.huge and total > plan.budget then return false end
        if total > M.policy.capital().max_deal + 1 then return false end
        if total > plan.cost * 1.25 then return false end
        if plan.value - total < math.max(1, plan.min_profit or 0) then return false end
        if plan.mode == "flip" and plan.risk then
            local sure = P.flip_confidence(plan.risk, plan.units, total, plan.resale)
            if sure < (plan.risk.min_confidence or 0) then return false end
        end
        return true
    end

    local function bought(j, qty, cost, row)
        -- What each unit was expected to bring, after the cut for a resale.
        local plan = j.plan
        local unit = plan and (plan.mode == "vendor" and plan.resale or P.net(plan.resale, M.policy.cut()))
        -- The profit it was planned to make after its deposits (its share of
        -- the plan), and whether it was big money: the lot keeps both.
        -- At the price actually paid: a quote may come in over the plan's cost.
        local planned = plan and (plan.units or 0) > 0 and ((plan.value or 0) * qty / plan.units - cost) or nil
        -- Gear is held by roll, for you to post ("gear"); any single item's
        -- buy keeps the roll it took, so it is never read as a sale of it.
        local extra, mode = nil, plan and plan.mode or nil
        if j.var ~= nil then
            extra, mode = { var = j.var, vname = job_name(j), roll = j.var, aid = row and row.ref and row.ref.auction_id },
                "gear"
        elseif row and row.ref and row.ref.var ~= nil then
            extra = { roll = row.ref.var }
        end
        L.bought(j.item_id, qty, cost, mode, unit, plan and plan.confidence, planned, plan and plan.big or nil, extra)
        j.got_qty, j.got_cost = (j.got_qty or 0) + qty, (j.got_cost or 0) + cost
        if j.auto then auto_spent = auto_spent + cost end
    end

    local function buy_done(j)
        local name = job_name(j)
        if (j.got_qty or 0) > 0 then
            K.bought(j.var ~= nil and U.vkey(j.item_id, j.var) or j.item_id)
        end
        -- Look again, so the deal list and prices show what is left.
        A.search(j.item_id, { front = true, reason = "refresh" })
        if (j.got_qty or 0) > 0 then
            local plan = j.plan
            local each = plan.mode == "vendor" and plan.resale or P.net(plan.resale, M.policy.cut())
            if j.var ~= nil then
                -- Gear: Auto cannot post it. Say what to post, and at what.
                local cap = M.policy.capital()
                local share = j.got_qty / math.max(1, plan.units)
                local exp = (plan.expected or 0) * share - ((j.got_cost or 0) - (plan.cost or 0) * share)
                local text = string.format("%sBought %s%s for %s: post it yourself at %s buyout, 48 hours (Gear tab); "
                    .. "expecting %s, %s sure", plan.big and "Big money: " or "", name,
                    j.got_qty > 1 and (" x" .. j.got_qty) or "", U.money(j.got_cost), U.money(plan.resale),
                    U.signed(exp), string.format("%.1f%%", (plan.confidence or 0) * 100))
                if plan.big then text = text .. string.format(" (%.0f%% of your money)", exp / math.max(1, cap.capital) * 100) end
                M.toast(text, "success")
                return finish(j, true, text)
            end
            if plan.big then
                -- Big money: said apart, and popped up.
                local cap = M.policy.capital()
                -- The plan's share, less what the quote cost over the plan's price.
                local share = j.got_qty / math.max(1, plan.units)
                local exp = (plan.expected or 0) * share - ((j.got_cost or 0) - (plan.cost or 0) * share)
                local text = string.format("Big money: bought %dx %s for %s, expecting +%s (%.0f%% of your money), %s sure",
                    j.got_qty, name, U.money(j.got_cost), U.money(exp), exp / math.max(1, cap.capital) * 100,
                    string.format("%.1f%%", (plan.confidence or 1) * 100))
                M.toast(text, "success")
                return finish(j, true, text)
            end
            return finish(j, true, string.format("Bought %dx %s for %s, expecting %s (%s, %s sure)", j.got_qty, name,
                U.money(j.got_cost), U.signed(each * j.got_qty - j.got_cost),
                plan.mode == "vendor" and ("a vendor pays " .. U.money(plan.resale) .. " each")
                    or ("resell at " .. U.money(plan.resale) .. " each"),
                string.format("%.1f%%", (plan.confidence or 0) * 100)))
        end
        return finish(j, false, "Bought nothing of " .. name)
    end

    --- Auto was switched off: an Auto job stops before its next action (a
    --- purchase already confirmed is still seen through and recorded).
    local function stopped(j)
        return j.auto and not (M.auto and M.auto.active())
    end

    local function run_buy(j, t)
        local id = j.item_id
        local name = job_name(j)
        if stopped(j) and (j.step == "search" or j.step == "searching" or j.step == "start" or j.step == "bid"
            or j.step == "relook") then
            if (j.got_qty or 0) > 0 then return buy_done(j) end
            return finish(j, false, "Stopped buying " .. name .. ": Auto is off")
        end
        if j.step == "quote" and stopped(j) then
            A.call("cancel_commodities_purchase")
            return finish(j, false, "Stopped buying " .. name .. ": Auto is off")
        end
        if j.step == "relook" then
            if t < (j.wait_until or 0) then return end
            j.step = "search"
        end
        if j.step == "search" then
            local rec = D.item(id)
            j.step = "searching"
            A.search(id, { front = true, level = rec and rec.lv, reason = "buy" }, function(result, why)
                j.result, j.why, j.answered = result, why, true
            end)
            return
        end
        if j.step == "searching" then
            if not j.answered then return end
            if not j.result then return finish(j, false, "Could not look up " .. name .. ": " .. tostring(j.why)) end
            local o, budget, lim = buy_budget(j)
            if budget <= 0 then
                return finish(j, false, "Not buying " .. name .. ": " .. (lim.why or "nothing to spend"))
            end
            -- Gear: the search's auctions of this ROLL only, read from their
            -- links; a search that does not say each auction's roll is not
            -- bought from (gear.lua).
            local rows = j.result.rows
            if j.var ~= nil then
                rows = M.gear and M.gear.filter(rows, j.var, id)
                if not rows then
                    -- The client fills an auction's link in once it has loaded
                    -- the item: one more look a moment later.
                    if not j.relooked then
                        j.relooked, j.step, j.answered, j.result, j.wait_until = true, "relook", false, nil, t + 1.5
                        return
                    end
                    return finish(j, false, "Not buying " .. name .. ": the auction house did not say which roll each "
                        .. "auction is, and gear is never bought blind")
                end
            end
            local function plan_on(opts)
                if j.var ~= nil then return M.gear.plan_for(U.vkey(id, j.var), rows, opts) end
                return K.plan_for(id, rows, opts, j.result.kind == "item")
            end
            local plan = plan_on(o)
            -- The half line holds on what this search finds: a deal queued as
            -- big money that is not big at this size any more is held to what
            -- smaller deals may spend (the review, 1.1.0: a big flag from an
            -- older look let a smaller deal fill stock past half of capital).
            if plan and j.auto and not plan.big and budget > (lim.spend_small or 0) then
                if (lim.spend_small or 0) < 1 then
                    return finish(j, false, "Not buying " .. name .. ": not big money at this size, and smaller "
                        .. "deals stop at half your money in stock")
                end
                o.budget = lim.spend_small
                plan = plan_on(o)
            end
            if not plan then return finish(j, false, name .. ": the deal is gone") end
            j.plan = plan
            j.step = j.result.kind == "commodity" and "start" or "bid"
            j.i = 1
            return
        end
        if j.step == "start" then
            if not A.lock("trader") then return end
            j.at = t
            A.call("start_commodities_purchase", id, j.plan.units)
            j.step = "quote"
            return
        end
        if j.step == "quote" then
            local e = fired("COMMODITY_PRICE_UPDATED", j.at)
            if e then
                local total = tonumber(e.args[2])
                if total and T.quote_ok(j.plan, total) then
                    j.total, j.gold0, j.at = total, L.gold_now(), t
                    A.call("confirm_commodities_purchase", id, j.plan.units)
                    j.step = "confirm"
                    return
                end
                A.call("cancel_commodities_purchase")
                return finish(j, false, string.format("Not buying %s: the price moved (quoted %s for %d, planned %s)",
                    D.name(id), U.money(total), j.plan.units, U.money(j.plan.cost)))
            end
            if fired("COMMODITY_PRICE_UNAVAILABLE", j.at) then
                return finish(j, false, "Not buying " .. D.name(id) .. ": the auction house gave no price")
            end
            if t - j.at >= QUOTE_TIMEOUT then
                A.call("cancel_commodities_purchase")
                return finish(j, false, "Not buying " .. D.name(id) .. ": no price quote came back")
            end
            return
        end
        if j.step == "confirm" then
            local g = L.gold_now()
            local paid = (j.gold0 and g) and (j.gold0 - g) or 0
            if fired("COMMODITY_PURCHASE_SUCCEEDED", j.at) or paid >= j.total * 0.99 then
                bought(j, j.plan.units, paid > 0 and paid or j.total)
                return buy_done(j)
            end
            local why = refusal(j.at) or (fired("COMMODITY_PURCHASE_FAILED", j.at) and "the purchase failed")
            if why then return finish(j, false, "Buying " .. D.name(id) .. " failed: " .. why) end
            if t - j.at >= CONFIRM_TIMEOUT then
                return finish(j, false, "Buying " .. D.name(id) .. ": no confirmation (check your mailbox)")
            end
            return
        end
        if j.step == "bid" then
            local row = j.plan.rows[j.i]
            if not row then return buy_done(j) end
            if j.next_at and t < j.next_at then return end
            -- Gear: never more pieces waiting for you than the cap, counted
            -- piece by piece (the review, 1.2.0: one plan of two could take the
            -- count past it).
            if j.var ~= nil and M.gear and M.gear.room() < 1 then return buy_done(j) end
            local auction = row.ref and row.ref.auction_id
            if not auction then return finish(j, false, "Buying " .. name .. ": the listing has no auction id") end
            if not A.ready() or not A.lock("trader") then return end
            j.gold0, j.at = L.gold_now(), t
            A.call("place_bid", auction, row.cost)
            j.step = "bid_wait"
            return
        end
        if j.step == "bid_wait" then
            local row = j.plan.rows[j.i]
            local g = L.gold_now()
            if j.gold0 and g and j.gold0 - g >= row.cost - 1 then
                bought(j, row.qty, j.gold0 - g, row)
                if j.var ~= nil and M.gear then M.gear.note_bid(true) end
                j.i, j.step, j.next_at = j.i + 1, "bid", t + STEP_GAP
                A.unlock("trader")
                return
            end
            local why = refusal(j.at)
            if why or t - j.at >= BID_TIMEOUT then
                -- A bid on gear the game said nothing at all to: gear buying
                -- stops for the session after two (gear.lua).
                if j.var ~= nil and M.gear then M.gear.note_bid(false, why ~= nil) end
                if (j.got_qty or 0) > 0 then return buy_done(j) end
                return finish(j, false, "Buying " .. name .. " failed: " .. (why or "no answer"))
            end
        end
    end

    -- --- post --------------------------------------------------------------------------

    local function run_post(j, t)
        local id = j.item_id
        local name = D.name(id)
        if halted then return finish(j, false, "Posting is stopped: " .. halted) end
        if stopped(j) and j.step ~= "posted" and j.step ~= "verify" then
            return finish(j, false, "Stopped posting " .. name .. ": Auto is off")
        end
        if j.step == "search" then
            local r, age = A.last(id)
            if r and age <= SEARCH_FRESH then
                j.step = "price"
            else
                local rec = D.item(id)
                j.step = "searching"
                A.search(id, { front = true, level = rec and rec.lv, reason = "post" }, function(result, why)
                    j.answered, j.why = true, why
                    j.result = result
                end)
            end
            return
        end
        if j.step == "searching" then
            if not j.answered then return end
            if not j.result then return finish(j, false, "Could not look up " .. name .. ": " .. tostring(j.why)) end
            j.step = "price"
            return
        end
        if j.step == "price" then
            ctx.inventory.invalidate()
            local items = B.read()
            local e = items[id]
            if not e or #e.slots == 0 then return finish(j, false, "No " .. name .. " left in your bags") end
            local advice = B.advise(id, e.count)
            if advice.action ~= "post" then
                return finish(j, false, "Not posting " .. name .. ": " .. tostring(advice.why))
            end
            -- Not a stack this run already posted (a bag read can lag the post).
            local slot = nil
            for i = 1, #e.slots do
                if not j.skip[e.slots[i].guid or ""] then slot = e.slots[i] break end
            end
            if not slot then return finish(j, false, "No more " .. name .. " to post") end
            local qty = math.min(slot.stack, j.limit or slot.stack)
            if qty <= 0 then return finish(j, false, "Nothing of " .. name .. " to post") end
            local before = B.places()
            if not before or not slot.guid or not before[slot.guid] then
                return finish(j, false, "Not posting " .. name .. ": its bag slot could not be checked")
            end
            local r = A.last(id)
            local status = tonumber(A.call("get_item_commodity_status", slot.bag, slot.slot))
            local info = D.info(id)
            local commodity = status == 2
                or (status ~= 1 and ((r and r.kind == "commodity") or ((info and info.s or 1) > 1)))
            if not A.ready() or not A.lock("trader") then return end
            -- As long as it should take to sell, at the cautious sales rate.
            local duration = M.policy.duration(id, qty)
            j.slot, j.qty, j.before, j.price, j.gold0, j.at = slot, qty, before, advice.price, L.gold_now(), t
            j.duration = duration
            if commodity then
                A.call("post_commodity", slot.bag, slot.slot, duration, qty, advice.price)
            else
                A.call("post_item", slot.bag, slot.slot, duration, qty, advice.price, advice.price)
            end
            j.step = "posted"
            return
        end
        if j.step == "posted" then
            local why = refusal(j.at) or (fired("AUCTION_MULTISELL_FAILURE", j.at) and "the auction house refused it")
            if why then
                B.mark_unpostable(id, why)
                return finish(j, false, "Posting " .. name .. " failed: " .. why)
            end
            local created = fired("AUCTION_HOUSE_AUCTION_CREATED", j.at)
            if created then j.auction = created.args[1] end
            if (created and t - j.at >= POST_SETTLE) or t - j.at >= POST_TIMEOUT then j.step = "verify" end
            return
        end
        if j.step == "verify" then
            local after = B.places()
            if not after then return finish(j, false, "Posted " .. name .. "? The bags could not be read to check") end
            local took, intruder = B.check_moves(j.before, after, j.slot.guid, id)
            if intruder then
                halted = string.format("%s left its bag slot instead of %s", D.name(intruder), name)
                M.log.fmt("warn", "POSTING STOPPED: %s. Cancel it from the Auctions tab if it was listed; "
                    .. "posting stays off until the scripts are reloaded.", halted)
                return finish(j, false, "POSTING STOPPED: " .. halted)
            end
            -- The server saying it made the auction is enough; otherwise the
            -- item must have left its place or shrunk.
            if not j.auction and not took then
                B.mark_unpostable(id, "the post did not take")
                return finish(j, false, "Posting " .. name .. " did not take")
            end
            local g = L.gold_now()
            local deposit = (j.gold0 and g) and (j.gold0 - g) or 0
            local hours = ({ 12, 24, 48 })[j.duration] or 24
            if deposit > 0 then L.fee(id, deposit, "deposit", hours) end
            L.posted(id, j.qty, j.price, hours, deposit, j.auction)
            if j.auction then
                -- The deposit is kept with the post: policy.lua learns the
                -- auction house cut from what the sale mail pays against it.
                posts[U.key(j.auction)] = { id = id, qty = j.qty, unit = j.price, t = U.now(), deposit = deposit }
                posts_store:touch()
            end
            finish(j, true, string.format("Posted %dx %s at %s each%s", j.qty, name, U.money(j.price),
                deposit > 0 and (" (deposit " .. U.money(deposit) .. ")") or ""))
            -- More stacks of it, with the search just made.
            local left = j.limit and (j.limit - j.qty) or nil
            if j.all and (not left or left > 0) and not stopped(j) then
                ctx.inventory.invalidate()
                local items = B.read()
                j.skip[j.slot.guid] = true
                local more = false
                for _, sl in ipairs(items[id] and items[id].slots or {}) do
                    if not j.skip[sl.guid or ""] then more = true end
                end
                if more then T.post(id, { all = true, limit = left, auto = j.auto, skip = j.skip }) end
            end
        end
    end

    -- --- cancel ------------------------------------------------------------------------

    local function run_cancel(j, t)
        local label = j.item_id and D.name(j.item_id) or ("auction " .. tostring(j.auction_id))
        if j.step == "send" and stopped(j) then
            return finish(j, false, "Not cancelling " .. label .. ": Auto is off")
        end
        if j.step == "send" then
            if A.call("can_cancel_auction", j.auction_id) == false then
                return finish(j, false, "Cannot cancel " .. label .. " (sold, or bid on)")
            end
            if not A.ready() or not A.lock("trader") then return end
            j.gold0, j.at = L.gold_now(), t
            A.call("cancel_auction", j.auction_id)
            j.step = "wait"
            return
        end
        local e = fired("AUCTION_CANCELED", j.at)
        local named = cancelled[U.key(j.auction_id)]
        local done = (named and named >= j.at) or (e and tonumber(e.args[1]) == nil) or false
        local why = refusal(j.at)
        if done or why or t - j.at >= CANCEL_TIMEOUT then
            local g = L.gold_now()
            local cost = (j.gold0 and g) and (j.gold0 - g) or 0
            if cost > 0 then L.fee(j.item_id, cost, "cancel") end
            local post = posts[U.key(j.auction_id)]
            -- Its units left the auction house by our hand, not a buyer's.
            if done and j.item_id then D.note_own_removal(j.item_id, (post and post.qty) or j.qty or 0) end
            if done then L.cancelled(j.item_id, (post and post.qty) or j.qty or 0, j.auction_id) end
            posts[U.key(j.auction_id)] = nil
            posts_store:touch()
            if done then return finish(j, true, "Cancelled " .. label) end
            return finish(j, false, "Cancelling " .. label .. ": " .. (why or "no answer"))
        end
    end

    -- --- my auctions ---------------------------------------------------------------------

    local owned = { list = nil, at = nil }
    T.owned_due = nil

    --- Your auctions of gear Auto bought, posted by hand: each becomes a post
    --- of the lot (kept with Auto's posts, marked hand: Auto never cancels
    --- it), with its deposit -- seen taken, or Forever's 48-hour one -- so its
    --- sale settles the lot and its profit counts the deposit. Only an auction
    --- made after Auto last bought the roll (its creation seen since, or an
    --- auction id above every auction it bought), and only as many as Auto
    --- holds of the roll: any other is your own.
    local function adopt(list)
        if not M.gear then return end
        local up = {}
        for _, post in pairs(posts) do
            -- Up or sold: a post of yours that left unsold (gone) is not up.
            if post.hand and not post.settled and not post.gone then
                local k = U.vkey(post.id, post.var)
                up[k] = (up[k] or 0) + (post.qty or 1)
            end
        end
        for i = 1, #list do
            local a = list[i]
            local key = U.key(a.auction_id)
            -- Up (0), or already sold (1) before your auctions were read.
            if (a.status == 0 or a.status == 1) and a.var ~= nil and a.item_id and not posts[key]
                and M.gear.is_single(a.item_id) then
                local h = L.holding(a.item_id, a.var)
                local k = U.vkey(a.item_id, a.var)
                local made = M.gear.created_at(a.auction_id)
                local after = (made and h and made >= (h.last_buy or 0))
                    or (not made and h and h.aid and tonumber(a.auction_id) and tonumber(a.auction_id) > h.aid)
                if h and h.mode == "gear" and after and (up[k] or 0) + (a.qty or 1) <= (h.qty or 0) + 1e-6 then
                    up[k] = (up[k] or 0) + (a.qty or 1)
                    local qty = math.max(1, a.qty or 1)
                    local unit = (a.buyout or 0) / qty
                    local deposit, seen = M.gear.deposit_for(a.auction_id, a.item_id)
                    posts[key] = { id = a.item_id, var = a.var, qty = qty, unit = unit, t = U.now(), deposit = deposit,
                        hand = true, cut_seen = true, sold = a.status == 1 and U.now() or nil }
                    local vname = M.gear.name(a.item_id, a.var)
                    L.fee(a.item_id, deposit, "deposit", 48, a.var, not seen)
                    L.posted(a.item_id, qty, unit, 48, deposit, a.auction_id,
                        { var = a.var, vname = vname, by = "you", est = not seen })
                    M.activity(string.format("You posted %s at %s (deposit %s%s): it is in the ledger with what Auto "
                        .. "paid for it", vname, U.money(unit), U.money(deposit), seen and "" or ", estimated"))
                end
            end
        end
    end

    -- An auction made while Auto posts nothing is yours: read your auctions
    -- at once, so a piece of Auto's gear you just posted is taken in.
    ctx.on("jcore.game_event.AUCTION_HOUSE_AUCTION_CREATED", function()
        if not (job and job.kind == "post") then T.owned_due = core.time() + 1.5 end
    end)

    --- When your auctions were last read (core.time()), or nil.
    function T.owned_at() return owned.at end

    --- The posts were changed from outside (gear.lua closing one): keep them.
    function T.save_posts() posts_store:touch() end

    function T.refresh_owned()
        A.owned(function(list)
            if not list then return end
            local before = owned.list
            owned.list, owned.at = list, core.time()
            adopt(list)
            -- Our posts that sold, or left with too much time left to have
            -- expired, are sold units waiting for their mail: still Auto's
            -- until the money is collected (auto's postable leaves them out, so
            -- your own units of the item are not posted in their place).
            local still = {}
            for i = 1, #list do
                local a = list[i]
                still[U.key(a.auction_id)] = true
                local sold_post = posts[U.key(a.auction_id)]
                if sold_post and a.status == 1 and not sold_post.sold then sold_post.sold = U.now() end
            end
            for i = 1, #(before or {}) do
                local a = before[i]
                local gone_post = posts[U.key(a.auction_id)]
                if gone_post and not gone_post.sold and not still[U.key(a.auction_id)] then
                    if gone_post.hand then
                        -- Yours, gone without being seen sold: you may have
                        -- cancelled it, or it expired -- not a sale (the review,
                        -- 1.2.0). Its sale mail, if it sold unseen, still settles it.
                        gone_post.gone = gone_post.gone or U.now()
                    elseif (a.band or 0) >= 3 then
                        gone_post.sold = U.now()
                    end
                end
            end
            -- Forget posts that are no longer up, two days on.
            local live = {}
            for i = 1, #list do live[U.key(list[i].auction_id)] = true end
            local now = U.now()
            for k, p in pairs(posts) do
                if not live[k] and now - (p.t or 0) > 2 * 86400 then posts[k] = nil end
            end
            posts_store:touch()
        end, { front = true })
    end

    --- Units of an item Auto's own posts have sold whose mail is not yet
    --- collected (`var`: of that roll only).
    function T.pending_sold(item_id, var)
        local n = 0
        for _, post in pairs(posts) do
            if post.id == item_id and (var == nil or (post.var or "") == var) and post.sold and not post.settled then
                n = n + (post.qty or 0)
            end
        end
        return n
    end

    --- Is one of Auto's pieces of this roll up, sold, or just gone from your
    --- auctions (your post of it, unsettled)? Then a sale mail of the roll is
    --- Auto's sale (ledger.lua); otherwise it is yours.
    function T.hand_post_open(item_id, var)
        local now = U.now()
        for _, post in pairs(posts) do
            if post.hand and not post.settled and post.id == item_id and (post.var or "") == (var or "")
                and (not post.gone or now - post.gone <= 2 * 86400) then
                return true
            end
        end
        return false
    end

    -- A sale's money arrived: its post is settled (oldest first; for gear,
    -- a post of the same roll -- one seen sold, else one of yours that left
    -- your auctions unseen, or is still up: its mail came first).
    ctx.on("jambix.market.trade", function(row)
        if type(row) ~= "table" or row.kind ~= "sell" or not row.id then return end
        -- Gear: only Auto's own pieces settle its posts (a sale of yours does not).
        local left = row.var == nil and (row.qty or 0) or (row.mine or 0)
        while left > 0 do
            local oldest = nil
            for _, post in pairs(posts) do
                if post.id == row.id and (row.var == nil or (post.var or "") == row.var) and post.sold
                    and not post.settled and (not oldest or post.sold < oldest.sold) then
                    oldest = post
                end
            end
            if not oldest and row.var ~= nil then
                for _, post in pairs(posts) do
                    if post.hand and not post.settled and post.id == row.id and (post.var or "") == row.var
                        and (not oldest or (post.t or 0) < (oldest.t or 0)) then
                        oldest = post
                    end
                end
                if oldest then oldest.sold = oldest.sold or U.now() end
            end
            if not oldest then break end
            oldest.settled = true
            left = left - (oldest.qty or 0)
        end
        posts_store:touch()
    end)

    --- Money waiting in the mailbox, as best it can be known (the user,
    --- 2026-10-07: "How much money is at the mailbox waiting to be
    --- collected"): the sale mails the inbox held the last time a mailbox was
    --- open (exact), plus auctions that sold since and are not in it yet --
    --- Auto's at the price it posted, yours at their buyout -- after the cut
    --- and with the deposit that comes back with a sale (estimated).
    --- Returns { total, inbox, inbox_n, inbox_at, coming, coming_n }.
    function T.mail_waiting()
        local seen = L.inbox_seen()
        local out = { inbox = seen and seen.money or 0, inbox_n = seen and #(seen.mails or {}) or 0,
            inbox_at = seen and seen.at, coming = 0, coming_n = 0 }
        -- Inbox mails, by item name and quantity, to match sold auctions to.
        local unmatched = {}
        for _, m in ipairs(seen and seen.mails or {}) do
            local k = tostring(m.name) .. "\1" .. tostring(m.qty)
            unmatched[k] = (unmatched[k] or 0) + 1
        end
        local function waiting(item_id, qty, gross, deposit, var)
            -- A roll of gear's mail names the roll ("Bandit Cloak of the Monkey").
            local nm = (var ~= nil and var ~= "" and M.gear) and M.gear.name(item_id, var) or D.name(item_id)
            local k = nm .. "\1" .. tostring(qty)
            if (unmatched[k] or 0) > 0 then
                unmatched[k] = unmatched[k] - 1         -- its mail is already counted
                return
            end
            out.coming = out.coming + P.net(gross, M.policy.cut()) + (deposit or 0)
            out.coming_n = out.coming_n + 1
        end
        local counted = {}
        for k, post in pairs(posts) do
            if post.sold and not post.settled then
                counted[k] = true
                waiting(post.id, post.qty or 0, (post.unit or 0) * (post.qty or 0), post.deposit, post.var)
            end
        end
        for _, a in ipairs(owned.list or {}) do
            local k = U.key(a.auction_id)
            if a.status == 1 and not counted[k] and not posts[k] then
                -- Yours, posted by hand: the buyout, read as T.owned reads it.
                local each = a.buyout / math.max(1, a.qty)
                local ref = D.reference(D.item(a.item_id))
                local unit = each
                if ref and ref > 0 and a.qty > 1 and math.abs(math.log(math.max(a.buyout, 1) / ref))
                    <= math.abs(math.log(math.max(each, 1) / ref)) then
                    unit = a.buyout
                end
                waiting(a.item_id, a.qty, unit * a.qty, 0, a.var)
            end
        end
        out.total = out.inbox + out.coming
        return out
    end

    --- What one of your auctions asks per unit: Auto's post says; else the
    --- buyout, per unit for a commodity on the retail side and per auction
    --- otherwise -- whichever is nearer the item's price.
    local function unit_of(a, post)
        if post then return post.unit end
        local whole, each = a.buyout, a.buyout / math.max(1, a.qty)
        local ref = D.reference(D.item(a.item_id))
        if ref and ref > 0 and a.qty > 1 then
            return (math.abs(math.log(math.max(whole, 1) / ref)) <= math.abs(math.log(math.max(each, 1) / ref)))
                and whole or each
        end
        return each
    end

    --- Your auctions as they are, with no cheapest seller looked up:
    --- { item_id, unit, qty, sold, var }. (deals.own_signatures and gear.lua
    --- read these; the cheapest of a roll is found from listings that leave
    --- yours out, so they must not ask T.owned back.)
    function T.own_listings()
        local out = {}
        for i = 1, #(owned.list or {}) do
            local a = owned.list[i]
            out[#out + 1] = { item_id = a.item_id, qty = a.qty, sold = a.status == 1, var = a.var,
                unit = unit_of(a, posts[U.key(a.auction_id)]) }
        end
        return out
    end

    --- Your auctions with a per-unit price and how each stands against the
    --- cheapest other seller.
    function T.owned()
        if not owned.list then return nil end
        local out = {}
        for i = 1, #owned.list do
            local a = owned.list[i]
            local post = posts[U.key(a.auction_id)]
            local unit = unit_of(a, post)
            -- A single item against its own ROLL's cheapest other seller; the
            -- item's cheapest is another roll's price.
            local single = a.var ~= nil and M.gear and M.gear.is_single(a.item_id)
            local lowest, known
            if single then lowest, known = M.gear.lowest(a.item_id, a.var) end
            if not known then lowest = B.lowest(a.item_id) end
            local status
            if a.status == 1 then status = "sold"
            elseif not lowest then status = "only seller"
            elseif unit <= lowest then status = "cheapest"
            else status = "undercut" end
            out[#out + 1] = {
                auction_id = a.auction_id, item_id = a.item_id, qty = a.qty, unit = unit, band = a.band,
                lowest = lowest, status = status, bid = a.bid, var = single and a.var or nil,
                name = single and (a.vname or M.gear.name(a.item_id, a.var)) or nil, hand = post and post.hand or nil,
            }
        end
        return out, owned.at
    end

    -- --- the runner ----------------------------------------------------------------------

    ctx.tick(function()
        local t = core.time()
        if not A.is_open() then
            -- A purchase already confirmed or bid on completes on the server:
            -- watch for it a few more seconds, and record it.
            if job and job.kind == "buy" and (job.step == "confirm" or job.step == "bid_wait") then
                queue = {}
                return run_buy(job, t)
            end
            if job then finish(job, false, (job.kind == "buy" and "Buying" or job.kind == "post" and "Posting"
                or "Cancelling") .. " stopped: the auction house closed") end
            queue = {}
            return
        end
        if not job and #queue > 0 then job = table.remove(queue, 1) end
        if job then
            if not M.cfg("enabled", true) then
                finish(job, false, "Jambix Market is switched off")
                queue = {}
                return
            end
            if job.kind == "buy" then run_buy(job, t)
            elseif job.kind == "post" then run_post(job, t)
            elseif job.kind == "cancel" then run_cancel(job, t) end
            return
        end
        if T.owned_due and t >= T.owned_due then
            T.owned_due = t + OWNED_EVERY
            T.refresh_owned()
        end
    end)

    ctx.on("jambix.market.ah_open", function()
        T.owned_due = core.time() + 3
    end)

    function T.state()
        local desc = nil
        if job then
            desc = (job.kind == "buy" and "Buying " or job.kind == "post" and "Posting " or "Cancelling ")
                .. (job.item_id and D.name(job.item_id) or tostring(job.auction_id))
        end
        return { job = desc, queued = #queue, halted = halted, last = last, auto_spent = auto_spent }
    end

    function T.posts() return posts end

    return T
end

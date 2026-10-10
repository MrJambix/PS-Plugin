-- Jambix Market / ledger -- how much money you have, and what trading made.
--
-- GOLD is read from the client every two seconds (ctx.inventory.gold, which
-- asks GetMoney) and kept per calendar day: the first, last, lowest and
-- highest figure of each of the last 60 days. That is the honest answer to
-- "how much did I make": it counts everything, trading or not.
--
-- TRADES are what this plugin can attribute:
--   buy   recorded by the trader with what the purchase actually cost
--   fee   the deposit a post took (the drop in gold right after posting)
--   sell  the money in an "Auction successful" mail, recorded when that
--         money reaches your gold -- by the Collect button or by hand
-- Bought units are held at their average cost; a sale of an item you
-- bought through here is charged that cost, and anything else (farmed,
-- crafted) costs nothing. Realised profit = sales - their cost - fees.
-- A sale mail's money already has the cut taken and the deposit returned,
-- which is why fees are counted when paid and sales at what arrived.
--
-- THE JOURNAL. The user (2026-10-07): "make sure it can log internally all
-- trades so we know exactly how much money we've invested and returned and
-- by sell/buy". Every row is kept for good in its own file,
-- scripts_data/jcore/jambix.market.journal.json, never trimmed, and the
-- all-time totals are folded from it (L.totals), so "invested" and
-- "returned" are exact however long ago a trade was:
--   buy       qty, copper paid, the plan's mode, expected profit, how sure
--   sell      qty, copper that arrived (after the cut, deposit back), basis
--             (what Auto's units of it cost), mine (how many were Auto's;
--             the rest of a sale is your own items, kept apart)
--   fee       a deposit (with the auction's hours) or a cancel cost
--   post      an auction posted: qty, unit price, hours, deposit, auction id
--             (by = "you" for gear Auto bought that you posted)
--   cancel    an auction Auto cancelled: qty, auction id
--   returned  items back by mail: an expired, cancelled or won auction
--
-- GEAR (gear.lua) is held ROLL BY ROLL: a holding's key is "id:roll"
-- ("9779:12741", util.hkey; "13127:" for gear with no roll, never the item's
-- own key, so a vendor flip of the same item can never take its place) and
-- its rows carry var (the roll) and vname (the roll's name). A buy of any
-- single item also carries roll, the roll it bought, so its own purchase is
-- never read as a sale of that roll. A sale mail names the roll in full
-- ("Auction successful: Bandit Cloak of the Monkey"), so the roll is found by
-- name -- and it is Auto's sale only while one of its pieces of that roll is
-- up (your post of it, taken in by trader.lua); otherwise it is yours.
--   kept      a piece of Auto's gear that left its books unsold: not in the
--             bags, the auction house or the mailbox (you kept, equipped or
--             sold it yourself; gear.lua finds these). Its cost leaves the
--             stock; the lot ends without counting toward the success rate.

return function(M)
    local ctx, U, D = M.ctx, M.util, M.db

    local L = {}

    local MAX_TRADES = 1500
    local GOLD_DAYS = 60

    local store = ctx.store("ledger")
    local data = store:all()
    data.trades = type(data.trades) == "table" and data.trades or {}
    data.holdings = type(data.holdings) == "table" and data.holdings or {}
    data.days = type(data.days) == "table" and data.days or {}

    local function save() store:touch() end

    --- The holding key of an item, or of one roll of gear (see the top).
    local function hkey(item_id, var) return U.hkey(item_id, var) end

    -- The journal: every trade row, kept for good (see the top). The ledger's
    -- old trimmed list (data.trades) seeds it once and is not written again.
    local journal_store = ctx.store("journal")
    local journal = journal_store:all()
    journal.rows = type(journal.rows) == "table" and journal.rows or {}
    if #journal.rows == 0 and #data.trades > 0 then
        for i = 1, #data.trades do journal.rows[i] = data.trades[i] end
        journal_store:touch()
    end
    local function rows() return journal.rows end

    -- A day's low of 0 between an open and a close with money is the
    -- loading-screen read that got in before the ten-second rule (below):
    -- the lower of the two stands in for it.
    for _, d in pairs(data.days) do
        if type(d) == "table" and d.low == 0 and (d.open or 0) > 0 and (d.close or 0) > 0 then
            d.low = math.min(d.open, d.close)
        end
    end

    -- --- gold --------------------------------------------------------------------

    local gold = nil
    local session_start = nil
    local listeners = {}

    local function read_gold()
        local g = U.try(ctx.inventory.gold)
        if type(g) ~= "number" then g = U.try(core.inventory and core.inventory.get_gold) end
        return type(g) == "number" and g or nil
    end

    local function note_day(g)
        local day = tostring(U.day())
        local d = data.days[day]
        if not d then
            d = { open = g, close = g, low = g, high = g }
            data.days[day] = d
            -- Keep sixty days.
            local keys = {}
            for k in pairs(data.days) do keys[#keys + 1] = tonumber(k) end
            table.sort(keys)
            for i = 1, #keys - GOLD_DAYS do data.days[tostring(keys[i])] = nil end
        end
        d.close = g
        if g < d.low then d.low = g end
        if g > d.high then d.high = g end
        save()
    end

    -- A loading screen reads 0 for a moment (the user's game, 2026-10-07: a 0
    -- got into the day's low). A 0 is believed once it has held for ten
    -- seconds -- a character can really have no money.
    local zero_since = nil

    ctx.tick(function()
        local g = read_gold()
        if not g then return end
        if g == 0 and gold ~= 0 then
            local t = core.time()
            zero_since = zero_since or t
            if t - zero_since < 10 then return end
        else
            zero_since = nil
        end
        if not session_start then session_start = g end
        if g ~= gold then
            local before = gold
            gold = g
            note_day(g)
            for i = 1, #listeners do pcall(listeners[i], g, before) end
        end
    end, { interval = 2.0 })

    --- Copper now, or nil before the first read.
    function L.gold() return gold end

    --- Called with (gold, previous) on every change.
    function L.on_gold(fn) listeners[#listeners + 1] = fn end

    --- Reads gold right now, past the two-second poll (the trader checks a
    --- purchase with it).
    function L.gold_now()
        local g = read_gold()
        return g or gold
    end

    --- Today's change in what you are worth, with what Auto holds counted at
    --- what it cost: gold spent on stock is not gold lost (the user,
    --- 2026-10-07: "I got more Expenses thant Profit projections"). The gold
    --- change, plus what went into stock today, less the cost of what sold.
    local worth_cache = nil
    function L.worth_change_today()
        if worth_cache and core.time() - worth_cache.at < 1.0 then return worth_cache.v end
        local g = L.change_over(1)
        local v = nil
        if g then
            local now = U.now()
            local s = L.summary_since(now - now % 86400)      -- since midnight, as the day's gold is
            v = g + s.bought - s.basis
        end
        worth_cache = { at = core.time(), v = v }
        return v
    end

    function L.session_change()
        if not gold or not session_start then return nil end
        return gold - session_start
    end

    --- Change over the last `days` calendar days (today counts as one).
    function L.change_over(days)
        if not gold then return nil end
        local today = U.day()
        local first = nil
        for k, d in pairs(data.days) do
            local day = tonumber(k)
            if day and day > today - days and (not first or day < first.day) then
                first = { day = day, open = d.open }
            end
        end
        if not first then return nil end
        return gold - first.open
    end

    --- The last `n` days, newest first: { day, open, close, low, high, change }.
    function L.days(n)
        local keys = {}
        for k in pairs(data.days) do keys[#keys + 1] = tonumber(k) end
        table.sort(keys, function(a, b) return a > b end)
        local out = {}
        local potential = type(data.potential) == "table" and data.potential or {}
        for i = 1, math.min(n or 14, #keys) do
            local d = data.days[tostring(keys[i])]
            local p = potential[tostring(keys[i])]
            out[i] = { day = keys[i], open = d.open, close = d.close, low = d.low, high = d.high,
                change = d.close - d.open, potential = p and p.best or nil }
        end
        return out
    end

    -- --- trades -------------------------------------------------------------------

    -- Summaries are read every frame by the window: kept a second, and
    -- dropped whenever a trade is added.
    local summary_cache = {}

    -- --- all-time totals, folded from the journal --------------------------------

    --- Of a sale row: the money for Auto's units and for your own, and how
    --- many units were Auto's. (Rows from before `mine` was kept: Auto's
    --- when the sale had a cost or an expectation.)
    local function sale_split(r)
        local qty = r.qty or 0
        local mine = r.mine
        if mine == nil then mine = ((r.basis or 0) > 0 or r.expected ~= nil) and qty or 0 end
        local share = qty > 0 and math.min(1, mine / qty) or 0
        local auto = (r.copper or 0) * share
        return auto, (r.copper or 0) - auto, mine
    end

    local totals = nil

    local function fold(t, r)
        local kind = r.kind
        if kind == "buy" then
            t.invested = t.invested + (r.copper or 0)
            t.buys, t.units_bought = t.buys + 1, t.units_bought + (r.qty or 0)
            if r.expected then t.expected = t.expected + r.expected end
        elseif kind == "sell" then
            local auto, own, mine = sale_split(r)
            t.own_sales = t.own_sales + own
            if auto > 0 then
                t.returned = t.returned + auto
                if r.note == "vendor" then t.returned_vendor = t.returned_vendor + auto
                else t.returned_ah = t.returned_ah + auto end
                t.basis = t.basis + (r.basis or 0)
                t.sells, t.units_sold = t.sells + 1, t.units_sold + mine
            end
        elseif kind == "fee" then
            t.fees = t.fees + (r.copper or 0)
            if r.note == "cancel" then t.cancel_fees = t.cancel_fees + (r.copper or 0)
            else t.deposits = t.deposits + (r.copper or 0) end
        elseif kind == "post" then
            t.posts, t.units_posted = t.posts + 1, t.units_posted + (r.qty or 0)
        elseif kind == "cancel" then
            t.cancels = t.cancels + 1
        elseif kind == "returned" then
            t.mail_back = t.mail_back + 1
        elseif kind == "kept" then
            -- Gear of Auto's that became yours unsold: its cost left the stock.
            t.kept, t.kept_n = t.kept + (r.basis or 0), t.kept_n + (r.qty or 0)
        end
        if r.t and (not t.first or r.t < t.first) then t.first = r.t end
    end

    local function fold_all()
        local t = { invested = 0, returned = 0, returned_ah = 0, returned_vendor = 0, basis = 0, fees = 0,
            deposits = 0, cancel_fees = 0, own_sales = 0, expected = 0, buys = 0, sells = 0, units_bought = 0,
            units_sold = 0, posts = 0, units_posted = 0, cancels = 0, mail_back = 0, kept = 0, kept_n = 0,
            first = nil }
        local all = rows()
        for i = 1, #all do fold(t, all[i]) end
        return t
    end

    local function add_trade(row)
        summary_cache = {}
        row.t = row.t or U.now()
        local all = rows()
        all[#all + 1] = row
        journal_store:touch()
        if totals then fold(totals, row) end
        save()
        ctx.emit("jambix.market.trade", row)
        return row
    end

    --- Every trade ever, exactly: what went in, what came back, and what it
    --- made. invested / returned (Auto's stock only; returned_ah and
    --- returned_vendor), basis (what the sold units cost), fees (deposits +
    --- cancel_fees), own_sales (your own items, kept apart), profit =
    --- returned - basis - fees, in_stock (what Auto holds, at cost), cash =
    --- returned - invested - fees (what trading has put in or taken out of
    --- your gold so far), counts, and first (when the journal starts).
    function L.totals()
        totals = totals or fold_all()
        local out = {}
        for k, v in pairs(totals) do out[k] = v end
        local held = 0
        for _, h in pairs(data.holdings) do held = held + (h.cost or 0) end
        out.in_stock = held
        out.profit = totals.returned - totals.basis - totals.fees
        out.cash = totals.returned - totals.invested - totals.fees
        return out
    end

    --- An auction posted (the trader, once the server made it). extra:
    --- { var, vname, by, est } for gear you posted (est: its deposit estimated).
    function L.posted(item_id, qty, unit, hours, deposit, auction_id, extra)
        extra = extra or {}
        return add_trade({ kind = "post", id = item_id, qty = qty, copper = 0, unit = unit, hours = hours,
            deposit = deposit, auction = auction_id, var = extra.var, vname = extra.vname, by = extra.by,
            est = extra.est or nil })
    end

    --- An auction Auto cancelled (its deposit is a fee row of its own).
    function L.cancelled(item_id, qty, auction_id)
        return add_trade({ kind = "cancel", id = item_id, qty = qty or 0, copper = 0, auction = auction_id })
    end

    --- Items back by mail: an expired, cancelled or won auction.
    function L.returned(item_id, qty, why, name, var)
        return add_trade({ kind = "returned", id = item_id, qty = qty or 1, copper = 0, note = why, name = name,
            var = var })
    end

    --- A purchase. `mode` is the plan's ("vendor" or "flip") and
    --- `expected_unit` what each unit was expected to bring after the cut, so
    --- the profit expected at the time is kept beside the profit made later.
    -- A LOT is what Auto holds of an item from its first purchase until the
    -- last unit has sold: its sales, what those units cost, and every deposit
    -- and cancel fee the item took meanwhile. A lot made money when the first
    -- is more than the other two together. That -- not each sale mail, which
    -- by construction never sells under cost -- is what the success rate
    -- counts (the review, 1.0.0), and what the confidence bar tunes to.
    data.lots = type(data.lots) == "table" and data.lots or { n = 0, ok = 0 }

    -- Holdings bought before lots were kept (the user's game ran an early
    -- 1.0.0 build, 2026-10-07) get their lot rebuilt from the trades, the
    -- way it would have been kept, so they count toward the success rate.
    do
        local sim = {}
        local all = rows()
        for i = 1, #all do
            local tr = all[i]
            local k = tr.id and hkey(tr.id, tr.var)
            local h = k and sim[k]
            if k and tr.kind == "buy" then
                if not h or h.qty <= 0 then
                    h = { qty = 0, lot = { t = tr.t, net = 0, basis = 0, fees = 0, expected = 0, bought = 0,
                        conf = 0 } }
                    sim[k] = h
                end
                h.qty = h.qty + (tr.qty or 0)
                h.lot.expected = h.lot.expected + (tr.expected or 0)
                h.lot.bought = h.lot.bought + (tr.qty or 0)
                h.lot.conf = math.max(h.lot.conf, tr.conf or 0)
            elseif h and h.qty > 0 and tr.kind == "fee" then
                h.lot.fees = h.lot.fees + (tr.copper or 0)
            elseif h and h.qty > 0 and tr.kind == "sell" then
                h.qty = h.qty - math.min(tr.qty or 0, h.qty)
                h.lot.net = h.lot.net + (tr.copper or 0)
                h.lot.basis = h.lot.basis + (tr.basis or 0)
            end
        end
        for k, h in pairs(data.holdings) do
            if type(h) == "table" and (h.qty or 0) > 0 and type(h.lot) ~= "table" and sim[k] and sim[k].qty > 0 then
                h.lot = sim[k].lot
            end
        end
    end

    --- extra (gear, and any single item): { var = the roll held (mode
    --- "gear"), vname = its name, roll = the roll bought }.
    function L.bought(item_id, qty, cost, mode, expected_unit, confidence, planned, big, extra)
        extra = extra or {}
        local var = extra.var
        local k = hkey(item_id, var)
        local h = data.holdings[k] or { qty = 0, cost = 0, expect = 0 }
        if var ~= nil then
            -- Gear: which item and roll this holding is, and its name; when it
            -- was last bought, and the newest auction id it bought (an auction
            -- of yours made before either is not its piece: trader.adopt).
            h.id, h.var, h.name = item_id, var, extra.vname or h.name
            h.last_buy = U.now()
            if tonumber(extra.aid) then h.aid = math.max(h.aid or 0, tonumber(extra.aid)) end
        end
        if (h.qty or 0) <= 0 or type(h.lot) ~= "table" then
            h.lot = { t = U.now(), net = 0, basis = 0, fees = 0, expected = 0, bought = 0, conf = 0, planned = 0 }
        end
        -- What the lot was planned to make after its deposits (false once a
        -- purchase in it came without a plan: then it teaches nothing).
        if type(h.lot.planned) == "number" and type(planned) == "number" then
            h.lot.planned = h.lot.planned + planned
        else
            h.lot.planned = false
        end
        if big then h.lot.big = true end
        h.qty, h.cost = h.qty + qty, h.cost + cost
        h.expect = (h.expect or 0) + (expected_unit or 0) * qty
        h.mode = mode or h.mode
        local expected = expected_unit and (expected_unit * qty - cost) or nil
        h.lot.expected = h.lot.expected + (expected or 0)
        h.lot.bought = h.lot.bought + qty
        h.lot.conf = math.max(h.lot.conf or 0, confidence or 0)
        data.holdings[k] = h
        -- (The trader says it in the activity list, once per purchase.)
        return add_trade({ kind = "buy", id = item_id, qty = qty, copper = cost, mode = mode,
            expected = expected, conf = confidence, note = mode, var = var, vname = extra.vname,
            roll = extra.roll or var })
    end

    --- How a holding was bought ("vendor" / "flip" / "gear"), if it was
    --- bought here. `var`: the roll, for gear.
    function L.holding(item_id, var)
        return data.holdings[hkey(item_id, var)]
    end

    --- A deposit (with the auction's `hours`) or a cancel cost. `var`: the
    --- roll, for gear; `est`: an estimate (your post, not seen taken), which
    --- policy.lua does not learn deposits from.
    function L.fee(item_id, copper, note, hours, var, est)
        if not copper or copper <= 0 then return end
        local h = item_id and data.holdings[hkey(item_id, var)]
        if h and type(h.lot) == "table" then h.lot.fees = h.lot.fees + copper end
        return add_trade({ kind = "fee", id = item_id, qty = 0, copper = copper, note = note, hours = hours, var = var,
            est = est or nil })
    end

    --- A sale's money arrived. Charged the average cost of units bought here.
    --- `var`: the roll, for gear; `yours`: a sale of your own (a roll Auto
    --- has none of up), kept apart from Auto's stock.
    function L.sold(item_id, qty, net, note, var, yours)
        local basis, expected, mine = 0, nil, 0
        if item_id and not yours then
            local k = hkey(item_id, var)
            local h = data.holdings[k]
            if h and h.qty > 0 then
                local take = math.min(qty, h.qty)
                mine = take
                basis = h.cost / h.qty * take
                local share = (h.expect or 0) / h.qty * take
                -- What these units were expected to make when they were bought.
                expected = share - basis
                h.qty, h.cost, h.expect = h.qty - take, h.cost - basis, (h.expect or 0) - share
                if type(h.lot) == "table" then
                    h.lot.net, h.lot.basis = h.lot.net + net, h.lot.basis + basis
                end
                if h.qty <= 0 then
                    data.holdings[k] = nil
                    if type(h.lot) == "table" then
                        local lot = h.lot
                        local made = lot.net - lot.basis - lot.fees
                        data.lots.n = data.lots.n + 1
                        if made > 0 then data.lots.ok = data.lots.ok + 1 end
                        M.activity(string.format("Lot of %s done: made %s (expected %s)", h.name or D.name(item_id),
                            U.signed(made), U.signed(lot.expected)))
                        ctx.emit("jambix.market.lot_done", { id = item_id, made = made, expected = lot.expected,
                            ok = made > 0, conf = lot.conf, t = U.now(), mode = h.mode,
                            days = (U.now() - (lot.t or U.now())) / 86400,
                            planned = type(lot.planned) == "number" and lot.planned or nil, big = lot.big == true,
                            var = h.var, name = h.name })
                    end
                end
            end
        end
        local made = net - basis
        M.activity(string.format("Sold %dx %s: %s arrived%s", qty,
            (var ~= nil and var ~= "" and note) or (item_id and D.name(item_id)) or (note or "?"),
            U.money(net), expected and string.format(" (profit %s, expected %s)", U.signed(made), U.signed(expected))
                or ""))
        return add_trade({ kind = "sell", id = item_id, qty = qty, copper = net, basis = basis,
            expected = expected, note = note, mine = mine, var = var })
    end

    --- The item and roll a mail names ("Bandit Cloak of the Monkey"): an
    --- item's own name first (a single item Auto holds as gear with no roll
    --- is that gear), else a roll of gear by its full name. var nil: not gear.
    function L.resolve(name)
        local id = D.id_by_name(name)
        if id then
            local g = data.holdings[hkey(id, "")]
            if g and g.mode == "gear" and (g.qty or 0) > 0 then return id, "" end
            return id, nil
        end
        if M.gear then
            local gid, var = M.gear.by_name(name)
            if gid then return gid, var end
        end
        return nil, nil
    end

    --- A sale of gear is Auto's only while one of its pieces of that roll is
    --- up (your post of it, which trader.lua took in); otherwise it is yours.
    local function gear_sale_is_yours(id, var)
        if var == nil or not id then return false end
        return not (M.trader and M.trader.hand_post_open(id, var))
    end

    --- A piece of Auto's gear left its books unsold (gear.lua: not in the
    --- bags, the auction house or the mailbox -- you kept, equipped, banked
    --- or sold it yourself). Its cost leaves the stock at what it cost; the
    --- lot ends uncounted (nothing was sold).
    function L.release(item_id, qty, var, why)
        local k = hkey(item_id, var)
        local h = data.holdings[k]
        if not h or (h.qty or 0) <= 0 then return nil end
        local take = math.min(qty or 1, h.qty)
        local basis = h.cost / h.qty * take
        local share = (h.expect or 0) / h.qty * take
        h.qty, h.cost, h.expect = h.qty - take, h.cost - basis, (h.expect or 0) - share
        if h.qty <= 1e-9 then data.holdings[k] = nil end
        M.activity(string.format("%s%s is no longer in your bags, the auction house or the mailbox: taken off Auto's "
            .. "stock (cost %s) as yours", h.name or D.name(item_id), take > 1 and (" x" .. take) or "", U.money(basis)))
        return add_trade({ kind = "kept", id = item_id, qty = take, copper = 0, basis = basis, var = var,
            vname = h.name, note = why })
    end

    --- The best profit the deal list offered on each day (the most any one
    --- look at the market showed), so missed chances are on record too.
    function L.note_potential(total, count)
        data.potential = type(data.potential) == "table" and data.potential or {}
        local day = tostring(U.day())
        local p = data.potential[day]
        if not p or total > p.best then
            data.potential[day] = { best = total, deals = count }
            local keys = {}
            for k in pairs(data.potential) do keys[#keys + 1] = tonumber(k) end
            table.sort(keys)
            for i = 1, #keys - GOLD_DAYS do data.potential[tostring(keys[i])] = nil end
            save()
        end
    end

    --- Average cost per unit of what is still held from purchases here
    --- (`var`: of that roll of gear).
    function L.cost_basis(item_id, var)
        local h = data.holdings[hkey(item_id, var)]
        if not h or h.qty <= 0 then return nil end
        return h.cost / h.qty
    end

    function L.holdings() return data.holdings end
    --- Every trade row ever, oldest first (the journal).
    function L.trades() return rows() end

    --- Totals over the last `days` days (all when nil), and per item.
    ---   profit          sales - their cost - fees (the actual figure)
    ---   expected_buys   what the purchases were expected to make when made
    ---   flips_expected / flips_actual
    ---                   for units bought here AND since sold: what they were
    ---                   expected to make, and what they did (before fees)
    ---   stock_cost / stock_expected
    ---                   what is still held from purchases here, and what it
    ---                   is expected to make
    function L.summary(days)
        local ck = days or "all"
        local hit = summary_cache[ck]
        if hit and core.time() - hit.at < 1.0 then return hit.s end
        local s = L.summary_since(days and (U.now() - days * 86400) or -math.huge)
        summary_cache[ck] = { at = core.time(), s = s }
        return s
    end

    --- Totals over trades from epoch `since` on (see L.summary).
    function L.summary_since(since)
        local s = { bought = 0, sold = 0, basis = 0, fees = 0, buys = 0, sales = 0, items = {},
            expected_buys = 0, flips_expected = 0, flips_actual = 0, flips = 0, flips_ok = 0,
            conf_sum = 0, conf_n = 0, other_sales = 0, posts = 0, cancels = 0 }
        local all = rows()
        -- Newest first, back to `since` (the journal is in time order).
        for i = #all, 1, -1 do
            local r = all[i]
            if (r.t or 0) < since then break end
            local money = r.kind == "buy" or r.kind == "fee" or r.kind == "sell"
            local auto, own, mine = 0, 0, 0
            if r.kind == "sell" then
                auto, own, mine = sale_split(r)
                s.other_sales = s.other_sales + own
                money = auto > 0
            elseif r.kind == "post" then
                s.posts = s.posts + 1
            elseif r.kind == "cancel" then
                s.cancels = s.cancels + 1
            end
            if money then
                -- Gear by roll: a roll's buys, sales and fees are its own row.
                local key = tostring(r.id and hkey(r.id, r.var) or r.note or "?")
                local it = s.items[key]
                if not it then
                    it = { id = r.id, bought = 0, bought_qty = 0, sold = 0, sold_qty = 0, basis = 0, fees = 0,
                        expected = 0 }
                    s.items[key] = it
                end
                if r.var and r.var ~= "" and not it.name then it.name = r.vname or (r.kind == "sell" and r.note) or nil end
                if r.kind == "buy" then
                    s.bought, s.buys = s.bought + r.copper, s.buys + 1
                    it.bought, it.bought_qty = it.bought + r.copper, it.bought_qty + (r.qty or 0)
                    if r.expected then
                        s.expected_buys = s.expected_buys + r.expected
                        it.expected = it.expected + r.expected
                    end
                    if r.conf then s.conf_sum, s.conf_n = s.conf_sum + r.conf, s.conf_n + 1 end
                elseif r.kind == "sell" then
                    -- Auto's units only; your own items' money is other_sales.
                    s.sold, s.sales = s.sold + auto, s.sales + 1
                    s.basis = s.basis + (r.basis or 0)
                    it.sold, it.sold_qty = it.sold + auto, it.sold_qty + mine
                    it.basis = it.basis + (r.basis or 0)
                    if r.expected then
                        s.flips = s.flips + 1
                        s.flips_expected = s.flips_expected + r.expected
                        s.flips_actual = s.flips_actual + (auto - (r.basis or 0))
                        if auto - (r.basis or 0) > 0 then s.flips_ok = s.flips_ok + 1 end
                    end
                elseif r.kind == "fee" then
                    s.fees = s.fees + r.copper
                    it.fees = it.fees + r.copper
                end
            end
        end
        s.profit = s.sold - s.basis - s.fees
        -- The success rate: purchase lots that made money once all sold, with
        -- their fees (all time); beside it, how sure the purchases were.
        s.lots, s.lots_ok = data.lots.n, data.lots.ok
        s.success = data.lots.n > 0 and (data.lots.ok / data.lots.n) or nil
        s.predicted = s.conf_n > 0 and (s.conf_sum / s.conf_n) or nil
        for _, it in pairs(s.items) do it.profit = it.sold - it.basis - it.fees end
        local held, expect = 0, 0
        for _, h in pairs(data.holdings) do
            held = held + h.cost
            expect = expect + (h.expect or 0) - h.cost
        end
        s.stock_cost, s.stock_expected = held, expect
        return s
    end

    -- --- the mailbox -------------------------------------------------------------------
    --
    -- Sale mails are counted while the mailbox is open. A mail that leaves
    -- the inbox (or whose money is taken) while gold rises by its money is a
    -- sale that arrived; one that leaves without the gold is a delete.

    local SOLD_PATTERNS = { "^Auction successful: (.-) %((%d+)%)$", "^Auction successful: (.+)$" }
    -- Mails carrying items back: a purchase, or a cancelled or expired post
    -- (which automatic reposting then posts again).
    local WON_PATTERNS = { "^Auction won: (.-) %((%d+)%)$", "^Auction won: (.+)$",
        "^Auction cancelled: (.+)$", "^Auction expired: (.+)$" }
    local WON_KIND = { "won", "won", "cancelled", "expired" }

    local function parse(subject, patterns)
        if type(subject) ~= "string" then return nil end
        for i = 1, #patterns do
            local name, qty = subject:match(patterns[i])
            if name then return name, tonumber(qty) or 1, i end
        end
        return nil
    end

    local mail = { open = false, last = nil, gold = nil, queue = nil, next_at = 0 }

    -- Every other mail with money or items is taken too (the user,
    -- 2026-10-07: "pick up all the mail") -- except one with a COD charge:
    -- taking it would pay the charge. Those are left, and counted.
    local function read_inbox()
        local n = tonumber(U.try(core.mail and core.mail.get_num_inbox_items)) or 0
        local sold, won, other, cod = {}, {}, {}, 0
        local by_key = {}
        for i = 1, n do
            local h = U.try(core.mail.get_inbox_header_info, i)
            if type(h) == "table" and (tonumber(h.cod_amount) or 0) > 0 then
                cod = cod + 1
            elseif type(h) == "table" then
                local money = tonumber(h.money) or 0
                local items = tonumber(h.item_count) or 0
                local name, qty = parse(h.subject, SOLD_PATTERNS)
                if name and money > 0 then
                    local key = h.subject .. "\1" .. money
                    local e = by_key[key]
                    if not e then
                        e = { name = name, qty = qty, money = money, count = 0 }
                        by_key[key] = e
                    end
                    e.count = e.count + 1
                    sold[#sold + 1] = { index = i, name = name, qty = qty, money = money }
                else
                    local wname, wqty, which = parse(h.subject, WON_PATTERNS)
                    if wname and items > 0 then
                        won[#won + 1] = { index = i, name = wname, qty = wqty, why = WON_KIND[which] }
                    elseif money > 0 or items > 0 then
                        other[#other + 1] = { index = i, money = money, items = items, subject = h.subject }
                    end
                end
            end
        end
        return { by_key = by_key, sold = sold, won = won, other = other, cod = cod, n = n }
    end

    --- The sale mails the inbox held the last time a mailbox was open, kept
    --- (in the ledger file) so the money waiting there is known with the
    --- mailbox shut: { at, mails = { { name, qty, money } } }.
    local function remember_inbox(r)
        local mails, total = {}, 0
        for i = 1, #r.sold do
            local m = r.sold[i]
            mails[#mails + 1] = { name = m.name, qty = m.qty, money = m.money }
            total = total + m.money
        end
        -- Item mails (won, returned, or anything else) and other money, so a
        -- mail run knows there is something to fetch; and the names on the
        -- won, cancelled and expired ones (lower case -> how many), so a piece
        -- of Auto's gear in the mailbox is known to be there (gear.lua).
        local items, other_money = #r.won, 0
        local named = {}
        for i = 1, #r.won do
            local lk = tostring(r.won[i].name):lower()
            named[lk] = (named[lk] or 0) + 1
        end
        for i = 1, #(r.other or {}) do
            if r.other[i].items > 0 then items = items + 1 end
            other_money = other_money + r.other[i].money
        end
        local was = data.inbox
        if not was or was.money ~= total or #(was.mails or {}) ~= #mails or was.items ~= items
            or was.other_money ~= other_money then
            data.inbox = { at = U.now(), money = total, mails = mails, items = items, other_money = other_money,
                cod = r.cod or 0, named = named }
            save()
        else
            was.at, was.named = U.now(), named
        end
    end

    function L.inbox_seen() return data.inbox end

    local function settle_mail(now_read, g)
        local before = mail.last
        if before and mail.gold and g then
            local gone, total = {}, 0
            for key, e in pairs(before.by_key) do
                local left = now_read.by_key[key] and now_read.by_key[key].count or 0
                if left < e.count then
                    gone[#gone + 1] = { e = e, n = e.count - left }
                    total = total + e.money * (e.count - left)
                end
            end
            local rose = g - mail.gold
            if #gone > 0 then
                if rose >= total - 1 then
                    for i = 1, #gone do
                        local e = gone[i].e
                        local id, var = L.resolve(e.name)
                        for _ = 1, gone[i].n do
                            L.sold(id, e.qty, e.money, e.name, var, gear_sale_is_yours(id, var))
                        end
                    end
                else
                    M.debug("mail: %d sale mail(s) left the inbox without their %s; not counted",
                        #gone, U.money(total))
                end
            end
        end
        mail.last, mail.gold = now_read, g
        remember_inbox(now_read)
    end

    ctx.on("jcore.game_event.MAIL_SHOW", function()
        mail.open, mail.last, mail.gold, mail.queue = true, nil, nil, nil
    end)
    ctx.on("jcore.game_event.MAIL_CLOSED", function()
        if mail.open then settle_mail(read_inbox(), L.gold_now()) end
        mail.open, mail.queue = false, nil
    end)

    ctx.tick(function()
        if not mail.open then return end
        local t = core.time()
        -- Collect, one mail at a time, from the bottom up so indices hold.
        if mail.queue and t >= mail.next_at then
            local job = table.remove(mail.queue)
            if job then
                if job.kind == "money" then
                    U.try(core.mail.take_inbox_money, job.index)
                else
                    U.try(core.mail.auto_loot_mail_item, job.index)
                    if job.name then
                        local id, var = L.resolve(job.name)
                        L.returned(id, job.qty, job.why, job.name, var)
                    end
                end
                mail.next_at = t + 0.8
            else
                mail.queue = nil
                M.activity("Mailbox: auction mail collected")
            end
        end
        settle_mail(read_inbox(), L.gold_now())
    end, { interval = 0.5 })

    function L.mailbox_open() return mail.open end

    --- What the open mailbox holds from the auction house.
    function L.mailbox()
        local r = mail.last
        if not mail.open or not r then return nil end
        local money = 0
        for i = 1, #r.sold do money = money + r.sold[i].money end
        local other_money = 0
        for i = 1, #(r.other or {}) do other_money = other_money + r.other[i].money end
        return { sales = #r.sold, money = money, won = #r.won, other = #(r.other or {}), other_money = other_money,
            cod = r.cod or 0, collecting = mail.queue ~= nil }
    end

    --- Mails still to take that could be taken now: every sale, and every
    --- item mail while there is bag room. 0 when the mailbox is shut.
    function L.mail_pending()
        local r = mail.last
        if not mail.open or not r then return 0 end
        local free = U.try(ctx.inventory.free_slots) or 0
        local n = #r.sold
        for i = 1, #r.other do
            if r.other[i].money > 0 or (r.other[i].items > 0 and free > 0) then n = n + 1 end
        end
        if free > 0 then n = n + #r.won end
        return n
    end

    --- Takes the money from every sale mail, the items from every won,
    --- cancelled or expired one, and the money and items of every other mail
    --- (items while there is bag room) -- never a mail with a COD charge.
    function L.collect()
        local r = mail.last
        if not mail.open or not r then return false, "the mailbox is not open" end
        local jobs = {}
        for i = 1, #r.sold do jobs[#jobs + 1] = { index = r.sold[i].index, kind = "money" } end
        local free = U.try(ctx.inventory.free_slots) or 0
        for i = 1, #r.won do
            if free > 0 then
                jobs[#jobs + 1] = { index = r.won[i].index, kind = "items", name = r.won[i].name,
                    qty = r.won[i].qty, why = r.won[i].why }
                free = free - 1
            end
        end
        -- Everything else: its money, and its items while there is room.
        for i = 1, #(r.other or {}) do
            local o = r.other[i]
            if o.money > 0 then jobs[#jobs + 1] = { index = o.index, kind = "money" } end
            if o.items > 0 and free > 0 then
                jobs[#jobs + 1] = { index = o.index, kind = "items" }
                free = free - o.items
            end
        end
        -- Highest index taken first (table.remove pops the end).
        table.sort(jobs, function(a, b) return a.index < b.index end)
        mail.queue, mail.next_at = jobs, core.time()
        return true
    end

    -- "A buyer has been found for your auction of X." -- a sale, before its
    -- mail. It goes in the activity list; the money is counted from the mail.
    ctx.on("jcore.game_event.CHAT_MSG_SYSTEM", function(args)
        local text = args and args[1]
        if type(text) ~= "string" then return end
        local name = text:match("^A buyer has been found for your auction of (.+)%.$")
        if name then
            M.activity("Sold: " .. name)
            M.toast("Sold: " .. name, "success")
            ctx.emit("jambix.market.sold_notice", name)
            return
        end
        local won = text:match("^You won an auction for (.+)$")
        if won then
            ctx.emit("jambix.market.won_notice", (won:gsub("%.$", "")))
        end
    end)

    --- What Auto made since `since` (epoch): its own stock's sales less what
    --- those units cost, less the deposits and cancels of items it bought. Your
    --- own items' sale mails are not Auto's making.
    function L.auto_made(since)
        local auto_items = {}
        for k in pairs(data.holdings) do auto_items[k] = true end
        for _, r in ipairs(rows()) do
            if r.kind == "buy" and r.id then auto_items[U.key(r.id)] = true end
        end
        local made = 0
        local all = rows()
        for i = 1, #all do
            local r = all[i]
            if (r.t or 0) >= since then
                if r.kind == "sell" and r.expected ~= nil then
                    made = made + sale_split(r) - (r.basis or 0)
                elseif r.kind == "fee" and r.id and auto_items[U.key(r.id)] then
                    made = made - r.copper
                end
            end
        end
        return made
    end

    --- The "clear the ledger" button: every trade, the journal too.
    function L.reset_trades()
        data.lots = { n = 0, ok = 0 }
        data.trades, data.holdings = {}, {}
        journal.rows, totals, summary_cache = {}, nil, {}
        journal_store:touch()
        save()
    end

    return L
end

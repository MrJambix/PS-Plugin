-- Jambix Market / window -- one AUTO button, and six tabs that show what it
-- is doing.
--
-- The user (2026-10-07): "add the Auto button on the UI where flips on and
-- Goes ahead and start finding items....Remove Manual posting and all that
-- make it all AUTO!!!" So there is no Buy, Post or Cancel button anywhere:
-- the button at the top switches Auto on (modules/auto.lua) and the tabs
-- report.
--
--   Overview  your gold, what it allows Auto to spend, what the bags and your
--             auctions are worth, profit on offer, expected and actual
--             profit, the scan, the mailbox, the best deals and sellers, and
--             what just happened
--   Deals     what is worth buying now (Auto buys from the top)
--   Gear      weapons, armor and other single items, by roll: what to post
--             yourself and at what buyout (Forever never lets Auto post
--             them), the gear deals, and cheap rolls not sure enough to buy
--   Sell      what you carry and what Auto does with each: post, vendor, keep
--   Auctions  your auctions: cheapest or undercut, and what each makes if it sells
--   Market    every item: what sells most, what does not sell, what moved
--   Ledger    what trading has bought, sold and made, expected against
--             actual; gold and profit on offer by day
--
-- Tables are never sorted by the toolkit: rows are built sorted, and the
-- selection is kept by item (or auction) id, so a list that re-sorts under
-- the cursor never moves the selection onto another row.

return function(M)
    local U, P, A, D, L, K, B, T, S, X =
        M.util, M.pricing, M.ah, M.db, M.ledger, M.deals, M.bags, M.trader, M.scanner, M.auto

    local W = {}

    local TABS = { "Overview", "Deals", "Gear", "Sell", "Vendor", "Auctions", "Market", "Ledger" }
    local MARKET_VIEWS = { "Best sellers", "Listed, not selling", "Most valuable", "Price drops",
        "Price rises", "Most listed", "Everything" }
    local LEDGER_PERIODS = { "Today", "7 days", "30 days", "All time" }
    local PERIOD_DAYS = { 1, 7, 30, nil }

    local selected = {}           -- table id -> key of the selected row
    local market_cache, market_key, market_at = nil, nil, -math.huge

    -- --- cells --------------------------------------------------------------------

    -- A table cell given as a table is only unwrapped by JCore's ui:table when
    -- it has an icon or a colour; any other table is drawn as "table: 0x...".
    -- So every table cell here carries a colour, and a plain one is a string.
    local function item_cell(id, name)
        name = name or D.name(id)
        if M.cfg("icons", true) then return { icon = "item:" .. tostring(id), text = name } end
        return { text = name, color = U.QUALITY_COLOR[D.quality(id) or 1] or "text" }
    end

    local function money_cell(c, tone)
        if c == nil then return { text = "-", color = "text_dim" } end
        if tone == nil then return U.money(c) end
        return { text = U.money(c), color = tone }
    end

    local function signed_cell(c)
        if c == nil then return { text = "-", color = "text_dim" } end
        return { text = U.signed(c), color = c > 0 and "success" or (c < 0 and "danger" or "text_dim") }
    end

    --- A table whose selection follows a key, not a row number.
    local function keyed_table(ui, tid, columns, rows, keys, opts)
        opts = opts or {}
        local want, idx = selected[tid], 0
        if want ~= nil then
            for i = 1, #keys do
                if keys[i] == want then idx = i break end
            end
            if idx == 0 then selected[tid] = nil end
        end
        opts.selected = idx
        local _, clicked = ui:table(tid, columns, rows, opts)
        if clicked then selected[tid] = keys[clicked] end
        return selected[tid]
    end

    local function band_text(b)
        return ({ "<30m", "30m-2h", "2-12h", "12h+" })[b or 0] or "-"
    end

    local function small(ui, text, color)
        ui:text(text, { size = "small", color = color or "text_dim", wrap = true })
    end

    local function sure_text(p)
        if not p then return "-" end
        if p >= 0.9995 then return "100%" end
        return string.format("%.1f%%", math.floor(p * 1000) / 10)
    end

    --- "12 of 12 purchases ... (100%), 99.4% predicted" -- the success rate
    --- measured on real purchase lots (ledger.lua), beside what they predicted.
    local function success_line(sum)
        if not sum.success then return "no purchase has sold out yet" end
        return string.format("%d of %d purchases made money once sold (%s)%s", sum.lots_ok, sum.lots,
            sure_text(sum.success),
            sum.predicted and (", " .. sure_text(sum.predicted) .. " predicted") or "")
    end

    -- --- the header: the AUTO button, gold, and what the gold allows ------------------

    local function header(ui)
        local on = X.active()
        if ui:button("auto", on and "AUTO IS ON  -  click to stop" or "AUTO IS OFF  -  click to start trading", {
            style = on and "danger" or "success",
            tooltip = on and "Stops buying, posting and reposting. Nothing already listed is touched."
                or "Buys deals, posts what it buys, reposts when undercut, collects mail and sells vendor "
                    .. "flips by itself, within the gold limits",
        }) then
            X.toggle()
        end

        -- The projection, in big type: what Auto has found to make
        -- (auto.projection: the deals it can afford, by how sure each is,
        -- plus what its stock should bring).
        local proj = X.projection()
        ui:text("Projected profit  " .. U.signed(proj.total),
            { size = 20, color = proj.total > 0 and "success" or "text_dim" })
        small(ui, string.format("%d deal(s) Auto can buy now: %s (spending %s)%s  |  found in all: %d deal(s), %s",
            proj.projected_n, U.signed(proj.projected), U.money(proj.spend),
            proj.stock ~= 0 and ("  |  stock held: " .. U.signed(proj.stock)) or "",
            proj.identified_n, U.signed(proj.identified)), proj.total > 0 and "text" or "text_dim")
        local sess = X.session()
        if sess then
            small(ui, string.format("Since Auto started %s ago: made %s%s", U.ago(sess.since), U.signed(sess.made),
                sess.start_total and (" (projected " .. U.signed(sess.start_total) .. " when it found its first deals)")
                    or ""), sess.made >= 0 and "success" or "warning")
        end

        -- Gold spent on stock is not gold lost: the stock is shown beside the
        -- gold, and "today" counts it at what it cost.
        local gold = L.gold()
        local held = L.summary(1)
        ui:row({ 0.30, 0.30, 0.26, 0.14 })
        ui:text("Gold  " .. (gold and U.money(gold) or "..."), { color = "warning" })
        ui:text("In stock  " .. U.money(held.stock_cost), { color = "accent", size = "small" })
        local today = L.worth_change_today()
        ui:text("Today " .. (today and U.signed(today) or "-"),
            { color = (today or 0) >= 0 and "success" or "danger", size = "small" })
        ui:text(A.is_open() and "AH open" or "AH closed",
            { color = A.is_open() and "success" or "text_dim", size = "small", align = "right" })
        ui:end_row()
        if held.stock_cost > 0 then
            small(ui, string.format("Spent %s on stock that should sell for %s: %s profit once sold. Today counts "
                .. "stock at what it cost.", U.money(held.stock_cost), U.money(held.stock_cost + held.stock_expected),
                U.signed(held.stock_expected)), "text_dim")
        end
        -- Gear Auto bought is yours to post (Forever never lets it): say what.
        if M.gear then
            local to_post = M.gear.to_post()
            if #to_post > 0 then
                small(ui, "Post these yourself (Gear tab), 48 hours: " .. M.gear.post_line(to_post), "accent")
            end
        end
        local mw = T.mail_waiting()
        if mw.total > 0 then
            small(ui, string.format("Waiting in the mailbox: %s%s%s. Open a mailbox to collect it.", U.money(mw.total),
                mw.inbox > 0 and string.format(" (%d sale mail(s), %s, seen %s ago)", mw.inbox_n, U.money(mw.inbox),
                    U.ago(U.now() - (mw.inbox_at or U.now()))) or "",
                mw.coming > 0 and string.format(" (%d auction(s) sold since, about %s)", mw.coming_n, U.money(mw.coming))
                    or ""), "success")
        end

        -- What the plugin has decided about your money right now (policy.lua).
        local cap = M.policy.capital()
        local ok_n, done_n = M.policy.record()
        small(ui, string.format("Capital %s  |  keeps %s  |  free %s  |  in stock %s  |  one deal up to %s, sized to "
            .. "how sure it is  |  bar %.1f%%%s  |  AH cut %.1f%%", U.money(cap.capital), U.money(cap.reserve),
            U.money(cap.free), U.money(cap.invested), U.money(cap.max_deal), M.policy.bar() * 100,
            done_n > 0 and string.format(" (%d/%d made money)", ok_n, done_n) or "", M.policy.cut()),
            cap.max_deal > 0 and "text_dim" or "warning")
        -- Big money (deals.lua): waiting for money, on the list, or where it starts.
        local wait = K.big_waiting()
        local big_n, big_e = K.big()
        if big_n > 0 then
            small(ui, string.format("Big money on the list: %d deal(s), +%s expected (big money starts at %s: 5%% of "
                .. "your %s, at least 20s).", big_n, U.money(big_e), U.money(M.policy.big_line(cap)),
                U.money(cap.capital)), "success")
        else
            small(ui, string.format("Big money starts at %s (5%% of your %s, at least 20s). Never bought: under %s, "
                .. "or under twice its deposits.", U.money(M.policy.big_line(cap)), U.money(cap.capital),
                U.money(M.policy.min_profit(cap))), "text_dim")
        end
        if wait then
            small(ui, string.format("Big money once money is free: %s, +%s, needs %s; one deal may get %s now.",
                K.name(wait), U.money(wait.full_expected or 0), U.money(wait.need or 0), U.money(cap.max_deal)),
                "accent")
        end
        small(ui, string.format("Smaller deals fill stock up to %s (half your money); the rest, up to %s, is kept for "
            .. "big money.", U.money(cap.capital * 0.5), U.money(cap.capital * 0.7)), "text_dim")
        if on and cap.max_deal < M.policy.min_profit(cap) then
            small(ui, string.format("Auto is waiting: %s. It always keeps 10%% of your money and at most 70%% in "
                .. "stock, and buys again as money frees up.", cap.why or "too little gold free for any deal"), "warning")
        end
        small(ui, X.status(), on and "warning" or "text_dim")
        if M.errands then
            -- The movement switch, here and on the settings page: one value.
            local want = M.cfg("mail_runs", false) == true
            local v, changed = ui:checkbox("mail_runs", "Walk to the mailbox and back to the auctioneer by itself",
                want, { tooltip = "Off: you walk to the mailbox yourself, and Auto takes the mail when you open it." })
            if changed then
                M.menu:set("mail_runs", v and true or false)
            elseif v ~= want then
                W.set_value("mail_runs", want)     -- changed on the settings page
            end
            local line, tone = M.errands.status()
            if line then small(ui, line, tone) end
        end
        if M.presence then
            local line, tone = M.presence.status()
            if line then small(ui, line, tone) end
        end

        if S.busy() or S.quick_busy() then
            local _, f, line = S.progress()
            ui:progress(f, { text = line })
        end

        local st = T.state()
        if st.halted then
            small(ui, "Posting stopped: " .. st.halted, "danger")
        elseif st.job then
            small(ui, st.job .. (st.queued > 0 and string.format(" (%d more queued)", st.queued) or ""), "accent")
        elseif st.last and core.time() - st.last.t < 20 then
            small(ui, st.last.text, st.last.ok and "success" or "warning")
        end
    end

    -- --- Overview ------------------------------------------------------------------------

    local function listed_value()
        local list = T.owned()
        if not list then return nil end
        local total = 0
        for i = 1, #list do
            local a = list[i]
            if a.status ~= "sold" then total = total + P.net(a.unit * a.qty, M.policy.cut()) end
        end
        return total
    end

    local function overview(ui)
        local gold = L.gold() or 0
        local bags = B.worth()
        local listed = listed_value()
        local sum = L.summary()

        ui:separator("Money")
        ui:row({ 0.5, 0.5 })
        ui:key_value("Gold", U.money(gold))
        ui:key_value("Last 7 days", L.change_over(7) and U.signed(L.change_over(7)) or "-")
        ui:end_row()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Bags would bring", U.money(bags))
        ui:key_value("Your auctions", listed and U.money(listed) or "open the AH")
        ui:end_row()
        local mailed = T.mail_waiting().total
        ui:row({ 0.5, 0.5 })
        ui:key_value("Waiting in the mailbox", U.money(mailed))
        ui:key_value("Profit on offer now", U.money(K.potential()))
        ui:end_row()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Worth in all", U.money(gold + bags + (listed or 0) + mailed))
        ui:key_value("", "")
        ui:end_row()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Stock held (cost)", U.money(sum.stock_cost))
        ui:key_value("Expected from stock held", U.signed(sum.stock_expected))
        ui:end_row()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Profit made (sold, after fees)", U.signed(sum.profit))
        ui:key_value("Deposits paid", U.money(sum.fees))
        ui:end_row()
        small(ui, "A deposit comes back when the auction sells and is lost when it is cancelled or expires. "
            .. "Profit made counts only what has sold.", "text_dim")
        local xs = X.stats()
        small(ui, string.format("Auto this session: %d buy(s), %d post(s), %d repost(s), %d vendor sale(s) for %s.",
            xs.buys, xs.posts, xs.cancels, xs.vendored, U.money(xs.vendor_gold)))
        small(ui, "Success so far: " .. success_line(sum) .. ".", sum.success and (sum.success >= 0.95 and "success"
            or "warning") or "text_dim")

        ui:separator("Auction house")
        local meta = D.meta()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Last full scan", meta.last_scan and (U.ago(U.now() - meta.last_scan) .. " ago") or "never")
        ui:key_value("Items tracked", tostring(D.stats().items))
        ui:end_row()
        if S.unsupported() then
            small(ui, "Full scans have not answered three times in a row; quick scans keep prices fresh.", "warning")
        end
        local every = math.max(3, tonumber(M.cfg("scan_every", 3)) or 3)
        local due = S.next_due() - U.now()
        local lq = S.last_quick()
        small(ui, string.format("Scans every %d min while the auction house is open: a full scan every %s, as "
            .. "often as the server gives one (%s), a quick re-check of what matters in between%s.", every,
            U.ago(S.gap()), due > 0 and ("next in " .. U.ago(due)) or "due now",
            lq and string.format("; last quick scan %s ago, %d item(s)", U.ago(core.time() - lq.at), lq.total) or ""))

        local box = L.mailbox()
        if box then
            ui:separator("Mailbox")
            small(ui, string.format("%d sale(s) worth %s, %d item mail(s)%s", box.sales, U.money(box.money), box.won,
                box.collecting and " -- collecting" or (X.active() and "" or " -- Auto collects them when it is on")))
        end

        ui:separator("Best deals")
        local deals = K.list()
        if #deals == 0 then
            small(ui, meta.last_scan and "Nothing worth buying in the last scan."
                or "Press AUTO at the auction house: it scans, then finds deals.")
        end
        for i = 1, math.min(4, #deals) do
            local d = deals[i]
            small(ui, string.format("%s%s  %dx  profit %s  (%s)", d.big and "BIG  " or "", K.name(d), d.units,
                U.money(d.profit), d.mode == "vendor" and "vendor flip" or (d.gear and "gear: you post it" or "resell")),
                d.big and "success" or "text")
        end

        ui:separator("Selling fastest")
        local top = W.market_rows(1, "")
        if #top == 0 then small(ui, "Sales show after two scans at least a minute apart.") end
        for i = 1, math.min(4, #top) do
            local r = top[i]
            small(ui, string.format("%s  %s  at %s", D.name(r.id), U.rate(r.per_day), U.money(r.rec.m)), "text")
        end

        ui:separator("Activity")
        local log = M.activity_log()
        for i = #log, math.max(1, #log - 6), -1 do
            small(ui, U.ago(U.now() - log[i].t) .. "  " .. log[i].text)
        end
    end

    -- --- Deals ---------------------------------------------------------------------------

    local DEAL_COLUMNS = {
        { label = "Item", w = 0.21 }, { label = "Size", w = 0.06 }, { label = "Kind", w = 0.07 },
        { label = "Units", w = 0.05, align = "right" }, { label = "Pay up to", w = 0.10, align = "right" },
        { label = "Cost", w = 0.10, align = "right" }, { label = "Sell at", w = 0.10, align = "right" },
        { label = "Expected", w = 0.10, align = "right" }, { label = "Sure", w = 0.08, align = "right" },
        { label = "A day", w = 0.07, align = "right" }, { label = "Sold", w = 0.06, align = "right" },
    }

    local function deals_tab(ui)
        local deals = K.list()
        local age = K.age()
        small(ui, string.format("%d deal(s)%s, %s profit on offer. %s", #deals,
            age and (" from data " .. U.ago(age) .. " old") or "", U.money(K.potential()),
            X.active() and M.cfg("auto_buy", true) and "Auto buys from the top, each deal sized to how sure it is."
                or "Auto is off: nothing is bought."))
        local rows, keys = {}, {}
        for i = 1, #deals do
            local d = deals[i]
            local kind = d.mode == "vendor" and { text = "vendor", color = "success" }
                or (d.gear and { text = "gear", color = "warning" } or { text = "resell", color = "accent" })
            rows[i] = {
                item_cell(d.item_id, K.name(d)),
                d.big and { text = "BIG", color = "success" } or (d.need and { text = "big*", color = "accent" } or ""),
                kind,
                tostring(d.units), money_cell(d.max_unit), money_cell(d.cost), money_cell(d.resale),
                { text = U.money(d.expected or d.profit), color = "success" },
                { text = sure_text(d.confidence), color = (d.confidence or 0) >= 0.99 and "success" or "warning" },
                string.format("%.0f%%", (d.rate or 0) * 100),
                U.rate(d.per_day),
            }
            keys[i] = d.key or d.item_id
        end
        local pick = keyed_table(ui, "deals", DEAL_COLUMNS, rows, keys, { h = 320 })
        local d = pick and K.get(pick)
        if d then
            local rec = d.gear and M.gear and M.gear.record(d.key) or D.item(d.item_id)
            small(ui, string.format("%s: planned against %s, market now %s, %s listed, sells %s; %s sure of a profit%s%s",
                K.name(d), U.money(d.reference), U.money(rec and rec.m), rec and tostring(rec.q or 0) or "?",
                U.rate(d.per_day), sure_text(d.confidence),
                d.checked and " (searched just now)" or " (from the last scan)",
                d.gear and ". Gear: Auto buys it, YOU post it (Gear tab)" or ""))
            -- The deposits its profit was planned after: one a post, k posts.
            small(ui, string.format("Expected +%s after the cut, %s of deposits and the chance it fails; earns %.0f%% a "
                .. "day on its %s for %s%s%s.", U.money(d.expected or 0),
                U.money(d.mode == "flip" and (d.fees or d.deposits or 0) or 0), (d.rate or 0) * 100,
                U.money(d.cost), d.days and string.format("%.1f day(s)", d.days) or "?",
                (d.posts or 1) > 1 and string.format(", judged over %d posts", d.posts) or "",
                d.big and "; BIG MONEY" or (d.need and string.format("; big money once %s is free", U.money(d.need)) or "")))
        end
    end

    -- --- Gear ---------------------------------------------------------------------------------
    --
    -- The user (2026-10-09): "lets identify weapon and gear that we can Flip
    -- for price like the rest but we will have to post it ourselfs".

    -- The roll has a column of its own: a long name cut short at the item's
    -- column would hide exactly the part that sets the price.
    local POST_COLUMNS = {
        { label = "Item", w = 0.21 }, { label = "Roll", w = 0.15 }, { label = "Qty", w = 0.05, align = "right" },
        { label = "Post at", w = 0.11, align = "right" }, { label = "Cheapest", w = 0.11, align = "right" },
        { label = "Deposit", w = 0.09, align = "right" }, { label = "If it sells", w = 0.11, align = "right" },
        { label = "Whose", w = 0.17 },
    }
    local GEAR_COLUMNS = {
        { label = "Item", w = 0.19 }, { label = "Roll", w = 0.14 }, { label = "Size", w = 0.05 },
        { label = "Buy at", w = 0.10, align = "right" }, { label = "Sell at", w = 0.10, align = "right" },
        { label = "Expected", w = 0.10, align = "right" }, { label = "Sure", w = 0.07, align = "right" },
        { label = "Sells", w = 0.08, align = "right" }, { label = "Listed", w = 0.07, align = "right" },
        { label = "Auto", w = 0.09 },
    }

    --- The roll part of a roll's name ("of the Monkey"); "-" for none.
    local function roll_text(id, name)
        local base = D.name(id)
        if not name or name == base then return { text = "-", color = "text_dim" } end
        if name:sub(1, #base) == base then
            local rest = name:sub(#base + 1):gsub("^%s+", "")
            if rest ~= "" then return { text = rest, color = "accent" } end
        end
        return { text = name, color = "accent" }
    end

    local function gear_tab(ui)
        local G = M.gear
        if not G then return end
        small(ui, "Weapons, armor and other single items (bags, recipes), priced by ROLL: \"of the Monkey\" apart "
            .. "from \"of the Owl\". Auto finds and buys gear deals by the same rules as everything else, but the game "
            .. "will not let it post a single item on Forever: YOU post them, at the buyout below, for 48 hours. "
            .. "The deposit comes back when it sells.")
        for _, line in ipairs(G.status()) do small(ui, line[1], line[2]) end

        ui:separator("Post these yourself")
        local bag = G.bag_list()
        local cut = M.policy.cut()
        local rows, keys = {}, {}
        for i = 1, #bag do
            local e = bag[i]
            local a = e.advice
            local if_sold = a.price and (P.net(a.price, cut) - (e.cost or 0)) * math.max(1, e.auto > 0 and e.auto or e.count)
            local whose
            if e.auto > 0 then
                whose = { text = string.format("Auto's (paid %s)", U.money(e.cost or 0)), color = "warning" }
            else
                whose = { text = e.known and "yours" or "yours (roll unread)", color = "text_dim" }
            end
            rows[i] = {
                item_cell(e.id), e.known and roll_text(e.id, e.name) or { text = "?", color = "warning" },
                tostring(e.count),
                a.price and { text = U.money(a.price), color = e.auto > 0 and "success" or "text" }
                    or { text = "hold", color = "text_dim" },
                money_cell(a.lowest), money_cell(a.deposit), if_sold and signed_cell(if_sold) or "-", whose,
            }
            keys[i] = e.vkey
        end
        if #rows == 0 then
            small(ui, "No gear in your bags.")
        else
            local pick = keyed_table(ui, "gear_bag", POST_COLUMNS, rows, keys, { h = 150 })
            for i = 1, #bag do
                local e = bag[i]
                if e.vkey == pick then
                    local a = e.advice
                    small(ui, string.format("%s: %s%s; usually %s%s; a vendor pays %s.", e.name,
                        a.price and ("post at " .. U.money(a.price) .. " buyout, 48 hours") or ("hold: " .. tostring(a.why)),
                        a.lowest and (", the cheapest other is " .. U.money(a.lowest)) or ", nobody else is selling it",
                        U.money(a.market), a.per_day and (", sells " .. U.rate(a.per_day)) or "", U.money(a.vendor)))
                    break
                end
            end
        end
        local waiting, list = G.waiting()
        local in_bags = 0
        for i = 1, #bag do in_bags = in_bags + bag[i].auto end
        if waiting > in_bags then
            local names = {}
            for i = 1, #list do names[#names + 1] = list[i].name end
            small(ui, string.format("Not in your bags yet: %d piece(s) Auto bought (%s) -- in the mailbox: collect them, "
                .. "then post them.", waiting - in_bags, table.concat(names, ", ")), "accent")
        end
        small(ui, "Auto buys at most two pieces ahead of you: once two wait to be posted it buys no more gear until you "
            .. "post them. Your posts of them are added to the ledger when your auctions are read.")

        ui:separator("Gear deals")
        local deals = {}
        for _, d in ipairs(K.list()) do if d.gear then deals[#deals + 1] = d end end
        local gear_ok, gear_why = G.can_buy()
        local drows, dkeys = {}, {}
        for i = 1, #deals do
            local d = deals[i]
            local rec = G.record(d.key)
            drows[i] = {
                item_cell(d.item_id), roll_text(d.item_id, K.name(d)),
                d.big and { text = "BIG", color = "success" } or (d.need and { text = "big*", color = "accent" } or ""),
                money_cell(d.max_unit), money_cell(d.resale),
                { text = U.money(d.expected or d.profit), color = "success" },
                { text = sure_text(d.confidence), color = (d.confidence or 0) >= 0.99 and "success" or "warning" },
                U.rate(d.per_day), rec and tostring(rec.q or 0) or "-",
                (X.active() and gear_ok) and { text = "buys it", color = "success" }
                    or { text = X.active() and "waits" or "Auto off", color = "text_dim" },
            }
            dkeys[i] = d.key
        end
        if #drows == 0 then
            small(ui, "No gear deal right now. A roll needs three scans and three sales seen before it is judged, "
                .. "the same as everything else.")
        else
            local pick = keyed_table(ui, "gear_deals", GEAR_COLUMNS, drows, dkeys, { h = 150 })
            local d = pick and K.get(pick)
            if d then
                small(ui, string.format("%s: buy %dx for %s, post at %s; expected %s after the cut, a 48-hour deposit "
                    .. "of %s and the chance it fails; %s sure%s.", K.name(d), d.units, U.money(d.cost),
                    U.money(d.resale), U.signed(d.expected or 0), U.money(d.deposits or 0), sure_text(d.confidence),
                    gear_ok and "" or (" -- Auto waits: " .. tostring(gear_why))))
            end
        end

        ui:separator("Cheap, but not sure enough")
        local near = G.near()
        if #near == 0 then
            small(ui, "Nothing cheap that Auto passed over.")
        else
            small(ui, string.format("Listed well under their usual price, but too few buyers seen to be %s sure: Auto "
                .. "does not buy these. Your call.", sure_text(M.policy.bar())))
            for i = 1, #near do
                local d = near[i]
                small(ui, string.format("%s: %s each, sells at %s; expected %s, %s sure", K.name(d), U.money(d.max_unit),
                    U.money(d.resale), U.signed(d.expected or 0), sure_text(d.confidence)), "text")
            end
        end
    end

    -- --- Sell --------------------------------------------------------------------------------

    local SELL_COLUMNS = {
        { label = "Item", w = 0.25 }, { label = "Qty", w = 0.06, align = "right" },
        { label = "Market", w = 0.11, align = "right" }, { label = "Cheapest", w = 0.11, align = "right" },
        { label = "Post at", w = 0.11, align = "right" }, { label = "Vendor", w = 0.10, align = "right" },
        { label = "Auto", w = 0.26 },
    }

    local function sell_tab(ui)
        local list = B.list()
        local all = M.cfg("auto_sell_all", false)
        local rows, keys = {}, {}
        for i = 1, #list do
            local a = list[i]
            local held = L.holding(a.id)
            local mine = held and held.qty > 0
            local advice
            if a.action == "post" then
                advice = (mine or all) and { text = "posts it", color = "success" }
                    or { text = "would post (yours: Auto leaves it)", color = "text_dim" }
            elseif a.action == "vendor" then
                advice = mine and { text = "sells to a vendor", color = "warning" }
                    or { text = "vendor" .. (a.why and (": " .. a.why) or ""), color = "text_dim" }
            elseif a.action == "hand" then
                advice = { text = "you post it (Gear tab)", color = mine and "warning" or "text_dim" }
            else
                advice = { text = "keeps: " .. tostring(a.why), color = "text_dim" }
            end
            rows[i] = {
                item_cell(a.id, a.name), tostring(a.count), money_cell(a.market), money_cell(a.lowest),
                a.price and { text = U.money(a.price), color = "success" } or "-", money_cell(a.vendor), advice,
            }
            keys[i] = a.id
        end
        local pick = keyed_table(ui, "bags", SELL_COLUMNS, rows, keys, { h = 320 })
        if pick then
            for i = 1, #list do
                local a = list[i]
                if a.id == pick then
                    small(ui, string.format("%s: %s%s%s", a.name or D.name(a.id), tostring(a.why or ""),
                        a.cost and ("; you paid " .. U.money(a.cost) .. " each") or "",
                        a.per_day and ("; sells " .. U.rate(a.per_day)) or ""))
                    break
                end
            end
        end
        small(ui, "Auto posts what it bought, 1c under the cheapest other seller, never under the vendor price or "
            .. "10% over what it paid, for 48 hours. Your own items are yours: Auto does not sell them. Gear and "
            .. "other single items only you can post on Forever: the Gear tab prices them by roll.")
    end

    -- --- Vendor ---------------------------------------------------------------------------

    local VENDOR_COLUMNS = {
        { label = "Item", w = 0.24 }, { label = "Qty", w = 0.06, align = "right" },
        { label = "Vendor pays", w = 0.13, align = "right" }, { label = "AH would bring", w = 0.14, align = "right" },
        { label = "You paid", w = 0.12, align = "right" }, { label = "Better", w = 0.18 },
        { label = "Vs paid", w = 0.13, align = "right" },
    }

    local function vendor_tab(ui)
        local v = B.vendor_list()
        small(ui, string.format("A vendor pays more for %d item(s) you carry: %s for them. Everything a vendor "
            .. "buys here: %s at a vendor; what the auction house would bring for it, after its cut and if it "
            .. "sells: %s.", v.vendor_best_n, U.money(v.vendor_best), U.money(v.vendor), U.money(v.ah)),
            v.vendor_best_n > 0 and "warning" or "text_dim")
        local rows, keys = {}, {}
        for i = 1, #v.rows do
            local r = v.rows[i]
            local better
            if r.best == "vendor" then
                if r.no_ah then better = { text = "vendor (" .. tostring(r.why) .. ")", color = "warning" }
                elseif not r.ah then better = { text = "vendor (no AH price)", color = "warning" }
                else better = { text = "vendor, +" .. U.money(r.vendor - r.ah), color = "warning" } end
            else
                better = { text = "AH, +" .. U.money(r.ah - r.vendor), color = "success" }
            end
            rows[i] = {
                item_cell(r.id, r.name), tostring(r.count),
                money_cell(r.vendor, r.best == "vendor" and "warning" or "text"),
                r.ah and money_cell(r.ah, r.best == "ah" and "success" or "text")
                    or { text = r.no_ah and "can't list" or "-", color = "text_dim" },
                money_cell(r.paid), better, r.gain and signed_cell(r.gain) or "-",
            }
            keys[i] = r.id
        end
        if #rows == 0 then
            small(ui, "Nothing in your bags that a vendor buys.")
        else
            local pick = keyed_table(ui, "vendor", VENDOR_COLUMNS, rows, keys, { h = 340 })
            if pick then
                for i = 1, #v.rows do
                    local r = v.rows[i]
                    if r.id == pick then
                        small(ui, string.format("%s x%d: a vendor pays %s each; the auction house %s%s.",
                            r.name or D.name(r.id), r.count, U.money(r.vendor / r.count),
                            r.ah and (U.money(r.ah / r.count) .. " each after its cut") or "has no price for it",
                            r.paid and ("; you paid " .. U.money(r.paid / r.count) .. " each") or ""))
                        break
                    end
                end
            end
        end
        small(ui, "Auto sells to a vendor only what it bought, when you open a merchant. What else to vendor is "
            .. "your call: this list says what each would bring.")
    end

    -- --- Auctions --------------------------------------------------------------------------

    local OWNED_COLUMNS = {
        { label = "Item", w = 0.26 }, { label = "Qty", w = 0.06, align = "right" },
        { label = "Your price", w = 0.13, align = "right" }, { label = "Cheapest", w = 0.13, align = "right" },
        { label = "If sold", w = 0.14, align = "right" }, { label = "Status", w = 0.15 }, { label = "Time", w = 0.13 },
    }
    local STATUS_TONE = { sold = "success", cheapest = "success", ["only seller"] = "success", undercut = "danger" }

    local function auctions_tab(ui)
        local list, at = T.owned()
        if not list then
            small(ui, A.is_open() and "Reading your auctions..."
                or "Your auctions are read when the auction house opens.")
            return
        end
        local rows, keys = {}, {}
        local undercut = 0
        for i = 1, #list do
            local a = list[i]
            -- Profit if it sells: after the cut, less what was paid (nothing
            -- for what was not bought here).
            local basis = L.cost_basis(a.item_id, a.var) or 0
            local if_sold = P.net(a.unit, M.policy.cut()) * a.qty - basis * a.qty
            rows[i] = {
                item_cell(a.item_id, a.name), tostring(a.qty), money_cell(a.unit), money_cell(a.lowest),
                signed_cell(if_sold), { text = a.status, color = STATUS_TONE[a.status] or "text" }, band_text(a.band),
            }
            keys[i] = a.auction_id
            if a.status == "undercut" then undercut = undercut + 1 end
        end
        small(ui, string.format("%d auction(s), read %s ago; %d undercut. %s Gear is compared with its own roll, and "
            .. "only you can repost it.", #list, U.ago(core.time() - at),
            undercut, X.active() and M.cfg("auto_repost", true)
                and "Auto cancels and reposts an undercut one it bought while that still makes a profit."
                or "Auto is off: undercut auctions are left as they are."))
        keyed_table(ui, "owned", OWNED_COLUMNS, rows, keys, { h = 320 })
    end

    -- --- Market -----------------------------------------------------------------------------

    --- Items for a market view, sorted, at most 250. Cached three seconds.
    function W.market_rows(view, filter)
        local cache_key = tostring(view) .. "\1" .. tostring(filter)
        local t = core.time()
        if market_cache and market_key == cache_key and t - market_at < 3 then return market_cache end
        local out = {}
        local needle = filter and filter ~= "" and filter:lower() or nil
        for k, rec in pairs(D.items()) do
            local id = tonumber(k)
            local name = D.name(id)
            if not needle or name:lower():find(needle, 1, true) then
                local r = { id = id, rec = rec, per_day = D.per_day(rec), trend = D.trend(rec), name = name }
                local keep
                if view == 1 then keep = (r.per_day or 0) > 0
                elseif view == 2 then keep = (rec.q or 0) > 0 and r.per_day == 0 and (rec.oa or 0) >= 6 * 3600
                elseif view == 3 then keep = rec.m ~= nil
                elseif view == 4 then keep = r.trend and r.trend < -0.1
                elseif view == 5 then keep = r.trend and r.trend > 0.1
                elseif view == 6 then keep = (rec.q or 0) > 0
                else keep = true end
                if keep then out[#out + 1] = r end
            end
        end
        local sorters = {
            function(a, b) return (a.per_day or 0) * (a.rec.m or 0) > (b.per_day or 0) * (b.rec.m or 0) end,
            function(a, b) return (a.rec.q or 0) * (a.rec.m or 0) > (b.rec.q or 0) * (b.rec.m or 0) end,
            function(a, b) return (a.rec.m or 0) > (b.rec.m or 0) end,
            function(a, b) return (a.trend or 0) < (b.trend or 0) end,
            function(a, b) return (a.trend or 0) > (b.trend or 0) end,
            function(a, b) return (a.rec.q or 0) > (b.rec.q or 0) end,
            function(a, b) return a.name < b.name end,
        }
        table.sort(out, sorters[view] or sorters[7])
        while #out > 250 do out[#out] = nil end
        market_cache, market_key, market_at = out, cache_key, t
        return out
    end

    local MARKET_COLUMNS = {
        { label = "Item", w = 0.28 }, { label = "Market", w = 0.12, align = "right" },
        { label = "Cheapest", w = 0.12, align = "right" }, { label = "Listed", w = 0.09, align = "right" },
        { label = "Sold", w = 0.10, align = "right" }, { label = "Trend", w = 0.09, align = "right" },
        { label = "Vendor", w = 0.10, align = "right" }, { label = "Seen", w = 0.10, align = "right" },
    }

    local function market_tab(ui)
        ui:row({ 0.5, 0.5 })
        local view = ui:dropdown("view", "Show", MARKET_VIEWS, 1)
        local filter = ui:text_input("filter", "Find", "", { placeholder = "item name" })
        ui:end_row()
        local list = W.market_rows(view, filter)
        local rows, keys = {}, {}
        local now = U.now()
        for i = 1, #list do
            local r = list[i]
            local rec = r.rec
            rows[i] = {
                item_cell(r.id, r.name), money_cell(rec.m), money_cell(rec.n), tostring(rec.q or 0),
                U.rate(r.per_day),
                r.trend and { text = U.pct(r.trend), color = r.trend >= 0 and "success" or "danger" } or "-",
                money_cell(D.vendor(r.id)), rec.t and U.ago(now - rec.t) or "-",
            }
            keys[i] = r.id
        end
        local pick = keyed_table(ui, "market", MARKET_COLUMNS, rows, keys, { h = 300 })
        if pick then
            local rec = D.item(pick)
            if rec then
                small(ui, string.format("%s: usual %s, %d seller(s), seen in %d scan(s); about %s sold; %s",
                    D.name(pick), U.money(rec.h), rec.s or 0, rec.c or 0,
                    string.format("%.0f", rec.sa or 0), D.per_day(rec) and ("selling " .. U.rate(D.per_day(rec)))
                        or "not watched long enough to say how fast it sells"))
            end
        end
        small(ui, "Sold figures are estimates: listings that left between two scans with too much time left to "
            .. "have expired. A cancelled listing counts as a sale.")
    end

    -- --- Ledger -------------------------------------------------------------------------------

    local LEDGER_COLUMNS = {
        { label = "Item", w = 0.26 }, { label = "Bought", w = 0.16, align = "right" },
        { label = "Sold", w = 0.16, align = "right" }, { label = "Fees", w = 0.10, align = "right" },
        { label = "Expected", w = 0.15, align = "right" }, { label = "Actual", w = 0.17, align = "right" },
    }
    local LOG_COLUMNS = {
        { label = "When", w = 0.15 }, { label = "What", w = 0.12 }, { label = "Item", w = 0.24 },
        { label = "Qty", w = 0.06, align = "right" }, { label = "Each", w = 0.12, align = "right" },
        { label = "Money", w = 0.13, align = "right" }, { label = "Notes", w = 0.18 },
    }
    local LOG_FILTERS = { "Everything", "Buys", "Sells", "Posts and cancels", "Fees" }
    local LOG_KINDS = { nil, { buy = true }, { sell = true }, { post = true, cancel = true, returned = true, kept = true },
        { fee = true } }
    local LOG_SHOWN = 300

    local DAY_COLUMNS = {
        { label = "Day", w = 0.20 }, { label = "Start", w = 0.20, align = "right" },
        { label = "End", w = 0.20, align = "right" }, { label = "Change", w = 0.20, align = "right" },
        { label = "On offer", w = 0.20, align = "right" },
    }

    local function day_label(day)
        local today = U.day()
        if day == today then return "today" end
        if day == today - 1 then return "yesterday" end
        return (today - day) .. " days ago"
    end

    local function clock(t)
        local s = math.floor(t % 86400)
        return string.format("%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60)
    end

    --- One journal row as a Trade log line.
    local function log_row(r)
        local qty = r.qty or 0
        local when = day_label(U.day(r.t or 0)) .. " " .. clock(r.t or 0)
        -- A roll of gear by its own name ("Bandit Cloak of the Monkey").
        local vname = r.vname or ((r.var and r.var ~= "") and (r.name or (r.kind == "sell" and r.note)) or nil)
        local item = r.id and item_cell(r.id, vname) or (r.name or r.note or "-")
        local each = qty > 0 and (r.copper or 0) > 0 and U.money((r.copper or 0) / qty) or "-"
        local k = r.kind
        if k == "buy" then
            return { when, { text = "Bought", color = "warning" }, item, tostring(qty), each,
                money_cell(-(r.copper or 0), "danger"),
                r.expected and string.format("exp. %s, %s sure", U.signed(r.expected), sure_text(r.conf)) or (r.note or "") }
        elseif k == "sell" then
            local mine = r.mine
            if mine == nil then mine = ((r.basis or 0) > 0 or r.expected ~= nil) and qty or 0 end
            local note = mine > 0 and ("made " .. U.signed((r.copper or 0) * math.min(1, mine / math.max(1, qty))
                - (r.basis or 0))) or "your own item"
            if r.note == "vendor" then note = note .. " (vendor)" end
            return { when, { text = "Sold", color = "success" }, item, tostring(qty), each,
                money_cell(r.copper or 0, "success"), note }
        elseif k == "fee" then
            return { when, { text = r.note == "cancel" and "Cancel fee" or "Deposit", color = "text_dim" }, item, "-",
                "-", money_cell(-(r.copper or 0), "danger"), r.hours and (r.hours .. " h auction") or "" }
        elseif k == "post" then
            return { when, { text = r.by == "you" and "You posted" or "Posted", color = "accent" }, item, tostring(qty),
                r.unit and U.money(r.unit) or "-", { text = "-", color = "text_dim" },
                string.format("%s h, deposit %s%s", tostring(r.hours or "?"), U.money(r.deposit or 0),
                    r.est and " (est.)" or "") }
        elseif k == "cancel" then
            return { when, { text = "Cancelled", color = "text_dim" }, item, tostring(qty), "-",
                { text = "-", color = "text_dim" }, "to repost" }
        elseif k == "returned" then
            return { when, { text = "Mail back", color = "text_dim" }, item, tostring(qty), "-",
                { text = "-", color = "text_dim" }, r.note or "" }
        elseif k == "kept" then
            return { when, { text = "Yours now", color = "text_dim" }, item, tostring(qty), "-",
                { text = "-", color = "text_dim" }, "cost " .. U.money(r.basis or 0) .. ": not sold through Auto" }
        end
        return { when, tostring(k), item, tostring(qty), each, money_cell(r.copper), r.note or "" }
    end

    local function all_time(ui)
        local t = L.totals()
        ui:separator("All time" .. (t.first and (" (since " .. day_label(U.day(t.first)) .. ")") or ""))
        ui:row({ 0.5, 0.5 })
        ui:key_value("Invested (bought)", U.money(t.invested))
        ui:key_value("Returned (sold)", U.money(t.returned))
        ui:end_row()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Cost of what sold", U.money(t.basis))
        ui:key_value("Fees (deposits, cancels)", U.money(t.fees))
        ui:end_row()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Profit made", U.signed(t.profit))
        ui:key_value("Still in stock (cost)", U.money(t.in_stock))
        ui:end_row()
        small(ui, string.format("%d buy(s) of %d unit(s); %d sale(s) of %d unit(s) (%s at the auction house, %s at "
            .. "vendors); %d post(s), %d cancel(s). Cash so far: %s (returned less invested and fees; the stock "
            .. "still held is the rest).%s", t.buys, t.units_bought, t.sells, t.units_sold, U.money(t.returned_ah),
            U.money(t.returned_vendor), t.posts, t.cancels, U.signed(t.cash),
            (t.own_sales > 0 and (" Your own items sold: " .. U.money(t.own_sales) .. ", not counted above.") or "")
            .. ((t.kept or 0) > 0 and string.format(" Gear Auto bought that became yours unsold: %d piece(s), cost %s.",
                t.kept_n or 0, U.money(t.kept)) or "")))
    end

    local function trade_log(ui)
        ui:separator("Trade log")
        local filter = ui:dropdown("log_filter", "Show", LOG_FILTERS, 1)
        local want = LOG_KINDS[filter]
        local all = L.trades()
        local rows, keys = {}, {}
        for i = #all, 1, -1 do
            local r = all[i]
            if not want or want[r.kind] then
                rows[#rows + 1] = log_row(r)
                keys[#keys + 1] = tostring(r.t) .. ":" .. tostring(i)
                if #rows >= LOG_SHOWN then break end
            end
        end
        if #rows == 0 then
            small(ui, "Nothing yet.")
        else
            keyed_table(ui, "log", LOG_COLUMNS, rows, keys, { h = 240 })
        end
        small(ui, string.format("Every trade is kept for good in scripts_data/jcore/jambix.market.journal.json "
            .. "(%d row(s)); the newest %d are shown.", #all, LOG_SHOWN))
    end

    local function ledger_tab(ui)
        all_time(ui)
        ui:separator("By period")
        local period = ui:dropdown("period", "Period", LEDGER_PERIODS, 2)
        local s = L.summary(PERIOD_DAYS[period])
        ui:row({ 0.5, 0.5 })
        ui:key_value("Spent buying", U.money(s.bought))
        ui:key_value("Sales of stock", U.money(s.sold))
        ui:end_row()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Cost of what sold", U.money(s.basis))
        ui:key_value("Deposits and cancels", U.money(s.fees))
        ui:end_row()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Profit (actual)", U.signed(s.profit))
        ui:key_value("Stock still held (cost)", U.money(s.stock_cost))
        ui:end_row()
        ui:row({ 0.5, 0.5 })
        ui:key_value("Expected when bought", U.signed(s.expected_buys))
        ui:key_value("Stock expected to make", U.signed(s.stock_expected))
        ui:end_row()
        if s.flips > 0 then
            local share = s.flips_expected ~= 0
                and (math.floor(s.flips_actual / s.flips_expected * 100 + 0.5) .. "% of what was expected") or "-"
            small(ui, string.format("Of %d sale(s) of stock bought here: expected %s, made %s before fees (%s).",
                s.flips, U.signed(s.flips_expected), U.signed(s.flips_actual), share))
        end
        small(ui, "Success rate: " .. success_line(s) .. ".", s.success and (s.success >= 0.95 and "success"
            or "warning") or "text_dim")

        local rows, keys = {}, {}
        local items = {}
        for k, it in pairs(s.items) do items[#items + 1] = { key = k, it = it } end
        table.sort(items, function(a, b) return a.it.profit > b.it.profit end)
        for i = 1, #items do
            local it = items[i].it
            rows[i] = {
                it.id and item_cell(it.id, it.name) or items[i].key,
                it.bought_qty > 0 and (it.bought_qty .. " for " .. U.money(it.bought)) or "-",
                it.sold_qty > 0 and (it.sold_qty .. " for " .. U.money(it.sold)) or "-",
                money_cell(it.fees > 0 and it.fees or nil),
                it.expected ~= 0 and signed_cell(it.expected) or "-", signed_cell(it.profit),
            }
            keys[i] = items[i].key
        end
        keyed_table(ui, "ledger", LEDGER_COLUMNS, rows, keys, { h = 170 })

        trade_log(ui)

        ui:separator("Gold by day")
        local days = L.days(14)
        local drows, dkeys = {}, {}
        for i = 1, #days do
            local d = days[i]
            drows[i] = { day_label(d.day), U.money(d.open), U.money(d.close), signed_cell(d.change),
                money_cell(d.potential) }
            dkeys[i] = d.day
        end
        keyed_table(ui, "days", DAY_COLUMNS, drows, dkeys, { h = 130 })
        small(ui, "\"On offer\": the most profit the deal list held at any one look that day, bought or not.")
    end

    -- --- the window ------------------------------------------------------------------------------

    local BODIES = { overview, deals_tab, gear_tab, sell_tab, vendor_tab, auctions_tab, market_tab, ledger_tab }

    -- A fixed, resizable size (the user, 2026-10-07: "Im having trouble moving
    -- the UI freely"): grown to fit its content, the window was taller than
    -- the screen, so JCore pinned its bottom to the screen's and its height
    -- changed under the cursor as it was dragged. Now it keeps the size you
    -- give it (the grip at its bottom-right corner) and scrolls inside; drag
    -- it by its title bar.
    local handle = M.ctx.ui:window("main", {
        title = "Jambix Market", anchor = "center", x = 0, y = 0, w = 680, h = 640,
        resizable = true, min_w = 480, min_h = 260,
        collapsible = true, closable = true, visible = false,
    }, function(ui)
        header(ui)
        local tab = ui:tabs("tab", TABS, 1)
        local body = BODIES[tab] or overview
        local ok, err = pcall(body, ui)
        if not ok then
            small(ui, "This tab hit an error: " .. tostring(err), "danger")
            M.log.fmt("error", "window tab %d raised: %s", tab, tostring(err))
        end
    end)

    local opened_by_ah = false

    function W.toggle() handle.toggle() end
    function W.show() handle.show() end
    function W.hide() handle.hide() end
    function W.is_visible() return handle.is_visible() end
    function W.set_tab(i) handle.set_value("tab", i) end
    function W.set_value(id, v) handle.set_value(id, v) end

    M.ctx.on("jambix.market.ah_open", function()
        if M.cfg("enabled", true) and M.cfg("open_with_ah", true) and not handle.is_visible() then
            handle.show()
            opened_by_ah = true
        end
    end)
    M.ctx.on("jambix.market.ah_closed", function()
        -- Not while a mail run walks off: the window shows how it goes, and
        -- the auction house opening again at the end finds it open.
        if M.errands and M.errands.running() then return end
        if opened_by_ah and M.cfg("close_with_ah", true) then handle.hide() end
        opened_by_ah = false
    end)

    return W
end

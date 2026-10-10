-- Jambix Market / db -- what every item costs, and how fast it moves.
--
-- One record per item id seen on the auction house, saved per realm in
-- scripts_data/jcore/jambix.market.<realm>.json:
--
--   m   market value at the last full scan (pricing.market_value)
--   n   lowest buyout per item at the last look (scan or search)
--   q   units listed at the last scan, l listings, s sellers
--   h   historical value: the market value averaged with a 3-day half-life
--   sa  units estimated sold, oa seconds watched (both decaying, 3-day
--       half-life); sold per day = sa / oa * 86400
--   ev  purchases seen (one buyer taking 53 is one), eu their units, eo
--       seconds watched, ei scans that saw a sale -- the same decay, kept
--       from 1.0.0's live fix on; resales are judged on these alone
--   un  units that left and might have expired
--   t   last scan that saw it listed, f first seen, c scans that saw it
--   k   "commodity" or "item" once a search has said, lv item level
--   d   one row a day for 14 days: { day, market, qty, lowest, sold, scans }
--
-- The full scan before the last one is kept too (the .snap file), in a
-- compact text form, because the sales estimate is the difference between
-- two scans and a reload between them must not lose it. A single item's
-- listing (gear) keeps its roll there too: gear.lua prices gear by roll.
--
-- Item names, quality and vendor price come from the client (info{}), are
-- asked for at most fifteen a tick, and are kept with the prices.
--
-- THE PLUGIN'S OWN BUYING IS NOT DEMAND. A listing Auto bought leaves the
-- auction house with time to spare and reads, scan to scan, exactly like a
-- sale (the user's first live sessions, 2026-10-07: 53 of the 60 Rockscale
-- Cod "sold" were Auto's own purchase). Every fold takes off what the
-- plugin itself removed since the last scan: its purchases, from the
-- ledger (which a reload does not lose), and its cancels (own{}, saved
-- here). Sales folded in before that (meta.own_v unset) are repaired once.

return function(M)
    local ctx, U, P = M.ctx, M.util, M.pricing

    local D = {}

    local PRICE_HALF_LIFE = 3 * 86400
    local SALES_HALF_LIFE = 3 * 86400
    local MAX_COMPARE = 6 * 3600      -- scans further apart than this are not compared
    local MIN_COMPARE = 60
    local MIN_WATCHED = 1800          -- a sales rate needs half an hour of comparisons
    local HISTORY_DAYS = 14

    local data = { v = 1, items = {}, info = {}, meta = { own_v = 1 }, own = {} }
    local prev = nil                  -- { at, items = { [id] = listings[] } }
    local file, snap_file = nil, nil
    local loaded = false
    local dirty = false

    local key = U.key

    -- --- files ----------------------------------------------------------------

    -- Sales folded in before the plugin took its own purchases off: once per
    -- file, every purchase the ledger holds that a later scan saw leave comes
    -- off the units sold, as far as there are any. (Purchases were never
    -- counted as purchases-seen -- ev -- so those need nothing.)
    local function repair_own_purchases()
        if data.meta.own_v then return end
        data.meta.own_v = 1
        dirty = true
        local last = tonumber(data.meta.last_scan)
        if not last or not M.ledger then return end
        local trades = M.ledger.trades()
        local fixed = 0
        for i = 1, #trades do
            local tr = trades[i]
            local t = tonumber(tr.t)
            local rec = tr.kind == "buy" and tr.id and data.items[key(tr.id)]
            if rec and t and t <= last and t >= (rec.f or math.huge) and (tr.qty or 0) > 0 and (rec.sa or 0) > 0 then
                rec.sa = math.max(0, rec.sa - tr.qty * P.decay(last - t, SALES_HALF_LIFE))
                local day = U.day(t)
                for j = 1, #(rec.d or {}) do
                    local row = rec.d[j]
                    if row[1] >= day and (row[5] or 0) > 0 then
                        row[5] = math.max(0, row[5] - tr.qty)
                        break
                    end
                end
                fixed = fixed + 1
            end
        end
        if fixed > 0 then
            M.activity(string.format("Price history: %d of Auto's own purchase(s) taken off the sales they were "
                .. "counted as", fixed))
        end
    end

    -- A listing of a single item (gear) carries its roll (var, util.link_variant)
    -- as a fifth field: "0" for no roll, the roll otherwise, nothing when its
    -- link was not read. A file from before 1.2.0 has four fields: no rolls.
    local function encode_snapshot(snap)
        local items = {}
        for id, listings in pairs(snap.items) do
            local parts = {}
            for i = 1, #listings do
                local l = listings[i]
                local owner = tostring(l.owner or ""):gsub("[,;]", "")
                -- %.0f, not %d: a copper figure past 2^31 is a float on some Luas.
                local text = string.format("%.0f,%.0f,%.0f,%s", l.unit, l.qty, l.band or 0, owner)
                if l.var ~= nil then text = text .. "," .. (l.var == "" and "0" or l.var) end
                parts[i] = text
            end
            items[key(id)] = table.concat(parts, ";")
        end
        return { at = snap.at, items = items }
    end

    local function decode_snapshot(raw)
        if type(raw) ~= "table" or type(raw.items) ~= "table" or not tonumber(raw.at) then return nil end
        local items = {}
        for k, text in pairs(raw.items) do
            local id = tonumber(k)
            if id and type(text) == "string" then
                local listings = {}
                for one in text:gmatch("[^;]+") do
                    local unit, qty, band, owner, var = one:match("^(%d+),(%d+),(%d+),([^,]*),?(.*)$")
                    if unit then
                        local l = { unit = tonumber(unit), qty = tonumber(qty), band = tonumber(band), owner = owner }
                        if var == "0" then l.var = "" elseif var ~= "" then l.var = var end
                        listings[#listings + 1] = l
                    end
                end
                items[id] = listings
            end
        end
        return { at = tonumber(raw.at), items = items }
    end

    --- Opens this realm's files. Called once the realm can be read.
    function D.load()
        if loaded then return end
        loaded = true
        local realm = ""
        pcall(function() realm = ctx.world.realm() or "" end)
        local slug = ctx.util.slug(realm ~= "" and realm or "default")
        file = "jcore/jambix.market." .. slug .. ".json"
        snap_file = "jcore/jambix.market." .. slug .. ".snap.json"
        local raw = ctx.storage.read_json(file)
        if type(raw) == "table" and type(raw.items) == "table" then
            data = raw
            data.info = type(data.info) == "table" and data.info or {}
            data.meta = type(data.meta) == "table" and data.meta or {}
            -- A fingerprint from before the value was kept in silver: convert it.
            local fp = data.meta.fp
            if type(fp) == "table" and fp.unit ~= "s" and tonumber(fp.value) then
                fp.value, fp.unit = math.floor(fp.value / 100 + 0.5), "s"
            end
        end
        data.own = type(data.own) == "table" and data.own or {}
        repair_own_purchases()
        prev = decode_snapshot(ctx.storage.read_json(snap_file))
        local n = 0
        for _ in pairs(data.items) do n = n + 1 end
        M.debug("db: %d item(s) from %s; last scan %s", n, file,
            prev and (U.ago(U.now() - prev.at) .. " ago") or "none")
    end

    function D.save(with_snapshot)
        if not loaded then return end
        if dirty then
            ctx.storage.write_json(file, data, false)
            dirty = false
        end
        if with_snapshot and prev then
            ctx.storage.write_json(snap_file, encode_snapshot(prev), false)
        end
    end

    function D.touch() dirty = true end
    function D.ready() return loaded end

    -- Saved a minute after anything changed (the info pump changes it a
    -- little at a time), and at once after a scan.
    ctx.every(60, function() D.save(false) end)

    -- --- reading ------------------------------------------------------------------

    function D.item(id) return data.items[key(id)] end
    function D.items() return data.items end
    function D.meta() return data.meta end
    function D.previous() return prev end

    --- Units sold per day (estimated), or nil until it has been watched long
    --- enough to say.
    function D.per_day(rec)
        if not rec then return nil end
        if (rec.eo or 0) >= MIN_WATCHED then return (rec.eu or 0) / rec.eo * 86400 end
        if not rec.oa or rec.oa < MIN_WATCHED then return nil end
        return (rec.sa or 0) / rec.oa * 86400
    end

    --- How the market value now compares with the item's own past: the
    --- average of the earlier days on record, else the historical value.
    function D.trend(rec)
        if not rec or not rec.m then return nil end
        local d = rec.d
        local today = U.day()
        local sum, n = 0, 0
        if type(d) == "table" then
            for i = 1, #d do
                local row = d[i]
                if row[1] < today and row[1] >= today - 7 and (row[2] or 0) > 0 then
                    sum, n = sum + row[2], n + 1
                end
            end
        end
        local base = n >= 2 and (sum / n) or rec.h
        if not base or base <= 0 or (n < 2 and (rec.c or 0) < 3) then return nil end
        return rec.m / base - 1
    end

    --- The price to post against when nobody else is selling: the historical
    --- value once three scans have formed it, else this scan's market value.
    function D.reference(rec)
        if not rec then return nil end
        if (rec.c or 0) >= 3 and rec.h then return rec.h end
        return rec.m
    end

    -- A resale is only judged on an item seen in three scans over at least an
    -- hour of comparisons: one or two looks say nothing about how it moves.
    local MATURE_SCANS = 3
    local MATURE_WATCHED = 3600
    -- And it must be SEEN SELLING to other players: three purchases or more,
    -- in two scans or more (2.5 and 1.5 allow for the decay of a few hours).
    -- One buyer once proves nothing.
    local MATURE_SALES = 2.5
    local MATURE_SALE_SCANS = 1.5

    --- What a resale of this item is judged on (pricing.plan_flip and
    --- flip_confidence):
    ---   usual      the usual price, once three scans have formed it
    ---   median     the median market value of recent days (two days or more)
    ---   market     this scan's market value, cheap listings and all
    ---   reference  the lowest of those three, for showing
    ---   cv         how much its price moves in a day, from its daily history
    ---   per_day    estimated units sold a day (nil until watched long enough)
    ---   per_day_low  the cautious rate: the 95% lower bound of PURCHASES a
    ---              day, times the units a purchase takes (lot)
    ---   lot        units a purchase takes on average (1 or more)
    ---   sales      purchases seen (decayed)
    ---   mature     seen often enough, and seen selling, to judge at all
    function D.risk(rec)
        if not rec then return nil end
        local today = U.day()
        local values = {}
        if type(rec.d) == "table" then
            for i = 1, #rec.d do
                local row = rec.d[i]
                if row[1] >= today - 7 and (row[7] or 0) > 0 and (row[2] or 0) > 0 then
                    values[#values + 1] = row[2]
                end
            end
        end
        local median = nil
        if #values >= 2 then
            local s = {}
            for i = 1, #values do s[i] = values[i] end
            table.sort(s)
            local n = #s
            if n % 2 == 1 then median = s[(n + 1) / 2] else median = (s[n / 2] + s[n / 2 + 1]) / 2 end
        end
        local usual = ((rec.c or 0) >= MATURE_SCANS) and rec.h or nil
        local sales, watched = rec.ev or 0, rec.eo or 0
        local lot = sales > 0 and math.max(1, (rec.eu or 0) / sales) or 1
        return {
            usual = usual, median = median, market = rec.m,
            reference = P.safe_reference(usual, median, rec.m),
            cv = P.volatility(values),
            trend = P.trend(values),
            per_day = watched >= MIN_WATCHED and (rec.eu or 0) / watched * 86400 or nil,
            -- The 95% lower bound of how many PURCHASES a day, from how many
            -- were seen over how long, in units: few purchases seen, little
            -- believed, however many units they took.
            per_day_low = P.rate_lower(sales, watched, 1.645) * lot,
            lot = lot,
            sales = sales,
            mature = (rec.c or 0) >= MATURE_SCANS and watched >= MATURE_WATCHED and sales >= MATURE_SALES
                and (rec.ei or 0) >= MATURE_SALE_SCANS,
            days = #values,
        }
    end

    -- --- item info ----------------------------------------------------------------

    local wanted, asked = {}, {}
    local id_by_name = nil

    function D.info(id)
        local i = data.info[key(id)]
        if not i then wanted[id] = true end
        return i
    end

    function D.name(id)
        local i = data.info[key(id)]
        return (i and i.n) or ("item " .. tostring(id))
    end

    function D.quality(id)
        local i = data.info[key(id)]
        return i and i.q
    end

    function D.vendor(id)
        local i = data.info[key(id)]
        return i and i.v or nil
    end

    --- Item id for a name, from what the info cache holds (for mail subjects).
    function D.id_by_name(name)
        if not id_by_name then
            id_by_name = {}
            for k, i in pairs(data.info) do
                if i.n then id_by_name[i.n] = tonumber(k) end
            end
        end
        return id_by_name[name]
    end

    local function remember_info(id, fields)
        local k = key(id)
        local i = data.info[k] or {}
        for f, v in pairs(fields) do
            if v ~= nil and v ~= "" then i[f] = v end
        end
        data.info[k] = i
        if i.n and id_by_name then id_by_name[i.n] = id end
        dirty = true
        return i
    end
    D.remember_info = remember_info

    local function ask_info(id)
        local info = U.try(core.quests and core.quests.get_item_info, id)
        if type(info) ~= "table" or type(info.name) ~= "string" or info.name == "" then
            info = M.ah.call("get_item_info", id)
        end
        if type(info) ~= "table" or type(info.name) ~= "string" or info.name == "" then return false end
        local stack = tonumber(info.stack_count)
        remember_info(id, {
            n = info.name, q = tonumber(info.quality), v = tonumber(info.sell_price) or 0,
            s = stack, b = tonumber(info.bind_type), c = tonumber(info.class_id),
            il = tonumber(info.item_level), ok = true,
        })
        return true
    end

    -- Fifteen a tick, each id tried again thirty seconds after an empty
    -- answer (the client loads item data on first ask), five times at most.
    ctx.tick(function()
        local t = core.time()
        local n = 0
        for id in pairs(wanted) do
            local a = asked[id]
            if not a or (t - a.at >= 30 and a.n < 5) then
                if ask_info(id) then
                    wanted[id] = nil
                    asked[id] = nil
                else
                    asked[id] = { at = t, n = (a and a.n or 0) + 1 }
                end
                n = n + 1
                if n >= 15 then break end
            elseif a.n >= 5 then
                wanted[id] = nil
            end
        end
    end, { interval = 0.1, deferrable = true })

    -- --- writing: a full scan -----------------------------------------------------------

    --- Units the plugin took off the auction house by cancelling its own
    --- auctions (its purchases are read from the ledger). Saved at once: a
    --- reload before the next scan must not turn them into sales.
    function D.note_own_removal(item_id, qty)
        item_id, qty = tonumber(item_id), tonumber(qty)
        if not item_id or not qty or qty <= 0 then return end
        data.own = type(data.own) == "table" and data.own or {}
        data.own[#data.own + 1] = { id = item_id, qty = qty, t = U.now() }
        dirty = true
        D.save(false)
    end

    --- What the plugin itself removed of each item between two scans.
    local function own_removed(from, to)
        local own = {}
        if M.ledger then
            local trades = M.ledger.trades()
            for i = #trades, 1, -1 do
                local tr = trades[i]
                local t = tonumber(tr.t) or 0
                if t <= from then break end       -- the ledger is in time order
                local id = tonumber(tr.id)
                if tr.kind == "buy" and id and t <= to then own[id] = (own[id] or 0) + (tr.qty or 0) end
            end
        end
        for _, e in ipairs(data.own or {}) do
            if e.t > from and e.t <= to then own[e.id] = (own[e.id] or 0) + e.qty end
        end
        return own
    end

    local function maybe_yield(n)
        if n % 150 ~= 0 then return end
        local co, main = coroutine.running()
        if co and not main then coroutine.yield() end
    end

    --- Today's row: { day, market, qty, lowest, sold, scans, market scans }.
    --- Zeros, never nils, for "none": the rows are JSON arrays, which cannot
    --- hold a hole. `keep` days are kept (14 when not given; gear.lua keeps 7).
    local function add_day(rec, now, market, qty, lowest, sold, keep)
        local day = U.day(now)
        rec.d = type(rec.d) == "table" and rec.d or {}
        local d = rec.d
        local row = d[#d]
        if not row or row[1] ~= day or #row < 7 then
            row = { day, 0, 0, 0, 0, 0, 0 }
            d[#d + 1] = row
            while #d > (keep or HISTORY_DAYS) do table.remove(d, 1) end
        end
        row[6] = row[6] + 1
        row[3] = row[3] + (qty - row[3]) / row[6]
        if market then
            row[7] = row[7] + 1
            row[2] = row[2] + (market - row[2]) / row[7]
        end
        if lowest and (row[4] == 0 or lowest < row[4]) then row[4] = lowest end
        row[5] = row[5] + (sold or 0)
    end
    D.add_day = add_day

    --- Folds one full scan into the records. May yield (run it in a
    --- coroutine for a big auction house); runs straight through otherwise.
    ---@param snap table { at, items = { [id] = listings[] }, meta = { [id] = { name, quality, level } } }
    ---@return table summary { items, sold, compared }
    function D.apply_scan(snap)
        local now = snap.at
        local elapsed = prev and (now - prev.at) or nil
        local compare = elapsed and elapsed >= MIN_COMPARE and elapsed <= MAX_COMPARE
        local summary = { items = 0, sold = 0, compared = compare and true or false, elapsed = elapsed }
        local n = 0
        local own = prev and own_removed(prev.at, now) or {}

        local function credit(rec, id, before, after)
            local sold, unclear, _, _, sales = P.sales_between(before, after, elapsed)
            sold, sales = P.sales_without(sold, sales, own[id])
            local keep = P.decay(elapsed, SALES_HALF_LIFE)
            rec.sa = (rec.sa or 0) * keep + sold
            rec.oa = (rec.oa or 0) * keep + elapsed
            rec.un = (rec.un or 0) * keep + unclear
            rec.ev = (rec.ev or 0) * keep + sales
            rec.eu = (rec.eu or 0) * keep + sold
            rec.eo = (rec.eo or 0) * keep + elapsed
            rec.ei = (rec.ei or 0) * keep + (sales > 0 and 1 or 0)
            summary.sold = summary.sold + sold
            return sold
        end

        for id, listings in pairs(snap.items) do
            local k = key(id)
            local rec = data.items[k]
            if not rec then
                rec = { f = now, c = 0 }
                data.items[k] = rec
            end
            local market, lowest, qty = P.market_value(listings)
            local sellers, seen = 0, {}
            for i = 1, #listings do
                local o = listings[i].owner or ""
                if not seen[o] then seen[o] = true; sellers = sellers + 1 end
            end
            local sold = 0
            if compare then sold = credit(rec, id, prev.items[id] or {}, listings) end
            if market then
                rec.h = P.blend(rec.h, market, now - (rec.ht or now), PRICE_HALF_LIFE)
                rec.ht = now
                rec.m = market
            end
            rec.n, rec.q, rec.l, rec.s = lowest, qty, #listings, sellers
            rec.t, rec.c = now, (rec.c or 0) + 1
            local meta = snap.meta and snap.meta[id]
            if meta then
                if meta.level and meta.level > 0 then rec.lv = meta.level end
                if meta.name and meta.name ~= "" and not (data.info[k] and data.info[k].ok) then
                    remember_info(id, { n = meta.name, q = meta.quality })
                end
            end
            if not (data.info[k] and data.info[k].ok) then wanted[id] = true end
            add_day(rec, now, market, qty, lowest, sold)
            summary.items = summary.items + 1
            n = n + 1
            maybe_yield(n)
        end

        -- Listed last time, gone now: sold out, expired or cancelled.
        if prev then
            for id, before in pairs(prev.items) do
                if not snap.items[id] then
                    local rec = data.items[key(id)]
                    if rec then
                        local sold = 0
                        if compare then sold = credit(rec, id, before, {}) end
                        rec.q, rec.l, rec.s, rec.n = 0, 0, 0, nil
                        add_day(rec, now, nil, 0, nil, sold)
                    end
                    n = n + 1
                    maybe_yield(n)
                end
            end
        end

        local later = {}
        for _, e in ipairs(data.own or {}) do
            if e.t > now then later[#later + 1] = e end
        end
        data.own = later
        data.meta.own_v = 1
        -- With what the scan read of single items' links (gear.lua folds the
        -- rolls from it): their names, and how many links answered.
        prev = { at = now, items = snap.items, vnames = snap.vnames, singles = snap.singles, linked = snap.linked }
        data.meta.last_scan = now
        data.meta.scans = (data.meta.scans or 0) + 1
        data.meta.listed = summary.items
        data.meta.rows = snap.rows
        data.meta.fp = D.fingerprint(snap)
        dirty = true
        return summary
    end

    --- What a full scan held, in three numbers: auctions, units, and their
    --- value. A live auction house never gives the same three twice in five
    --- minutes; the scanner uses it to spot the server handing back the last
    --- list (scanner.lua, "a throttled full scan is not a scan").
    function D.fingerprint(snap)
        local units, value = 0, 0
        for _, listings in pairs(snap.items) do
            for i = 1, #listings do
                local l = listings[i]
                units = units + (l.qty or 0)
                value = value + (l.unit or 0) * (l.qty or 0)
            end
        end
        -- The value in silver: in copper a live auction house passes 2^31
        -- (the user's: 2,171,456,680), which a 32-bit Lua cannot print as %d.
        return { rows = snap.rows or 0, units = units, value = math.floor(value / 100 + 0.5), unit = "s" }
    end

    -- --- writing: one search -----------------------------------------------------------

    --- A search is the whole of one item's listings right now: it moves the
    --- lowest price, the market value and the usual price, and says whether
    --- the item is a commodity. It does not touch the sales estimate, which
    --- compares full scans only, nor the scan count a resale waits on.
    function D.apply_search(result)
        if not result or not result.item_id then return end
        local k = key(result.item_id)
        local rec = data.items[k]
        if not rec then
            rec = { f = result.at, c = 0 }
            data.items[k] = rec
        end
        if result.kind ~= "none" then rec.k = result.kind end
        local others = {}
        for i = 1, #result.rows do
            local r = result.rows[i]
            if not r.own and r.unit > 0 then others[#others + 1] = r end
        end
        local market, lowest, qty = P.market_value(others)
        rec.n = lowest
        rec.sn, rec.sq, rec.st = lowest, qty, result.at
        if market then
            -- A search is the whole of one item's listings, so its market value
            -- is as good as a scan's, and is folded into the usual price the
            -- same way -- by time, so a search every five minutes counts no
            -- more than the five minutes it covers. (The sales estimate still
            -- compares full scans only.)
            rec.h = P.blend(rec.h, market, result.at - (rec.ht or result.at), PRICE_HALF_LIFE)
            rec.ht = result.at
            rec.m = market
            add_day(rec, result.at, market, qty, lowest, 0)
        end
        if not (data.info[k] and data.info[k].ok) then wanted[result.item_id] = true end
        dirty = true
    end

    ctx.on("jambix.market.search", function(result) D.apply_search(result) end)

    --- Forgets every price and the scan baseline (the info cache stays).
    function D.reset()
        data.items = {}
        data.meta = { own_v = 1 }
        data.own = {}
        prev = nil
        dirty = true
        D.save(true)
        -- The saved scan too, or a reload would bring it (and its sales) back.
        if snap_file then ctx.storage.write_json(snap_file, {}, false) end
    end

    function D.stats()
        local n = 0
        for _ in pairs(data.items) do n = n + 1 end
        local i = 0
        for _ in pairs(data.info) do i = i + 1 end
        local w = 0
        for _ in pairs(wanted) do w = w + 1 end
        return { items = n, info = i, wanted = w, file = file, last_scan = data.meta.last_scan,
            scans = data.meta.scans or 0 }
    end

    return D
end

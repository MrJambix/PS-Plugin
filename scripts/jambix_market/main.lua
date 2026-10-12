-- Jambix Market -- make money on the WoW Forever auction house. Built on JCore.
--
-- What it does, module by module (each is a factory taking the bundle M, and
-- the order they are built in below is the dependency graph):
--
--   util     money text, a calendar clock (the loader has no os.time)
--   pricing  the arithmetic: market value, sales between scans, post price,
--            what a purchase would make -- pure, tested offline
--   ah       the only caller of core.auction_house: guarded, single-flight
--            searches, the window's open/closed state
--   db       per-realm price history and sales estimates, item info
--   scanner  the full scan (ReplicateItems), every 20 minutes the AH is open
--   ledger   gold by day, purchases, sales from the mailbox, fees, profit
--   deals    what is worth buying from the last scan
--   gear     weapons, armor and every single item, priced by roll ("of the
--            Monkey"): deals bought like the rest, POSTED BY YOU (Forever
--            never takes post_item), and what to post at what buyout
--   bags     what you carry and what to do with each item
--   trader   buying, posting and cancelling, one job at a time, checked;
--            the gold limits every purchase is held to
--   auto     AUTO: buys, posts, reposts, collects and vendors by itself
--   window   the AUTO button and eight read-only tabs (no manual trading:
--            the user, 2026-10-07, "make it all AUTO"; gear is the one thing
--            you post, because the game allows nothing else)
--
-- FOREVER ONLY (the user, 2026-10-07: "Make it for Forever only"). Forever's
-- auction house is Blizzard's modern one (C_AuctionHouse), which the core
-- drives there since 2026-10-06; Era's is the legacy one, with no full scan
-- worth the name and none of the commodity calls. On any other client this
-- registers, shows one line on its page, and does nothing at all.

---@diagnostic disable: lowercase-global

local MINIMUM_CORE = "1.7.9"      -- inventory.bag_rows (1.7.9 is the old 1.13.1, renumbered)
local PACKAGE = "jambix_market"
local VERSION = "1.2.5"

-- =============================================================================
-- MODULE LOADING -- loader builds differ on whether a package-local require
-- resolves from the package folder or the scripts root; try both.
-- =============================================================================

local resolved_prefix = nil

local function load_module(relative_path)
    local candidates
    if resolved_prefix then
        candidates = { resolved_prefix .. relative_path }
    else
        candidates = { relative_path, PACKAGE .. "/" .. relative_path, "./" .. relative_path }
    end
    local errors = {}
    for i = 1, #candidates do
        local ok, result = pcall(require, candidates[i])
        local kind = type(result)
        if ok and (kind == "function" or kind == "table") then
            if not resolved_prefix then
                resolved_prefix = candidates[i]:sub(1, #candidates[i] - #relative_path)
            end
            return result
        end
        errors[#errors + 1] = ok and ("returned " .. kind .. " from " .. candidates[i]) or tostring(result)
    end
    error("Jambix Market: could not load '" .. relative_path .. "': " .. table.concat(errors, " | "))
end

-- =============================================================================
-- START
-- =============================================================================

local function start(JCore)
    if not JCore.require_version(MINIMUM_CORE) then
        core.log_error(("[Jambix Market] needs JCore %s or newer, found %s")
            :format(MINIMUM_CORE, tostring(JCore.version)))
        return
    end

    local M = { JCore = JCore, VERSION = VERSION }

    local ctx = JCore.register({
        id      = "jambix.market",
        name    = "Jambix Market",
        version = VERSION,
        kind    = "plugin",
        on_load = function(self) self.log.info("Jambix Market " .. VERSION .. " online") end,
        on_unload = function()
            if M.db then pcall(M.db.save, true) end
            if M.gear then pcall(M.gear.save, true) end
        end,
        on_disable = function()
            if M.db then pcall(M.db.save, true) end
            if M.gear then pcall(M.gear.save, true) end
        end,
    })
    if not ctx then return end
    M.ctx, M.log = ctx, ctx.log

    local menu = ctx.menu({ icon = "activity", root = true })
    M.menu = menu

    -- ==========================================================================
    -- FOREVER ONLY
    -- ==========================================================================
    local forever, client = false, ""
    pcall(function()
        forever = ctx.world.is_forever() == true
        client = tostring(ctx.world.client().version or "")
    end)
    if not forever then
        local s = menu:section("Jambix Market", "activity")
        s:label("Jambix Market is for WoW Forever only.")
        s:label("This client (" .. (client ~= "" and client or "unknown") .. ") is not Forever, so it does nothing here.")
        ctx.log.fmt("info", "%s client: Jambix Market is for Forever only and stays off", client)
        return
    end

    -- ==========================================================================
    -- SETTINGS -- almost none: the user, 2026-10-07, "fix it so it can
    -- automatically Know what to spend when to spend it and not relying on my
    -- Limits! ... remove all manual sets make it all auto".
    --
    -- What is left on the page: switch the plugin on, Auto on or off, open the
    -- window, its key, and clearing data. Everything else is FIXED below (rules
    -- that do not depend on you) or worked out in modules/policy.lua (amounts
    -- that follow your gold and the plugin's own results). Reads of the old
    -- setting ids go to FIXED, never to the menu, so a value an earlier build
    -- saved cannot come back.
    -- ==========================================================================

    M.FIXED = {
        -- scanning
        scan_every = 3, quick_scan = true, quick_items = 80, auto_scan = true,
        -- Auto does every part
        auto_buy = true, auto_sell = true, auto_repost = true, auto_collect = true, auto_vendor = true,
        -- your own items are not Auto's to sell
        auto_sell_all = false,
        repost_wait = 15, repost_max = 3,
        -- what counts as a deal (the money and the certainty are policy.lua's)
        deal_vendor = true, deal_flip = true, deal_min_margin = 25, deal_min_sold = 0, deal_stock_days = 3,
        -- posting: never under the floor, at most twice the usual price
        post_margin = 10, post_ceiling = 200, below_floor = 1,
        -- the window
        open_with_ah = true, close_with_ah = true, icons = true,
    }
    M.FIXED_MONEY = { undercut = 1, sell_min_value = 100, deal_min_spend = 0 }

    function M.cfg(id, default)
        if M.FIXED[id] ~= nil then return M.FIXED[id] end
        local v = menu:get_or(id, default)
        if v == nil then return default end
        return v
    end

    function M.money(id)
        return M.FIXED_MONEY[id] or 0
    end

    local general = menu:section("Jambix Market", "settings")
    -- OFF EVERY TIME THE SCRIPTS LOAD (the user, 2026-10-10: "Market should
    -- always be of and require us to turn it on"). Both switches are put back
    -- off here, whatever was saved: nothing scans, opens, reads your auctions
    -- or trades until you turn Market on, and nothing trades until you press
    -- AUTO. (Off, it still writes down your gold and the sale mails you take,
    -- so what Auto already posted settles in its books.)
    general:toggle("enabled", "Turn Jambix Market on (it is off every time the scripts load)", false)
    general:toggle("auto_trade", "AUTO: trade by itself (the AUTO button in the window)", false)
    menu:set("enabled", false)
    menu:set("auto_trade", false)
    -- The one movement switch (the user, 2026-10-08: "make the Moving to AH and
    -- the Mailbox a checkbox if its not checked its gonna have to be manual!
    -- mainly cause im reworking pathing"). Off by default: you walk to the
    -- mailbox yourself, and Auto still takes the mail when you open it.
    general:toggle("mail_runs", "Walk to the mailbox and back to the auctioneer by itself (mail runs)", false)
    general:button("open_window", "Open the market window", {
        on_click = function() if M.window then M.window.show() end end,
    })
    general:keybind("window_key", "Toggle the market window", 0, { mode = "toggle", modes = { "toggle", "hold" } })
    general:label("Everything else is decided by the plugin, from your gold and from how its own trades")
    general:label("have gone: what to spend on each deal and when, how sure a deal must be (tuned to keep")
    general:label("98% of purchases profitable), the auction house cut (learned from your sales), and how")
    general:label("long to post for. The lines below show what it has decided right now.")

    -- What the plugin has decided, live.
    menu:live_lines(10, function()
        local U, Pol = M.util, M.policy
        if not (U and Pol) then return {} end
        local cap = Pol.capital()
        local ok, n = Pol.record()
        return {
            M.cfg("enabled", false) and (M.auto and M.auto.active() and "Market is ON and trading (AUTO)"
                or "Market is ON: scanning; press AUTO to trade")
                or "Market is OFF until you turn it on (above, or in the window): nothing scans or trades",
            string.format("Capital %s: gold %s + stock %s", U.money(cap.capital), U.money(cap.gold),
                U.money(cap.invested)),
            string.format("Keeps %s (10%%); free to spend %s; stock room %s", U.money(cap.reserve),
                U.money(cap.free), U.money(cap.stock_room)),
            string.format("One deal may get up to %s, sized to how sure it is (quarter Kelly)", U.money(cap.max_deal)),
            string.format("Big money: a deal expected to make %s or more (5%% of capital, at least 20s) after "
                .. "every cost", U.money(Pol.big_line(cap))),
            string.format("Never bought: a deal making under %s, or under twice its deposits (48 h deposit: "
                .. "%.0f%% of the vendor price a unit, at least 1s)", U.money(Pol.min_profit(cap)),
                (Pol.deposit_rate(48) or 0.6) * 100),
            string.format("Confidence bar: %.2f%% (%d of %d purchases made money); a resale is judged over "
                .. "%s", Pol.bar() * 100, ok, n, Pol.posts_max() > 1 and "up to two 48 h posts"
                    or "one 48 h post (two once 10 have sold out and 98% made money)"),
            string.format("Auction house cut: %.1f%%", Pol.cut()),
            string.format("Scans every 3 minutes: a full scan every %s (as often as the server gives one), "
                .. "quick in between", U.ago(M.scanner.gap())),
            M.gear and string.format("Gear: priced by roll, bought like the rest, posted by YOU (the game never lets "
                .. "Auto post a single item); %d piece(s) waiting for you, two at most", (M.gear.waiting())) or "",
        }
    end)

    -- ==========================================================================
    -- THE BUNDLE
    -- ==========================================================================

    M.util = load_module("modules/util")
    local U = M.util

    local activity = {}
    function M.activity(text)
        activity[#activity + 1] = { t = U.now(), text = text }
        if #activity > 60 then table.remove(activity, 1) end
        ctx.log.info(text)
    end
    function M.activity_log() return activity end
    function M.debug(fmt, ...) ctx.log.fmt("debug", fmt, ...) end
    function M.toast(text, kind)
        pcall(JCore.ui.toast, text, { kind = kind or "info", title = "Jambix Market", duration = 4 })
    end

    M.pricing = load_module("modules/pricing")
    M.ah = load_module("modules/ah")(M)
    M.db = load_module("modules/db")(M)
    M.scanner = load_module("modules/scanner")(M)
    M.ledger = load_module("modules/ledger")(M)
    M.policy = load_module("modules/policy")(M)
    M.deals = load_module("modules/deals")(M)
    M.gear = load_module("modules/gear")(M)
    M.bags = load_module("modules/bags")(M)
    M.trader = load_module("modules/trader")(M)
    M.auto = load_module("modules/auto")(M)
    M.presence = load_module("modules/presence")(M)
    M.errands = load_module("modules/errands")(M)
    M.window = load_module("modules/window")(M)

    -- The price file is per realm; wait (up to ten seconds) for the realm.
    local boot_at = core.time()
    local load_job
    load_job = ctx.tick(function()
        local realm = ""
        pcall(function() realm = ctx.world.realm() or "" end)
        if realm ~= "" or core.time() - boot_at > 10 then
            M.db.load()
            M.gear.load()
            M.deals.compute()
            ctx.remove_job(load_job)
        end
    end, { interval = 1.0 })

    -- The window key, never while typing. A toggle-mode key's state is a latch
    -- that flips on each press, so the window toggles on every change of it:
    -- each press in toggle mode, press and release in hold mode (the review,
    -- 1.0.0: on the rising edge only, every second press did nothing).
    local key_was = false
    ctx.tick(function()
        local active = menu:is_keybind_active("window_key") and true or false
        if active ~= key_was and not ctx.input.is_typing() then M.window.toggle() end
        key_was = active
    end, { interval = 0.05 })

    -- Deals go stale as the scan ages; rebuild every five minutes.
    ctx.every(300, function() M.deals.compute() end)
    menu:title(function()
        local g = M.ledger.gold()
        local last = M.db.meta().last_scan
        if not M.cfg("enabled", false) then
            return string.format("Market OFF (turn it on below)  |  Gold %s  |  last full scan %s",
                g and U.money(g) or "...", last and (U.ago(U.now() - last) .. " ago") or "never")
        end
        return string.format("Gold %s  |  projected profit %s  |  %d deal(s)  |  last full scan %s  |  Auto %s",
            g and U.money(g) or "...", U.signed(M.auto.projection().total), #M.deals.list(),
            last and (U.ago(U.now() - last) .. " ago") or "never", M.auto.active() and "ON" or "off")
    end)

    -- Market on: a scan cycle at once if the auction house is open. Market
    -- off: AUTO goes off with it, so it never trades again by itself when
    -- Market is turned back on.
    menu:on_change("enabled", function(on_now)
        if on_now then
            M.activity("Jambix Market ON")
            if M.ah.is_open() then M.scanner.cycle_now() end
        else
            if M.cfg("auto_trade", false) then M.menu:set("auto_trade", false) end
            M.trader.stop_auto()
            M.activity("Jambix Market OFF")
        end
    end)

    local data_section = menu:section("Data", "settings")
    data_section:button("forget_prices", "Forget every price and sales estimate", {
        on_click = function()
            pcall(JCore.ui.confirm, {
                title = "Forget all prices?", tone = "danger", confirm_label = "Forget",
                body = "The price history and sales estimates for this realm are deleted. Item names, "
                    .. "the ledger and gold history stay.",
                on_confirm = function()
                    M.db.reset()
                    M.deals.compute()
                    M.activity("Price history cleared")
                end,
            })
        end,
    })
    data_section:button("clear_ledger", "Clear the trade ledger", {
        on_click = function()
            pcall(JCore.ui.confirm, {
                title = "Clear the ledger?", tone = "danger", confirm_label = "Clear",
                body = "Every recorded purchase, sale and fee, and the stock Auto is holding to sell, are "
                    .. "forgotten. Gold history and prices stay.",
                on_confirm = function()
                    M.ledger.reset_trades()
                    M.activity("Trade ledger cleared")
                end,
            })
        end,
    })

    _G.JambixMarket = M
end

-- Not before a character is in the world (1.2.5): at the character select
-- screen the game has not loaded the tables an item or spell name is read
-- from, and asking one there kills the client (ASSERT(IsLoaded())).
local function jcore_in_world(J)
    return type(J.in_world) ~= "function" or J.in_world()
end

if _G.JCore and jcore_in_world(_G.JCore) then
    start(_G.JCore)
else
    local deadline, started = core.time() + 15.0, false
    core.register_on_update_callback(function()
        if started then return end
        local J = _G.JCore
        if J then
            if jcore_in_world(J) then
                started = true
                start(J)
            end
        elseif core.time() > deadline then
            started = true
            core.log_error("[Jambix Market] JCore never loaded; plugin inactive")
        end
    end)
end

-- Jambix AIO / forever_npc -- the vendor and the quest givers, on Forever.
--
-- Three switches on the Automation page, built only on the Forever client
-- (asked for there on 2026-10-03; on every other client this file is never
-- loaded and the Automation page is unchanged):
--
--   Sell junk      at any merchant, every grey item with a sell price goes
--   Accept quests  what a quest giver offers is taken
--   Turn in        finished quests are handed in, and when the reward is a
--                  choice, the one that fits the class best is taken
--
-- Holding Shift as a window opens leaves that window to the player.
--
-- WHAT IT STANDS ON. The API recorder (sessions 1-26 on the Forever beta)
-- saw these answer there:
--   MERCHANT_SHOW / MERCHANT_CLOSED, GOSSIP_SHOW / GOSSIP_CLOSED,
--   QUEST_DETAIL, QUEST_PROGRESS, QUEST_COMPLETE, QUEST_ACCEPTED (id) and
--   QUEST_TURNED_IN (id, xp, money) all arrive;
--   get_gossip_available_quests / get_gossip_active_quests answer rows with
--   real quest ids and is_complete; get_reward_money answers at
--   QUEST_COMPLETE; get_items_in_bag and item:get_item_id answer.
-- It has NOT yet seen these answer there, so each one's first use leaves a
-- line in the recorder's trace (jcore.trace.txt):
--   core.quests.get_item_info (quality, sell price, armour, item level),
--   get_quest_item_link("choice", i), use_container_item at a merchant,
--   accept_quest, complete_quest, get_quest_reward and the gossip selects.
--
-- SELLING IS CHECKED, ONE ITEM AT A TIME. The (bag, slot) pair comes from
-- inventory_helper, and a wrong pair sells the item next to the one meant.
-- So every sale is followed by a look at where each carried item sits, read
-- straight from the client by guid: the item meant must have left its slot
-- and no other carried item may have. Anything else stops selling until the
-- scripts are reloaded, and says what went, so it can be bought back from
-- the merchant's Buyback tab. (1.51.0 checked by counting instead, and on
-- Forever a sold item stays in the player's item array, so the count never
-- fell: three good sales read as failures, and a later recount stopped
-- selling for an item sold a visit earlier. Fixed in 1.54.0.)
--
-- ONLY THE BAGS. inventory_helper reads bag 0 out of that same array, from
-- client slot 35 on, and does not stop where the backpack does: the
-- merchant's Buyback list comes back as bag 0 slots past it. After a reload
-- (which forgets what was sold) Broken Boar Tusk, sold earlier, was offered
-- as "bag 0 slot 39" (client slot 0:73), three such sales a visit changed
-- nothing, and selling gave up (2026-10-04). Since 1.66.2 a bag 0 row past
-- the backpack's size is neither sold nor watched.

-- WHICH REWARD (1.7.4): the class kit, the fit test and the choice moved to
-- modules/rewards.lua, unchanged, so the guide walk (guidewalk.lua) chooses the
-- same way on every client.

return function(P)
    local ctx, log = P.ctx, P.log
    local units = P.units

    -- Which reward to take (modules/rewards.lua, 1.7.4).
    local load = P.load or function(path) return require("jambix_aio/" .. path) end
    local rewards = load("modules/rewards")
    local pick_reward = rewards.pick_reward

    local M = {}

    local SELL_GAP = 0.3          -- seconds between two sales
    local EMPTY_LOOK = 1.5        -- and between looks at bags with nothing to sell
    local SETTLE = 0.25           -- a sale is looked for this long after it was made, at the earliest
    local VERIFY_TIMEOUT = 1.5    -- and given up on after this long
    local MISSES_PER_VISIT = 3    -- sales that changed nothing before selling stops for the visit
    local REACT_MIN, REACT_SPAN = 0.15, 0.25   -- a quest window is answered this long after it opens
    local WANT_TTL = 6.0          -- an answer not given by then is dropped
    local LINK_WAIT = 0.6         -- a reward window with no choices is looked at again for this long
    local INFO_WAIT = 2.0         -- seconds a reward choice waits for its item data
    local INFO_RETRY = 2.0        -- an item with no data is asked about again after this long
    local QUEST_RETRY = 60        -- a quest picked twice in this long is left to the player
    local MAX_CHOICES = 10
    local MAX_GREETING = 10
    local SHIFT = 0x10            -- VK_SHIFT

    M.fit, M.pick_reward, M.role_of = rewards.fit, rewards.pick_reward, rewards.role_of

    local function now() return core.time() end

    --- `core.<namespace>.<field>` when it is a function, read at call time so
    --- the recorder's wrapper is the one called.
    local function api(namespace, field)
        local group = type(core) == "table" and core[namespace] or nil
        if type(group) ~= "table" then return nil end
        local fn = group[field]
        if type(fn) ~= "function" then return nil end
        return fn
    end

    local function call(namespace, field, ...)
        local fn = api(namespace, field)
        if not fn then return nil end
        local ok, value = pcall(fn, ...)
        if ok then return value end
        return nil
    end

    --- One line in the log and the same in the recorder's trace.
    local function trace(fmt, ...)
        local text = string.format(fmt, ...)
        log.fmt("info", "%s", text)
        if ctx.emit then pcall(ctx.emit, "jcore.recorder.trace", text) end
    end

    local function on(id)
        return P.master_on() and P.opt(id, false) == true
    end

    local function by_hand()
        return call("input", "is_key_pressed", SHIFT) == true
    end

    local function money(copper)
        copper = math.floor(tonumber(copper) or 0)
        local g, s, c = math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100
        if g > 0 then return string.format("%dg %ds %dc", g, s, c) end
        if s > 0 then return string.format("%ds %dc", s, c) end
        return string.format("%dc", c)
    end

    -- --- item data -------------------------------------------------------------

    local info_cache = {}       -- item id or link -> answer with a name
    local info_asked = {}       -- item id or link -> when an empty answer came back

    ---@param key integer|string item id or link
    ---@param fresh? boolean ask even if an empty answer came back lately
    local function item_info(key, fresh)
        if key == nil then return nil end
        local hit = info_cache[key]
        if hit then return hit end
        local t = now()
        if not fresh and info_asked[key] and t - info_asked[key] < INFO_RETRY then return nil end
        local info = call("quests", "get_item_info", key)
        if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            info_cache[key] = info
            return info
        end
        info_asked[key] = t
        return nil
    end

    -- --- selling junk ----------------------------------------------------------

    local helper
    do
        local ok, mod = pcall(require, "common/utility/inventory_helper")
        if ok and type(mod) == "table" then helper = mod end
    end

    local function guid_of(obj)
        local ok, guid = pcall(obj.get_guid, obj)
        if ok and type(guid) == "string" and guid ~= "" then return guid end
        return nil
    end

    --- Where every carried item sits, read straight from the client:
    --- guid -> { at = "bag:slot_id", id = item id }.
    ---
    --- WHY PLACES AND NOT COUNTS. Bag 0 is the player's whole item array, and
    --- on Forever a sold item stays in it (seen 2026-10-03: three sales that
    --- emptied their slots never lowered a count). A sale is the item
    --- leaving ITS slot, and that holds wherever the client keeps it after.
    local function places()
        local get = api("inventory", "get_items_in_bag")
        if not get then return nil end
        local out = {}
        for bag = 0, 4 do
            local ok, rows = pcall(get, bag)
            if ok and type(rows) == "table" then
                for i = 1, #rows do
                    local row = rows[i]
                    local obj = row and row.object
                    local guid = obj and guid_of(obj)
                    if guid then
                        local ok_id, id = pcall(obj.get_item_id, obj)
                        out[guid] = { at = tostring(bag) .. ":" .. tostring(row.slot_id),
                            id = ok_id and tonumber(id) or nil }
                    end
                end
            end
        end
        return out
    end

    local unread_warned, guidless_warned, outside_traced = false, false, false
    local sold = {}               -- guid -> true: sold this session, never offered again

    local BACKPACK_SLOTS = 16     -- the classic backpack, when the size cannot be read

    --- How many slots the backpack has, from JCore (its bag 1: the core's bag
    --- sizes are shifted by one), which already replaces an answer no
    --- backpack can have.
    local function backpack_slots()
        local inv = ctx.inventory
        if type(inv) == "table" and type(inv.bag_slots) == "function" then
            local ok, n = pcall(inv.bag_slots, 1)
            n = ok and tonumber(n) or nil
            if n and n >= 1 then return n end
        end
        return BACKPACK_SLOTS
    end

    --- The grey items in the bags with a sell price, as inventory_helper
    --- places them, less the slots this visit has given up on; and the guid
    --- of every item in the bags, which a sale must leave where it was.
    local function junk_rows(skip)
        local out, carried = {}, {}
        if not helper then return out, carried end
        local ok, rows = pcall(helper.get_character_bag_slots, helper)
        if not ok or type(rows) ~= "table" then return out, carried end
        local seen, unread, guidless, outside = 0, 0, 0, 0
        local backpack = backpack_slots()
        for i = 1, #rows do
            local row = rows[i]
            local obj = row and row.item
            -- Past the backpack is the Buyback list, not the bags (see the top).
            local past = obj and row.bag_id == 0 and (tonumber(row.bag_slot) or 0) > backpack
            if past then outside = outside + 1 end
            if obj and row.bag_id and row.bag_slot and not past then
                local guid = guid_of(obj)
                if guid then carried[guid] = true else guidless = guidless + 1 end
                local ok_id, id = pcall(obj.get_item_id, obj)
                if ok_id and type(id) == "number" and id > 0 then
                    seen = seen + 1
                    local info = item_info(id)
                    if not info then
                        unread = unread + 1
                    elseif tonumber(info.quality) == 0 and (tonumber(info.sell_price) or 0) > 0 then
                        local key = tostring(row.bag_id) .. ":" .. tostring(row.bag_slot)
                        if guid and not sold[guid] and not skip[key] then
                            out[#out + 1] = {
                                id = id, guid = guid, bag = row.bag_id, slot = row.bag_slot, key = key,
                                name = info.name, stack = tonumber(row.stack_count) or 1,
                                price = tonumber(info.sell_price) or 0,
                            }
                        end
                    end
                end
            end
        end
        if seen > 0 and unread == seen and not unread_warned then
            unread_warned = true
            trace("sell junk: get_item_info answered nothing for %d bag item(s); grey items cannot be told apart yet",
                seen)
        end
        if guidless > 0 and not guidless_warned then
            guidless_warned = true
            trace("sell junk: %d bag item(s) answered no guid; a sale cannot be checked, so they are kept", guidless)
        end
        if outside > 0 and not outside_traced then
            outside_traced = true
            trace("sell junk: %d item(s) past the %d-slot backpack (the merchant's Buyback) are not in the bags; left alone",
                outside, backpack)
        end
        return out, carried
    end

    local shop = { open = false }
    local halted = nil            -- why selling stopped for the session
    local sales = { sold = 0, copper = 0, visits = 0 }
    local landing_traced = false

    local function merchant_open()
        local t = now()
        shop = {
            open = true, hand = by_hand(), at = t, last_sale = t, sold = 0, copper = 0,
            misses = 0, skip = {}, pending = nil,
        }
        sales.visits = sales.visits + 1
    end

    local function merchant_closed()
        if shop.open and shop.sold > 0 then
            trace("sell junk: sold %d item(s) for %s", shop.sold, money(shop.copper))
        end
        shop.open = false
        shop.pending = nil
    end

    --- Did the last sale take the item meant out of its slot, and leave every
    --- other carried item where it was?
    local function verify(t)
        local p = shop.pending
        if t - p.at < SETTLE then return end
        local after = places()
        if not after then
            shop.pending = nil
            return
        end
        for guid, was in pairs(p.watch) do
            local now_at = after[guid] and after[guid].at
            if now_at ~= was.at then
                local info = was.id and item_info(was.id)
                halted = string.format("%s left its bag slot instead of %s",
                    (info and info.name) or ("item " .. tostring(was.id)), p.name)
                shop.pending = nil
                log.fmt("warn", "sell junk STOPPED: %s. Buy it back from the merchant's Buyback tab; "
                    .. "selling stays off until the scripts are reloaded.", halted)
                if ctx.emit then
                    pcall(ctx.emit, "jcore.recorder.trace", string.format(
                        "sell junk STOPPED: %s (bag:slot %s, client slot %s -> %s)",
                        halted, p.key, was.at, tostring(now_at)))
                end
                return
            end
        end
        local mine = after[p.guid]
        if not mine or mine.at ~= p.from then
            sold[p.guid] = true
            local copper = p.price * p.stack
            shop.sold, shop.copper = shop.sold + 1, shop.copper + copper
            sales.sold, sales.copper = sales.sold + 1, sales.copper + copper
            shop.pending = nil
            if not landing_traced then
                landing_traced = true
                trace("sell junk: %s left client slot %s for %s", p.name, p.from,
                    mine and ("client slot " .. mine.at) or "nowhere the bags show")
            end
            return
        end
        if t - p.at >= VERIFY_TIMEOUT then
            shop.misses = shop.misses + 1
            shop.skip[p.key] = true
            shop.pending = nil
            if shop.misses >= MISSES_PER_VISIT then
                trace("sell junk: %d sale(s) left their item in place at this merchant; leaving the rest",
                    shop.misses)
            end
        end
    end

    local function sell_tick(t)
        if not shop.open or shop.hand or halted then return end
        if not on("npc_sell_junk") then return end
        if shop.pending then
            verify(t)
            return
        end
        if shop.misses >= MISSES_PER_VISIT then return end
        if t - shop.last_sale < SELL_GAP then return end

        local list, carried = junk_rows(shop.skip)
        local row = list[1]
        if not row then
            shop.last_sale = t + EMPTY_LOOK - SELL_GAP
            return
        end
        local use = api("input", "use_container_item")
        if not use then
            log.once("warn", "npc_no_use_container", "core.input.use_container_item is missing; nothing is sold")
            return
        end
        local before = places()
        local from = before and before[row.guid]
        if not from then
            -- The helper's row is older than the bags: the item is not there now.
            shop.skip[row.key] = true
            return
        end
        local watch = {}
        for guid in pairs(carried) do
            if guid ~= row.guid and before[guid] and not sold[guid] then watch[guid] = before[guid] end
        end
        shop.last_sale = t
        pcall(use, row.bag, row.slot)
        shop.pending = {
            guid = row.guid, id = row.id, name = row.name, key = row.key, from = from.at, watch = watch,
            at = t, price = row.price, stack = row.stack,
        }
        if not shop.first_traced then
            shop.first_traced = true
            trace("sell junk: selling %s from bag %s slot %s (client slot %s)", row.name, tostring(row.bag),
                tostring(row.slot), from.at)
        end
    end

    -- --- quests ----------------------------------------------------------------

    local want = nil              -- { kind, at, due }: the window waiting for an answer
    local tries = {}              -- quest id (or "t:" .. title) -> { n, at }
    local complete_titles = {}    -- title -> true, from gossip rows, for QUEST_GREETING
    local quest_stats = { accepted = 0, turned_in = 0, by_hand = 0, last_reward = nil }

    local function may_try(key)
        local r = tries[key]
        if not r or now() - r.at > QUEST_RETRY then return true end
        return r.n < 2
    end

    local function tried(key)
        local r = tries[key]
        if not r or now() - r.at > QUEST_RETRY then
            r = { n = 0 }
            tries[key] = r
        end
        r.n, r.at = r.n + 1, now()
    end

    local function wants_window(kind)
        if kind == "accept" then return on("npc_accept_quests") end
        if kind == "progress" or kind == "complete" then return on("npc_turn_in_quests") end
        return on("npc_accept_quests") or on("npc_turn_in_quests")
    end

    local function answer(kind)
        if not wants_window(kind) then return end
        if by_hand() then
            quest_stats.by_hand = quest_stats.by_hand + 1
            want = nil
            return
        end
        local t = now()
        want = { kind = kind, at = t, due = t + REACT_MIN + math.random() * REACT_SPAN }
    end

    local function title_of(r)
        return type(r.title) == "string" and r.title ~= "" and r.title or ("quest " .. tostring(r.quest_id))
    end

    --- A giver's window: hand in what is finished, then take what is offered.
    local function gossip_step()
        local active = call("quests", "get_gossip_active_quests")
        local available = call("quests", "get_gossip_available_quests")
        if type(active) == "table" then
            for i = 1, #active do
                local r = active[i]
                if type(r) == "table" and r.is_complete == true and type(r.title) == "string" then
                    complete_titles[r.title] = true
                end
            end
        end

        if on("npc_turn_in_quests") and type(active) == "table" then
            for i = 1, #active do
                local r = active[i]
                local id = type(r) == "table" and tonumber(r.quest_id) or nil
                if id and r.is_complete == true and not r.is_repeatable and may_try(id) then
                    tried(id)
                    call("quests", "select_gossip_active_quest", id)
                    trace("quests: handing in %s (%d)", title_of(r), id)
                    return
                end
            end
        end

        -- Grey (trivial) and repeatable quests are left alone: a repeatable
        -- one is usually a turn-in that spends something from the bags.
        if on("npc_accept_quests") and type(available) == "table" then
            for i = 1, #available do
                local r = available[i]
                local id = type(r) == "table" and tonumber(r.quest_id) or nil
                if id and not r.is_trivial and not r.is_repeatable and not r.is_ignored and may_try(id) then
                    tried(id)
                    call("quests", "select_gossip_available_quest", id)
                    trace("quests: picking up %s (%d)", title_of(r), id)
                    return
                end
            end
        end
    end

    --- The older multi-quest window. It names its quests only by title, and
    --- says nothing of which are finished: a quest goes back only when a
    --- giver's gossip already said it was complete.
    local function greeting_step()
        if on("npc_turn_in_quests") then
            for i = 1, MAX_GREETING do
                local title = call("quests", "get_active_title", i)
                if type(title) ~= "string" or title == "" then break end
                local key = "t:" .. title
                if complete_titles[title] and may_try(key) then
                    tried(key)
                    call("quests", "select_active_quest", i)
                    trace("quests: handing in %s", title)
                    return
                end
            end
        end
        if on("npc_accept_quests") then
            for i = 1, MAX_GREETING do
                local title = call("quests", "get_available_title", i)
                if type(title) ~= "string" or title == "" then break end
                local key = "t:" .. title
                if may_try(key) then
                    tried(key)
                    call("quests", "select_available_quest", i)
                    trace("quests: picking up %s", title)
                    return
                end
            end
        end
    end

    --- Who the character is, for the reward (rewards.who).
    local function who() return rewards.who(P, item_info) end

    --- The reward window: choose, then take it. False while still waiting
    --- for the choices or their item data to arrive.
    local function complete_step(w, t)
        local links = {}
        for i = 1, MAX_CHOICES do
            local link = call("quests", "get_quest_item_link", "choice", i)
            if type(link) ~= "string" or link == "" then break end
            links[#links + 1] = link
        end
        if #links == 0 and t - w.at < LINK_WAIT then return false end

        if #links <= 1 then
            call("quests", "get_quest_reward", #links)
            trace("quests: turned in (%s)", #links == 1 and "one reward" or "no reward choice")
            return true
        end

        local choices, missing = {}, 0
        for i = 1, #links do
            local link = links[i]
            local info = item_info(link, true)
            if not info then
                local id = tonumber(link:match("item:(%d+)"))
                info = id and item_info(id, true) or nil
            end
            if not info then missing = missing + 1 end
            choices[i] = { index = i, link = link, info = info }
        end
        if missing > 0 and t - w.at < INFO_WAIT then return false end

        local index, why = pick_reward(choices, who())
        quest_stats.last_reward = why
        call("quests", "get_quest_reward", index)
        trace("quest reward: %s%s", why,
            missing > 0 and string.format(" (%d choice(s) without item data)", missing) or "")
        return true
    end

    local function quest_tick(t)
        local w = want
        if not w then return end
        if t - w.at > WANT_TTL or not P.master_on() then
            want = nil
            return
        end
        if t < w.due then return end

        local done = true
        if w.kind == "gossip" then
            gossip_step()
        elseif w.kind == "greeting" then
            greeting_step()
        elseif w.kind == "accept" then
            if on("npc_accept_quests") then
                call("quests", "accept_quest")
                trace("quests: accepted the quest on offer")
            end
        elseif w.kind == "progress" then
            if on("npc_turn_in_quests") then call("quests", "complete_quest") end
        elseif w.kind == "complete" then
            if on("npc_turn_in_quests") then done = complete_step(w, t) end
        end
        -- A step can open the next window before it returns (its event
        -- replaces `want`); only the answer just given is cleared.
        if done and want == w then want = nil end
    end

    -- --- wiring ----------------------------------------------------------------

    if ctx.on then
        local function hear(event, fn)
            ctx.on("jcore.game_event." .. event, function(args)
                local ok, err = pcall(fn, args)
                if not ok then log.once("warn", "npc_" .. event, "vendor/quests " .. event .. ": " .. tostring(err)) end
            end)
        end
        hear("MERCHANT_SHOW", merchant_open)
        hear("MERCHANT_CLOSED", merchant_closed)
        hear("GOSSIP_SHOW", function() answer("gossip") end)
        hear("QUEST_GREETING", function() answer("greeting") end)
        hear("QUEST_DETAIL", function() answer("accept") end)
        hear("QUEST_PROGRESS", function() answer("progress") end)
        hear("QUEST_COMPLETE", function() answer("complete") end)
        hear("GOSSIP_CLOSED", function()
            if want and want.kind == "gossip" then want = nil end
        end)
        hear("QUEST_ACCEPTED", function() quest_stats.accepted = quest_stats.accepted + 1 end)
        hear("QUEST_TURNED_IN", function() quest_stats.turned_in = quest_stats.turned_in + 1 end)
    end

    ctx.tick(function()
        local t = now()
        sell_tick(t)
        quest_tick(t)
    end, { interval = 0.1 })

    -- --- diagnostics -----------------------------------------------------------

    function M.stats()
        return {
            sold = sales.sold, copper = sales.copper, visits = sales.visits, halted = halted,
            merchant_open = shop.open == true,
            accepted = quest_stats.accepted, turned_in = quest_stats.turned_in,
            by_hand = quest_stats.by_hand, last_reward = quest_stats.last_reward,
            waiting = want and want.kind or nil,
        }
    end

    --- One line for the Overview page.
    function M.summary()
        if halted then return "selling STOPPED: " .. halted end
        return string.format("sold %d (%s), %d accepted, %d handed in",
            sales.sold, money(sales.copper), quest_stats.accepted, quest_stats.turned_in)
    end

    return M
end

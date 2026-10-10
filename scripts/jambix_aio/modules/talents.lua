-- Jambix AIO / talents -- read the Classic talent trees and derive the spec.
--
-- core.game_ui.get_active_talents answers an empty table on Classic, so the
-- trees are walked the Classic way: get_talent_info(tab, index) over the three
-- tabs until the indices run out.
--
-- Forever (Classic+) is ADDED beside that, never instead of it: a classic
-- world on the retail engine, whose talents are trait trees. get_talent_info
-- is {} there and get_active_talents is the answer, so on Forever the scan
-- reads that and maps the trees back onto the three tabs the class modules
-- count with (see scan_traits). Which client it is is decided once, at load;
-- every other client runs exactly the classic walk and nothing else.
--
-- Talents are keyed by NAME for the same reason spells are -- see the note at
-- the top of spellbook.lua. A talent id table would have to be correct for
-- Vanilla and TBC separately and would silently rot.
--
-- What the rotation actually needs from this:
--   * Which tree has the most points, to pick a default profile.
--   * Whether specific talents are taken, because a few of them change the
--     priority rather than just the numbers -- Improved Overpower, Tactical
--     Mastery (which decides whether stance dancing is affordable at all),
--     Flurry, Impale, Improved Slam.

return function(P)
    local ctx, log = P.ctx, P.log

    local M = {}

    -- Tab 1/2/3 are positions, not names: Arms/Fury/Protection on a warrior,
    -- Arcane/Fire/Frost on a mage. Hard-coding the warrior names here made a
    -- mage read "Talents 0/0/0 -> Protection", which is nonsense.
    --
    -- The scan reads the real tab names off the talents themselves where it
    -- can, and the active class module can override. Nothing downstream
    -- assumes a particular set.
    M.TAB_ARMS, M.TAB_FURY, M.TAB_PROT = 1, 2, 3

    local TAB_NAME = { [1] = "Tree 1", [2] = "Tree 2", [3] = "Tree 3" }
    M.TAB_NAME = TAB_NAME

    --- Installs this class's tree names, from the class module.
    ---@param names string[]|nil
    function M.set_tree_names(names)
        if type(names) ~= "table" then return end
        for i = 1, 3 do
            if type(names[i]) == "string" then TAB_NAME[i] = names[i] end
        end
    end

    -- lowercase talent name -> { rank, max_rank, tab }
    local by_name = {}
    local points = { 0, 0, 0 }
    local total_points = 0
    local dominant_tab = 0
    local last_scan = 0
    local scanned_ok = false
    local source = "none"     -- "trees" (classic API) or "traits" (Forever, Retail)
    local split = "none"      -- how points found their tab: "trees", "nodes" (NODE_TAB), "spec", "none"

    -- No Classic tree has more than about 22 entries; the scan stops on the
    -- first index that answers nothing, and this is only the hard stop so a
    -- misbehaving client cannot spin here.
    local MAX_TALENTS_PER_TAB = 40

    local function game_ui_fn(name)
        local ns = type(core.game_ui) == "table" and core.game_ui or nil
        local fn = ns and ns[name]
        return type(fn) == "function" and fn or nil
    end

    --- Is this a trait-tree client (Forever, Retail)? Read from the JCore
    --- world service, which normalises core.get_game_version.
    local function trait_client()
        local world = ctx.world
        if type(world) ~= "table" or type(world.client) ~= "function" then return false end
        local ok, client = pcall(world.client)
        return ok and type(client) == "table" and client.trait_talents == true
    end

    -- Decided once: a client cannot change without a restart, and the
    -- classic clients must not pay for the Forever path at all.
    local TRAITS = trait_client()

    -- tree id -> { node id -> true }. A tree's node list is static data and
    -- around a hundred ids, so it is read once per tree for the session.
    local tree_nodes = {}

    -- THE TAB OF A NODE (1.77.3). Forever keeps a class's three classic trees
    -- in ONE trait tree, side by side, and answers that one tree and
    -- specialization 1: every point was counted for tab 1, so past 20 points
    -- a Feral druid played Balance, a Frost mage Arcane, a Combat rogue
    -- Assassination. The column a node sits in is its tab, which the client's
    -- own tables say (modules/talent_trees.lua, written by
    -- tools/jcheck/talents_extract.js). node id -> 1, 2 or 3.
    local NODE_TAB = {}
    if TRAITS then
        local load = P.load or function(path) return require("jambix_aio/" .. path) end
        local ok, data = pcall(load, "modules/talent_trees")
        local trees = ok and type(data) == "table" and type(data.forever) == "table" and data.forever.trees or nil
        for _, tree in pairs(type(trees) == "table" and trees or {}) do
            for node, tab in pairs(type(tree.nodes) == "table" and tree.nodes or {}) do NODE_TAB[node] = tab end
        end
    end

    local function nodes_of(tree_id)
        local cached = tree_nodes[tree_id]
        if cached then return cached end
        local set = {}
        local get = game_ui_fn("get_talent_tree_nodes")
        local ok, list = false, nil
        if get then ok, list = pcall(get, tree_id) end
        if ok and type(list) == "table" then
            for i = 1, #list do set[list[i]] = true end
        end
        tree_nodes[tree_id] = set
        return set
    end

    --- The classic walk: get_talent_info(tab, index) until a tab runs out.
    local function scan_trees(fresh, fresh_points)
        local get_info = game_ui_fn("get_talent_info")
        if not get_info then return false end
        local any = false
        for tab = 1, 3 do
            for index = 1, MAX_TALENTS_PER_TAB do
                local ok, info = pcall(get_info, tab, index)
                if not ok or type(info) ~= "table" or not info.name or info.name == "" then
                    break
                end

                any = true
                local rank = tonumber(info.rank) or 0
                fresh[info.name:lower()] = {
                    name = info.name,
                    rank = rank,
                    max_rank = tonumber(info.max_rank) or 0,
                    tab = tab,
                    tier = info.tier,
                    column = info.column,
                }
                fresh_points[tab] = fresh_points[tab] + rank
            end
        end
        return any
    end

    --- The trait reader (Forever, Retail): get_active_talents lists what is
    --- bought, one row per node, and names and ranks need nothing more.
    ---
    --- The three tab totals the class modules' `suggest` counts with need the
    --- tree each node sits in:
    ---   three trait trees, one per classic tab  -> the tree's position is the tab
    ---   one tree holding all three (Forever)    -> the node's column (NODE_TAB)
    ---   a class tree plus a chosen spec         -> get_specialization() is the tab
    --- A node the column table does not know (a newer client) falls back to
    --- the spec. When nothing holds, names and ranks are still right and the
    --- totals stay at zero, which every class module reads as "levelling" --
    --- the safe default rather than a guessed spec.
    ---@return boolean any, string split "trees" | "nodes" | "spec" | "none"
    local function scan_traits(fresh, fresh_points)
        local get_active = game_ui_fn("get_active_talents")
        if not get_active then return false end
        local ok, list = pcall(get_active)
        if not ok or type(list) ~= "table" or #list == 0 then return false end

        local trees = {}
        local get_trees = game_ui_fn("get_talent_tree_ids")
        if get_trees then
            local ok_t, ids = pcall(get_trees)
            if ok_t and type(ids) == "table" then trees = ids end
        end

        local spec = nil
        if #trees ~= 3 then
            local get_spec = game_ui_fn("get_specialization")
            if get_spec then
                local ok_s, index = pcall(get_spec)
                if ok_s and type(index) == "number" and index >= 1 and index <= 3 then
                    spec = index
                end
            end
        end

        local any, by_node = false, false
        for i = 1, #list do
            local row = list[i]
            if type(row) == "table" and type(row.name) == "string" and row.name ~= "" then
                local rank = tonumber(row.rank) or 0
                local tab = spec
                if #trees == 3 then
                    for t = 1, 3 do
                        if nodes_of(trees[t])[row.node_id] then
                            tab = t
                            break
                        end
                    end
                elseif NODE_TAB[row.node_id] then
                    tab = NODE_TAB[row.node_id]
                    by_node = true
                end

                -- One name on two nodes (both sides of a choice node) is one
                -- talent to the rotation: keep the higher rank.
                local key = row.name:lower()
                local prev = fresh[key]
                if not prev or rank > prev.rank then
                    fresh[key] = {
                        name = row.name,
                        rank = rank,
                        max_rank = tonumber(row.max_rank) or 0,
                        tab = tab or 0,
                        node_id = row.node_id,
                        spell_id = row.spell_id,
                    }
                end
                if tab then fresh_points[tab] = fresh_points[tab] + rank end
                any = true
            end
        end
        return any, (#trees == 3 and "trees") or (by_node and "nodes") or (spec and "spec") or "none"
    end

    function M.scan()
        local fresh = {}
        local fresh_points = { 0, 0, 0 }

        -- Forever reads its trait trees, and falls back to the classic walk
        -- in case the client still answers it. Every other client runs the
        -- classic walk alone, as it always has. A reader that finds nothing
        -- has written nothing.
        local any, from, how
        if TRAITS then
            any, how = scan_traits(fresh, fresh_points)
            from = "traits"
            if not any then any, from, how = scan_trees(fresh, fresh_points), "trees", "trees" end
        else
            any, from, how = scan_trees(fresh, fresh_points), "trees", "trees"
        end

        if not any then
            -- Character select, a loading screen, or a client without either
            -- talent API. Keep the previous scan rather than blanking the
            -- spec and flipping the profile to a default mid-fight.
            scanned_ok = false
            return false
        end

        source = from
        split = how
        by_name = fresh
        points = fresh_points
        total_points = fresh_points[1] + fresh_points[2] + fresh_points[3]

        local best, best_tab = -1, 0
        for tab = 1, 3 do
            if fresh_points[tab] > best then
                best, best_tab = fresh_points[tab], tab
            end
        end
        dominant_tab = total_points > 0 and best_tab or 0

        scanned_ok = true
        last_scan = core.time()

        log.fmt("debug", "talents: %d/%d/%d (%s)",
            points[1], points[2], points[3],
            dominant_tab > 0 and TAB_NAME[dominant_tab] or "none")

        ctx.emit("jambix.aio.talents_changed", {
            arms = points[1], fury = points[2], prot = points[3],
            dominant = dominant_tab,
        })
        return true
    end

    --- Rank of a talent by English name, 0 when untaken or unknown.
    ---@param name string
    ---@return integer
    function M.rank(name)
        local row = by_name[name:lower()]
        return row and row.rank or 0
    end

    ---@param name string
    ---@return boolean
    function M.has(name)
        return M.rank(name) > 0
    end

    --- How many ranks a talent has, 0 when it is not in the trees read. A
    --- client may change it: Forever's Improved Slam has 2 ranks, Era's 5.
    --- Trait clients list bought talents only, so there it is known once one
    --- rank is taken.
    ---@param name string
    ---@return integer
    function M.max_rank(name)
        local row = by_name[name:lower()]
        return row and row.max_rank or 0
    end

    ---@return integer arms
    ---@return integer fury
    ---@return integer prot
    function M.points()
        return points[1], points[2], points[3]
    end

    ---@return integer tab 1 Arms, 2 Fury, 3 Protection, 0 when untalented.
    function M.dominant()
        return dominant_tab
    end

    ---@return string
    function M.spec_name()
        if dominant_tab == 0 then
            -- Trait talents whose trees could not be told apart: bought,
            -- just not attributable to a tab.
            if source == "traits" and next(by_name) ~= nil then return "Traits (no tree split)" end
            return "Untalented"
        end
        return TAB_NAME[dominant_tab]
    end

    -- NOTE: profile suggestion lives on each CLASS MODULE now (its `suggest`
    -- field). The warrior-specific version that used to sit here was dead
    -- code the moment the engine went class-agnostic.

    function M.stats()
        return {
            ok = scanned_ok,
            arms = points[1], fury = points[2], prot = points[3],
            total = total_points,
            spec = M.spec_name(),
            source = source,
            split = split,
            tree1 = TAB_NAME[1], tree2 = TAB_NAME[2], tree3 = TAB_NAME[3],
            age = core.time() - last_scan,
            known = (function()
                local n = 0
                for _ in pairs(by_name) do n = n + 1 end
                return n
            end)(),
        }
    end

    -- Talent changes do not raise a dedicated event on Classic; a respec shows
    -- up as SPELLS_CHANGED, and spending a point while levelling is picked up
    -- by the periodic scan.
    ctx.on("jambix.aio.spells_changed", function() M.scan() end)
    ctx.every(5.0, function() M.scan() end)

    -- Forever only: a trait loadout announces itself, but in bursts -- one
    -- TRAIT_CONFIG_UPDATED per node while it applies -- so the events ask for
    -- ONE scan half a second later rather than running one each.
    if TRAITS then
        local rescan_pending = false
        local function rescan_soon()
            if rescan_pending then return end
            rescan_pending = true
            ctx.after(0.5, function()
                rescan_pending = false
                M.scan()
            end)
        end
        ctx.on("jcore.game_event.TRAIT_CONFIG_UPDATED", rescan_soon)
        ctx.on("jcore.game_event.PLAYER_TALENT_UPDATE", rescan_soon)
    end

    M.scan()

    return M
end

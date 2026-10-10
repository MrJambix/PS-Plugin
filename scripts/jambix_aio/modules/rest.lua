-- Jambix AIO / rest -- eat and drink between pulls.
--
-- The single biggest time sink while levelling is sitting at half health
-- because nobody pressed the food. It is also the thing most likely to kill a
-- hardcore character, because the alternative to eating is pulling at 50%.
--
-- WHAT MAKES THIS NON-TRIVIAL
-- Eating is cancelled by damage, by moving, and by entering combat, so a
-- naive "use food when low" fires once per second forever and never actually
-- eats. The state machine here is therefore about NOT re-using: once the
-- eating aura is seen, nothing is pressed again until it is gone.
--
-- Consumables are found by FLAG through the shipped inventory helper
-- (is_food_or_drink), not by name, so this works on a non-English client --
-- unlike most of the rest of the plugin, which is an honest asymmetry rather
-- than an oversight.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat

    local M = {}

    local inventory_helper
    do
        local ok, mod = pcall(require, "common/utility/inventory_helper")
        if ok then inventory_helper = mod end
    end

    -- Aura names that mean "already eating or drinking". Checked by name
    -- because these are auras rather than spells we cast.
    local CONSUMING = { "Food", "Drink", "Refreshment", "Well Fed" }

    local food_id, drink_id = nil, nil
    local food_name, drink_name = nil, nil
    local last_use = 0
    local last_scan = 0

    --- Finds one food and one drink from the bags.
    ---
    --- The helper's flag is the whole point: a name match would need a list of
    --- every food item in two expansions and would still miss conjured items.
    local function scan()
        if not inventory_helper then return end

        local ok, list = pcall(inventory_helper.get_current_consumables_list, inventory_helper)
        if not ok or type(list) ~= "table" then return end

        food_id, drink_id, food_name, drink_name = nil, nil, nil, nil

        for i = 1, #list do
            local row = list[i]
            if row and row.is_food_or_drink and row.item then
                local ok_id, item_id = pcall(row.item.get_item_id, row.item)
                local ok_name, name = pcall(row.item.get_name, row.item)
                if ok_id and item_id and item_id > 0 then
                    local lowered = (ok_name and name or ""):lower()
                    -- The helper does not split food from drink, and the
                    -- distinction matters: drinking restores mana, eating
                    -- restores health, and a class with no mana bar wants only
                    -- one of them. Fall back to the name for the split, and
                    -- treat anything unrecognised as food.
                    if lowered:find("water", 1, true) or lowered:find("drink", 1, true)
                        or lowered:find("juice", 1, true) or lowered:find("milk", 1, true)
                        or lowered:find("wine", 1, true) or lowered:find("ale", 1, true) then
                        if not drink_id then drink_id, drink_name = item_id, name end
                    else
                        if not food_id then food_id, food_name = item_id, name end
                    end
                end
            end
        end

        last_scan = core.time()
    end

    ctx.every(10.0, scan)
    ctx.on("jcore.combat.leave", scan)
    scan()

    ---@return boolean
    function M.consuming()
        local player = units.player()
        if not player then return false end
        local ok, auras = pcall(player.get_auras, player)
        if not ok or type(auras) ~= "table" then return false end
        for i = 1, #auras do
            local aura = auras[i]
            local name = aura and aura.buff_name
            if type(name) == "string" then
                for j = 1, #CONSUMING do
                    if name:find(CONSUMING[j], 1, true) then return true end
                end
            end
        end
        return false
    end

    local function mana_fraction(player)
        local max_mana = P.power_max("MANA")
        if max_mana <= 0 then return 1 end
        return P.power("MANA") / max_mana
    end

    --- How far to recover TO, rather than how low to start.
    ---
    --- THE QUESTION THE OLD THRESHOLDS ANSWERED WRONG. "Drink below 50%" says
    --- when to sit down and nothing at all about when to stand up, so the
    --- character either drinks to full every time -- minutes of a levelling
    --- session spent watching a bar that was already enough -- or stands up at
    --- the same 50% that made it sit.
    ---
    --- What matters is whether the NEXT pull is affordable. modules/auto.lua
    --- already derives that from what a cast actually costs and how long a
    --- fight actually lasts, so recovery aims at it directly and stops there.
    ---@return number mana fraction
    ---@return number health fraction
    local function recover_to()
        -- The conserve line is "enough to finish a fight". Standing up exactly
        -- there leaves nothing for the one after it, so the target sits
        -- comfortably above rather than level with it.
        local mana = P.tune("res_conserve_power", 35) * 1.6
        local health = P.tune("res_conserve_hp", 55) * 1.3

        return math.max(0.30, math.min(0.98, mana)),
               math.max(0.30, math.min(0.98, health))
    end

    M.recover_to = recover_to

    --- Are we still below what the next pull wants?
    ---
    --- Published so the rest of the plugin can hold off rather than pull at
    --- half a mana bar and need to sit down again immediately.
    ---@return boolean
    ---@return string reason
    function M.recovering()
        local player = units.player()
        if not player or player:is_dead() then return false, "" end
        if combat.in_combat() then return false, "" end
        if not P.opt("rest_enabled", false) then return false, "" end

        local want_mana, want_health = recover_to()
        local hp = units.health_fraction(player)
        local mana = mana_fraction(player)

        if P.power_max("MANA") > 0 and mana < want_mana then
            return true, string.format("mana at %.0f%%, a pull wants %.0f%%",
                mana * 100, want_mana * 100)
        end
        if hp < want_health then
            return true, string.format("health at %.0f%%, a pull wants %.0f%%",
                hp * 100, want_health * 100)
        end
        return false, ""
    end

    local function tick()
        if not P.master_on() then return end
        if not P.opt("rest_enabled", false) then return end

        local player = units.player()
        if not player then return end
        if player:is_dead() or player:is_mounted() then return end
        if combat.in_combat() then return end

        -- Moving cancels it, so pressing food while running is a guaranteed
        -- no-op that would also block the cooldown below.
        if player:is_moving() then return end

        -- Already eating: the whole state machine is this line. Without it the
        -- item is re-used every tick, each use cancelling the last, and the
        -- character never actually finishes a bite.
        if M.consuming() then return end

        local now = core.time()
        if (now - last_use) < 3 then return end

        local hp = units.health_fraction(player)
        local mana = mana_fraction(player)
        local want_mana, want_health = recover_to()

        -- A BANDAGE FIRST, where health is the problem. It is free, it is
        -- faster than food, and nothing in the plugin was using it -- the item
        -- was already being found in the bags for the hardcore emergency path
        -- and then only ever used at death's door.
        if hp < want_health and P.opt("rest_bandage", true) and P.hardcore then
            if P.hardcore.use_item("bandage", "recovering between pulls") then
                last_use = now
                ctx.emit("jambix.aio.rest", { kind = "bandage", hp = hp })
                return
            end
        end

        -- Drink first when both are low: mana regenerates more slowly, so it
        -- is the one that decides how soon the next pull can happen.
        if drink_id and P.power_max("MANA") > 0 and mana < want_mana then
            last_use = now
            pcall(core.input.use_item, drink_id)
            log.fmt("debug", "drinking %s at %.0f%% mana, aiming for %.0f%%",
                drink_name or "?", mana * 100, want_mana * 100)
            ctx.emit("jambix.aio.rest", { kind = "drink", mana = mana })
            return
        end

        if food_id and hp < want_health then
            last_use = now
            pcall(core.input.use_item, food_id)
            log.fmt("debug", "eating %s at %.0f%% health, aiming for %.0f%%",
                food_name or "?", hp * 100, want_health * 100)
            ctx.emit("jambix.aio.rest", { kind = "food", hp = hp })
            return
        end
    end

    ctx.tick(tick, { interval = 1.0, deferrable = true })

    function M.stats()
        return {
            food = food_name,
            drink = drink_name,
            consuming = M.consuming(),
            helper = inventory_helper ~= nil,
            age = core.time() - last_scan,
        }
    end

    return M
end

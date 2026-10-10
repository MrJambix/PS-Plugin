-- Jambix AIO / classes / shaman

return function(P, H, CS)
    local book = H.book

    local function low_mana(s) return H.power_fraction(s) < 0.2 end

    local function shield_missing(s)
        return not (H.buff_up(s.player, "Lightning Shield")
            or H.buff_up(s.player, "Water Shield")
            or H.buff_up(s.player, "Earth Shield"))
    end

    --- Totems are dropped once and left. Re-dropping one mid-fight for a
    --- twenty-second gain is a global cooldown the rotation needs elsewhere,
    --- so the lockouts here are long on purpose.
    local function totem_wanted(s)
        return s.in_combat
    end

    -- MAELSTROM WEAPON (1.77.3; Forever, Enhancement; Season of Discovery's
    -- rune): melee hits stack it on you (408505, not the talent's 408498), up
    -- to 5, each taking a fifth off the next Lightning Bolt's cast and cost.
    -- At 5 the Bolt is instant and free: worth a global cooldown in melee.
    local MAELSTROM = { 408505 }
    local function maelstrom_full(s)
        return H.debuff_stacks(s.player, MAELSTROM) >= 5
    end

    -- WEAPON IMBUES (1.80.0). Every Enhancement guide starts with one --
    -- Windfury Weapon from 30, Flametongue or Rockbiter before -- and the
    -- shaman cast none. Out of combat, on a main hand whose temporary enchant
    -- has run out or has under two minutes left; the best one trained. A read
    -- that cannot tell (no weapon, no answer) casts nothing.
    local MAIN_HAND = 16             -- INVSLOT_MAINHAND, 1-based
    local IMBUES = { "Windfury Weapon", "Flametongue Weapon", "Rockbiter Weapon" }

    local function imbue_left()
        local inv = P.ctx and P.ctx.inventory
        if not (inv and inv.equipped_at) then return nil end
        local ok_row, row = pcall(inv.equipped_at, MAIN_HAND)
        local item = ok_row and type(row) == "table" and row.object or nil
        if not item then return nil end
        local ok, ms = pcall(item.item_enchant_expiration, item)
        if not ok or type(ms) ~= "number" then return nil end
        return ms / 1000
    end

    local function best_imbue()
        for i = 1, #IMBUES do
            if book.known(IMBUES[i]) then return IMBUES[i] end
        end
        return nil
    end

    -- An imbue lasts 30 minutes. Pressed in the last 25 and still read as
    -- nearly gone, either the press failed or the read cannot see it (it was
    -- never measured on Forever): wait 5 minutes before the next, rather than
    -- an imbue every few seconds between pulls.
    local IMBUE_TRUSTED_FOR, IMBUE_RETRY = 1500, 300

    local function imbue_rule(name)
        return { name, function(s)
            if s.in_combat or best_imbue() ~= name then return false end
            local left = imbue_left()
            if left == nil or left >= 120 then return false end
            local since = H.since_cast(name)
            return not (since < IMBUE_TRUSTED_FOR and since < IMBUE_RETRY)
        end, self = true, upkeep = 10 }
    end

    -- FIRE NOVA IS A SPELL ON FOREVER (1.80.0): it makes your fire totem
    -- explode (10 yards round the totem), so it needs one down. Every guide
    -- uses it on packs. A totem is taken to be up for its shortest life after
    -- we dropped it (Searing 30 s at rank 1, Magma 20 s), and it was dropped
    -- where we stand, so the mobs it should hit are the ones round us.
    -- Flametongue Totem has no duration since client 1.60.1.70291 (it stays
    -- until another fire totem replaces it); 2 minutes is kept for it all
    -- the same, because it stays where it was dropped while the fight moves.
    local FIRE_TOTEMS = { ["Searing Totem"] = 30, ["Magma Totem"] = 20, ["Flametongue Totem"] = 120 }
    local function fire_totem_up()
        for name, lasts in pairs(FIRE_TOTEMS) do
            if H.since_cast(name) < lasts then return true end
        end
        return false
    end
    local function fire_nova_wanted(s)
        return s.in_combat and fire_totem_up() and H.spread(s, 2)
    end

    --- Party members under `line` within 40 yards, you included.
    local function party_hurt(line)
        local group = P.ctx and P.ctx.group
        if not (group and group.count_below) then return 0 end
        local ok, n = pcall(group.count_below, line, 40)
        return ok and tonumber(n) or 0
    end

    local profiles = {}

    profiles.leveling = {
        label = "Levelling (Enhancement)",
        power = "MANA",
        rules = {
            imbue_rule("Windfury Weapon"),
            imbue_rule("Flametongue Weapon"),
            imbue_rule("Rockbiter Weapon"),
            { "Lightning Shield", shield_missing, self = true, upkeep = 20 },
            { "Healing Wave", function(s)
                local line = P.derived and P.derived("rot_defensive_hp", 40) or 0.40
                return s.in_combat and (s.hp < line + 0.05 or (H.bleeding() and s.hp < 0.6))
            end, self = true, upkeep = 2 },
            { "Searing Totem", totem_wanted, self = true, upkeep = 45 },
            { "Stormstrike", function() return true end },
            { "Flame Shock", function(s) return H.dot_worth_it(s, "Flame Shock", 10) end,
              upkeep = 2 },
            { "Fire Nova", fire_nova_wanted, self = true, upkeep = 4 },
            { "Earth Shock", function(s) return not low_mana(s) end, upkeep = 1 },
            { "Lightning Bolt", function(s)
                -- Only as a pull or when we cannot reach: at melee range the
                -- cast time is worth less than the swings it replaces --
                -- unless Maelstrom Weapon has made it instant.
                return (not s.in_combat and not s.player:is_moving()) or maelstrom_full(s)
            end },
        },
    }

    profiles.enhancement = {
        label = "Enhancement",
        power = "MANA",
        rules = {
            imbue_rule("Windfury Weapon"),
            imbue_rule("Flametongue Weapon"),
            imbue_rule("Rockbiter Weapon"),
            { "Lightning Shield", shield_missing, self = true, upkeep = 20 },
            { "Strength of Earth Totem", totem_wanted, self = true, upkeep = 120 },
            { "Windfury Totem", totem_wanted, self = true, upkeep = 120 },
            { "Stormstrike", function() return true end },
            { "Lava Lash", function() return true end },
            { "Flame Shock", function(s) return H.dot_worth_it(s, "Flame Shock", 10) end,
              upkeep = 2 },
            { "Lightning Bolt", maelstrom_full },
            { "Fire Nova", fire_nova_wanted, self = true, upkeep = 4 },
            { "Earth Shock", function() return true end, upkeep = 1 },
            { "Magma Totem", function(s) return H.spread(s, 3) end, self = true, upkeep = 30 },
        },
    }

    profiles.elemental = {
        label = "Elemental",
        power = "MANA",
        rules = {
            { "Water Shield", shield_missing, self = true, upkeep = 20 },
            -- Forever moved Water Shield into the Restoration tree, so an
            -- Elemental there kept no shield at all (1.80.0). Lightning
            -- Shield goes up whenever Water Shield cannot.
            { "Lightning Shield", shield_missing, self = true, upkeep = 20 },
            { "Searing Totem", totem_wanted, self = true, upkeep = 45 },
            { "Flame Shock", function(s) return H.dot_worth_it(s, "Flame Shock", 10) end,
              upkeep = 2 },
            { "Fire Nova", fire_nova_wanted, self = true, upkeep = 4 },
            -- Lava Burst (Forever, Elemental, 40; Season of Discovery's rune):
            -- fire on a 10 s cooldown, harder while your Flame Shock burns.
            { "Lava Burst", function(s) return not s.player:is_moving() end },
            { "Chain Lightning", function(s)
                return H.spread(s, 2) and not s.player:is_moving()
            end },
            { "Lightning Bolt", function(s) return not s.player:is_moving() end },
            { "Earth Shock", function(s) return s.player:is_moving() end, upkeep = 1 },
        },
    }

    profiles.restoration = {
        label = "Restoration",
        power = "MANA",
        rules = {
            { "Water Shield", shield_missing, self = true, upkeep = 20 },
            { "Mana Spring Totem", totem_wanted, self = true, upkeep = 120 },
            { "Earth Shield", function(s)
                return s.ally ~= nil and not H.buff_up(s.ally, "Earth Shield")
            end, heal = true, upkeep = 30 },
            { "Riptide", function(s)
                return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_renew_hp", 85)
            end, heal = true, upkeep = 2 },
            -- THE BIG HEAL COMES BEFORE THE FAST ONE (1.80.0). Lesser Healing
            -- Wave (below 50%) sat above Healing Wave (below 40%) and Chain
            -- Heal, and heals keep their list order, so the other two fired
            -- only when Lesser Healing Wave could not. Now: Chain Heal when
            -- two or more are hurt, Healing Wave below the big line while
            -- standing, Lesser Healing Wave below the fast line (or moving).
            { "Chain Heal", function(s)
                local line = P.optpct("rot_heal_flash_hp", 50)
                return s.ally ~= nil and s.ally_hp < line and party_hurt(line + 0.2) >= 2
                    and not s.player:is_moving()
            end, heal = true },
            { "Healing Wave", function(s)
                return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_big_hp", 40)
                    and not s.player:is_moving()
            end, heal = true },
            { "Lesser Healing Wave", function(s)
                return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_flash_hp", 50)
            end, heal = true },
            { "Flame Shock", function(s)
                return P.opt("rot_heal_dps", true) and s.in_combat
                    and H.dot_worth_it(s, "Flame Shock", 10)
            end, upkeep = 2 },
            { "Lightning Bolt", function(s)
                return P.opt("rot_heal_dps", true) and s.in_combat and not s.player:is_moving()
            end },
        },
    }

    return {
        key = "shaman",
        label = "Shaman",
        trees = { "Elemental", "Enhancement", "Restoration" },
        dispels = {
            { spell = "Cure Poison",  types = { "POISON" } },
            { spell = "Cure Disease", types = { "DISEASE" } },
        },
        buffs = {},
        icon = "bolt",
        heal_capable = true,
        -- This class has something that hits more than one target, so the
        -- field module may plan an AoE. Declared rather than inferred: a rule
        -- predicate is a closure and cannot be asked what it would do.
        aoe_capable = true,
        -- THE BURST SEQUENCE, in order. modules/burst.lua fires these off the
        -- global cooldown lane when it decides a window is worth opening, and
        -- pulls the trinkets and the offensive racial into the same few
        -- seconds so they multiply each other instead of landing on three
        -- different mobs. `duration` is what the window is held open for.
        -- Rage of the Farseer: Forever's Enhancement talent, attack speed for
        -- 25 s. Elemental Mastery is Era's; Forever has none.
        burst = {
            { spell = "Rage of the Farseer", duration = 25 },
            { spell = "Elemental Mastery", duration = 6 },
        },

        class_name = "SHAMAN",
        power = "MANA",
        interrupts = { "Earth Shock" },
        defensives = { "Shamanistic Rage", "Stoneclaw Totem", "Healing Wave" },
        escapes = { "Ghost Wolf", "Earthbind Totem", "Frost Shock" },
        profiles = profiles,
        profile_order = { "leveling", "enhancement", "elemental", "restoration" },
        suggest = function(t)
            local elemental, enhancement, resto = t.points()
            local total = elemental + enhancement + resto
            if total < 20 then return "leveling" end
            if enhancement >= elemental and enhancement >= resto then return "enhancement" end
            if elemental >= resto then return "elemental" end
            return "restoration"
        end,
    }
end

-- Jambix AIO / classes / priest
--
-- Healing profiles use the engine's `heal` rule shape: the target is the
-- lowest-health ally in range, resolved once per tick, so a heal rule reads as
-- a threshold rather than as a search.

return function(P, H, CS)
    local book = H.book

    local function low_mana(s) return H.power_fraction(s) < 0.2 end

    -- WEAKENED SOUL (1.77.3) is no spell a priest casts, so asking for it by
    -- name read your spellbook and never found it: the shield was offered
    -- again for the whole 15 s it cannot go, and refused. By its id (6788,
    -- Era and Forever), from any priest -- anyone's blocks a shield.
    local WEAKENED_SOUL = { 6788 }

    local function fortitude_wanted(s)
        return not s.in_combat and not H.buff_up(s.player, "Power Word: Fortitude")
    end

    --- Shield is worth a global cooldown when something is actually hitting
    --- us, and not while the Weakened Soul debuff would waste it.
    local function shield_wanted(s)
        -- A shield before the damage, not after (1.35.x; was an 80% slider):
        -- something on us and health below the top, or health draining.
        return s.in_combat and ((s.hp < 0.85 and (s.on_me or 0) > 0) or H.bleeding())
            and not H.buff_up(s.player, "Power Word: Shield")
            and not H.debuff_up_any(s.player, WEAKENED_SOUL)
    end

    local profiles = {}

    profiles.leveling = {
        label = "Levelling (Shadow)",
        power = "MANA",
        rules = {
            { "Power Word: Fortitude", fortitude_wanted, self = true, upkeep = 30 },
            { "Inner Fire", function(s)
                return not H.buff_up(s.player, "Inner Fire")
            end, self = true, upkeep = 20 },
            { "Power Word: Shield", shield_wanted, self = true, upkeep = 3 },
            -- Both halves wait for the last Renew to run out (1.80.0). Lua binds
            -- `and` before `or`, so the "not up" check guarded only the bleed:
            -- under 65% Renew was pressed every 3 s while it ticked.
            { "Renew", function(s)
                return (s.hp < 0.65 or (H.bleeding() and s.hp < 0.85))
                    and not H.buff_up(s.player, "Renew")
            end, self = true, upkeep = 3 },
            { "Shadow Word: Pain", function(s) return H.dot_worth_it(s, "Shadow Word: Pain", 10) end,
              upkeep = 2, dot = true },
            { "Devouring Plague", function(s) return H.dot_worth_it(s, "Devouring Plague", 12) end,
              upkeep = 2, dot = true },
            { "Mind Blast", function() return true end },
            -- Penance (Forever, Discipline, 30; Season of Discovery's rune):
            -- holy damage on its 12 s cooldown, and no cast to stand still for.
            { "Penance", function(s) return s.target ~= nil end, upkeep = 2, channel = true },
            { "Shadow Word: Death", function(s) return H.execute_phase(s, 0.2) end, upkeep = 1 },
            { "Mind Flay", function(s)
                return not s.player:is_moving() and H.filler_ok(s)
            end, channel = true },
            -- The guides are explicit that a levelling priest wins by RECOVERING
            -- faster rather than killing faster, and the wand is what makes that
            -- possible: damage for no mana at all. It is the finisher, not a
            -- last resort, so it sits above the mana-spending filler.
            { "Shoot", H.wand_wanted, upkeep = 3 },
            { "Smite", function(s)
                return not s.player:is_moving() and H.filler_ok(s)
            end },
        },
    }

    profiles.shadow = {
        label = "Shadow",
        power = "MANA",
        rules = {
            { "Power Word: Fortitude", fortitude_wanted, self = true, upkeep = 30 },
            { "Inner Fire", function(s)
                return not H.buff_up(s.player, "Inner Fire")
            end, self = true, upkeep = 20 },
            { "Shadowform", function(s)
                return not s.in_combat and not H.buff_up(s.player, "Shadowform")
            end, self = true, upkeep = 30 },
            { "Power Word: Shield", shield_wanted, self = true, upkeep = 3 },
            -- Vampiric Touch first: it is the mana return for the whole group
            -- and the longest DoT, so it wants to be up before anything else.
            { "Vampiric Touch", function(s) return H.dot_worth_it(s, "Vampiric Touch", 12) end,
              upkeep = 2, dot = true },
            { "Shadow Word: Pain", function(s) return H.dot_worth_it(s, "Shadow Word: Pain", 10) end,
              upkeep = 2, dot = true },
            { "Devouring Plague", function(s) return H.dot_worth_it(s, "Devouring Plague", 12) end,
              upkeep = 2, dot = true },
            { "Mind Blast", function() return true end },
            { "Shadow Word: Death", function(s) return H.execute_phase(s, 0.2) end, upkeep = 1 },
            { "Mind Flay", function(s) return not s.player:is_moving() end, channel = true },
        },
    }

    --- Healing priority. Shield, then the heal whose size matches the hole:
    --- a Greater Heal on a 90% target is most of a mana bar wasted.
    local heal_rules = {
        { "Power Word: Fortitude", fortitude_wanted, self = true, upkeep = 30 },
        { "Inner Fire", function(s)
            return not H.buff_up(s.player, "Inner Fire")
        end, self = true, upkeep = 20 },
        { "Power Word: Shield", function(s)
            return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_shield_hp", 70)
                and not H.debuff_up_any(s.ally, WEAKENED_SOUL)
                and not H.buff_up(s.ally, "Power Word: Shield")
        end, heal = true, upkeep = 2 },
        -- Forever's talents (and the runes of Season of Discovery), each on its
        -- own cooldown: Penance heals as it does damage, instantly, every 12 s;
        -- Prayer of Mending waits on someone hurt in a fight and jumps on.
        { "Penance", function(s)
            return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_flash_hp", 50)
        end, heal = true, upkeep = 2, channel = true },
        { "Prayer of Mending", function(s)
            return s.in_combat and s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_renew_hp", 85)
        end, heal = true, upkeep = 2 },
        -- THE BIG HEAL BEFORE THE FAST ONE (1.80.0). Heals keep their list
        -- order, and Flash Heal (below 50%) sat above Greater Heal and Heal
        -- (below 40%), so those fired only when Flash Heal could not. Below
        -- the big line and standing, the big heal; otherwise Flash Heal.
        { "Greater Heal", function(s)
            return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_big_hp", 40)
                and not s.player:is_moving()
        end, heal = true },
        { "Heal", function(s)
            return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_big_hp", 40)
                and not s.player:is_moving()
        end, heal = true },
        { "Flash Heal", function(s)
            return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_flash_hp", 50)
        end, heal = true },
        { "Renew", function(s)
            return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_renew_hp", 85)
                and not H.buff_up(s.ally, "Renew")
        end, heal = true, upkeep = 2 },
        -- Nothing hurt: contribute damage rather than stand still.
        { "Shadow Word: Pain", function(s)
            return P.opt("rot_heal_dps", true) and s.in_combat
                and H.dot_worth_it(s, "Shadow Word: Pain", 10)
        end, upkeep = 2, dot = true },
        { "Smite", function(s)
            return P.opt("rot_heal_dps", true) and s.in_combat and not s.player:is_moving()
        end },
    }

    profiles.holy = { label = "Holy", power = "MANA", rules = heal_rules }
    profiles.discipline = { label = "Discipline", power = "MANA", rules = heal_rules }

    return {
        key = "priest",
        label = "Priest",
        wand_capable = true,
        trees = { "Discipline", "Holy", "Shadow" },
        dispels = {
            { spell = "Abolish Disease", types = { "DISEASE" } },
            { spell = "Cure Disease",    types = { "DISEASE" } },
            { spell = "Dispel Magic",    types = { "MAGIC" } },
        },
        buffs = {
            { spell = "Prayer of Fortitude", replaces = { "Power Word: Fortitude" } },
            { spell = "Power Word: Fortitude", replaces = { "Prayer of Fortitude" } },
            { spell = "Divine Spirit" },
        },
        icon = "heart",
        heal_capable = true,
        -- THE BURST SEQUENCE, in order. modules/burst.lua fires these off the
        -- global cooldown lane when it decides a window is worth opening, and
        -- pulls the trinkets and the offensive racial into the same few
        -- seconds so they multiply each other instead of landing on three
        -- different mobs. `duration` is what the window is held open for.
        burst = {
            { spell = "Power Infusion", duration = 15 },
            { spell = "Inner Focus", duration = 6 },
        },

        class_name = "PRIEST",
        power = "MANA",
        interrupts = { "Silence" },
        defensives = { "Power Word: Shield", "Desperate Prayer", "Fade" },
        -- Confounding Flash (Forever, 10): every enemy close by confused until
        -- it is hit, on a 2 min cooldown.
        escapes = { "Psychic Scream", "Confounding Flash", "Fade" },
        profiles = profiles,
        profile_order = { "leveling", "shadow", "holy", "discipline" },
        suggest = function(t)
            local discipline, holy, shadow = t.points()
            local total = discipline + holy + shadow
            if total < 20 then return "leveling" end
            if shadow >= holy and shadow >= discipline then return "shadow" end
            if holy >= discipline then return "holy" end
            return "discipline"
        end,
    }
end

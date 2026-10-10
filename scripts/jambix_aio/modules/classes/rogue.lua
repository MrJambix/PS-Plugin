-- Jambix AIO / classes / rogue
--
-- Energy and combo points. The one rule that matters more than any other is
-- that a finisher at five points is worth far more than one at two, so nothing
-- spends points early.

return function(P, H, CS)
    local book = H.book

    local function cp(s) return s.combo or 0 end

    -- THE FIGHT DECIDES WHEN TO SPEND (1.35.x): five points, or fewer when the
    -- target will not live long enough for the rest -- points left on a corpse
    -- are damage never dealt.
    local function finisher_ready(s)
        local points = cp(s)
        if points >= 5 then return true end
        local ttd = s.ttd or 0
        if s.target and ((s.thp or 1) < 0.15 or (ttd > 0 and ttd < 4)) then return points >= 2 end
        if s.target and ttd > 0 and ttd < 7 then return points >= 3 end
        return false
    end

    --- A finisher that is a buff on you: up first, and refreshed before it
    --- drops rather than after.
    local function finisher_buff_wanted(s, name)
        if cp(s) < 1 then return false end
        local remaining = H.buff_remaining(s.player, name)
        if remaining > 3 then return false end
        -- At one or two points a refresh is fine; from a standing start, wait
        -- for a real one.
        return remaining > 0 or cp(s) >= 2
    end

    --- Slice and Dice is the highest-value thing a levelling rogue does with
    --- combo points: it is a damage multiplier on every swing.
    local function snd_wanted(s) return finisher_buff_wanted(s, "Slice and Dice") end

    --- VENOM (1.77.3; Forever, Assassination, 40): a finisher that raises
    --- your poisons' damage and how often they land, for 9 to 21 s by combo
    --- points -- the Slice and Dice of a poison build, kept up the same way,
    --- in a fight. Envenom is Season of Discovery's; Forever has Venom.
    local function venom_wanted(s)
        return s.in_combat and finisher_buff_wanted(s, "Venom")
    end

    --- AUTO-STEALTH (1.61.0). Players: "anytime i get any where close to a
    --- enemy even if im just walking around it auto stealth". Both halves of
    --- 1.46.0's rule did that: the sneak (a hostile close enough to notice
    --- us), and the opener for any target in 40 yd -- which auto-target had
    --- picked while the player only walked by. So it is a choice now, on the
    --- Rogue page, and the default stealths only before an opener the
    --- rotation is going to make (H.stealth_wanted, rotation.lua).
    local STEALTH_NEVER, STEALTH_OPENER, STEALTH_NEAR = 1, 2, 3
    local STEALTH_MODES = { "Never", "Only before an opener", "Before an opener and near enemies" }
    local function stealth_wanted(s)
        if H.buff_up(s.player, "Stealth") then return false end
        local mode = CS and CS.opt("stealth_mode", STEALTH_OPENER) or STEALTH_OPENER
        if mode == STEALTH_NEVER then return false end
        if mode == STEALTH_NEAR then return (H.stealth_wanted(s)) end
        return (H.stealth_wanted(s, { engaging = true, no_sneak = true }))
    end

    local function stealth_opener(s)
        return not s.in_combat and H.buff_up(s.player, "Stealth")
    end

    local profiles = {}

    profiles.leveling = {
        label = "Levelling",
        power = "ENERGY",
        rules = {
            { "Stealth", stealth_wanted, self = true, upkeep = 5 },
            { "Ambush", stealth_opener },
            { "Cheap Shot", stealth_opener },
            { "Slice and Dice", snd_wanted, self = true, upkeep = 1 },
            { "Eviscerate", finisher_ready },
            { "Sinister Strike", function() return true end },
        },
    }

    profiles.combat = {
        label = "Combat",
        power = "ENERGY",
        rules = {
            { "Stealth", stealth_wanted, self = true, upkeep = 5 },
            { "Ambush", stealth_opener },
            { "Blade Flurry", function(s)
                return H.bursting() and H.spread(s, 2)
            end, self = true, upkeep = 10 },
            { "Slice and Dice", snd_wanted, self = true, upkeep = 1 },
            -- Rupture beats Eviscerate on anything that will live long enough
            -- to take the whole bleed.
            { "Rupture", function(s)
                return finisher_ready(s) and H.dot_worth_it(s, "Rupture", 12)
            end, upkeep = 2, dot = true },
            { "Eviscerate", finisher_ready },
            { "Sinister Strike", function() return true end },
        },
    }

    profiles.assassination = {
        label = "Assassination",
        power = "ENERGY",
        rules = {
            { "Stealth", stealth_wanted, self = true, upkeep = 5 },
            { "Ambush", stealth_opener },
            { "Cold Blood", function(s)
                return H.bursting() and finisher_ready(s)
            end, self = true, upkeep = 5 },
            { "Slice and Dice", snd_wanted, self = true, upkeep = 1 },
            { "Venom", venom_wanted, self = true, upkeep = 1 },
            { "Rupture", function(s)
                return finisher_ready(s) and H.dot_worth_it(s, "Rupture", 12)
            end, upkeep = 2, dot = true },
            { "Envenom", finisher_ready },
            { "Eviscerate", finisher_ready },
            { "Mutilate", function() return true end },
            { "Sinister Strike", function() return true end },
        },
    }

    profiles.subtlety = {
        label = "Subtlety",
        power = "ENERGY",
        rules = {
            { "Stealth", stealth_wanted, self = true, upkeep = 5 },
            { "Ambush", stealth_opener },
            { "Premeditation", stealth_opener, self = true, upkeep = 5 },
            { "Slice and Dice", snd_wanted, self = true, upkeep = 1 },
            { "Rupture", function(s)
                return finisher_ready(s) and H.dot_worth_it(s, "Rupture", 12)
            end, upkeep = 2, dot = true },
            { "Eviscerate", finisher_ready },
            { "Hemorrhage", function() return true end },
            { "Sinister Strike", function() return true end },
        },
    }

    return {
        key = "rogue",
        label = "Rogue",
        trees = { "Assassination", "Combat", "Subtlety" },
        buffs = {},
        icon = "dagger",
        -- This class has something that hits more than one target, so the
        -- field module may plan an AoE. Declared rather than inferred: a rule
        -- predicate is a closure and cannot be asked what it would do.
        aoe_capable = true,
        -- THE BURST SEQUENCE, in order. modules/burst.lua fires these off the
        -- global cooldown lane when it decides a window is worth opening, and
        -- pulls the trinkets and the offensive racial into the same few
        -- seconds so they multiply each other instead of landing on three
        -- different mobs. `duration` is what the window is held open for.
        burst = {
            { spell = "Adrenaline Rush", duration = 15 },
        },

        settings = function(s)
            s:dropdown("stealth_mode", "Stealth by itself", STEALTH_MODES, STEALTH_OPENER)
            s:label("Only before an opener: when the rotation is about to open on the")
            s:label("target (start fights is on, the engage key is held, or you hit it).")
            s:label("Near enemies also stealths whenever a hostile could notice you.")
        end,

        class_name = "ROGUE",
        power = "ENERGY",
        interrupts = { "Kick", "Gouge" },
        defensives = { "Evasion" },
        escapes = { "Vanish", "Sprint", "Blind", "Gouge" },
        profiles = profiles,
        profile_order = { "leveling", "combat", "assassination", "subtlety" },
        suggest = function(t)
            local assassination, combat, subtlety = t.points()
            local total = assassination + combat + subtlety
            if total < 20 then return "leveling" end
            if combat >= assassination and combat >= subtlety then return "combat" end
            if assassination >= subtlety then return "assassination" end
            return "subtlety"
        end,
    }
end

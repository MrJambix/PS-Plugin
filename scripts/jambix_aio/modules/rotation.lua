-- Jambix AIO / rotation -- the class-agnostic priority engine.
--
-- THE BUG THIS MODULE EXISTS TO FIX
-- The rotation used to BE the warrior rotation. It ran whatever class you were
-- on, so a warlock got a warrior priority list: every rule failed to resolve,
-- nothing ever fired, and nothing said why. Class is now read from the player
-- and decides which rule set loads, and an unsupported class says so out loud
-- instead of running a rotation for somebody else's class.
--
-- WHAT IS GENERIC AND WHAT IS NOT
-- Everything that is the same for every class lives here: the situation
-- snapshot, the priority walk, the off-GCD lane, interrupts, defensives,
-- healing target selection, form maintenance, and the deadlock breaker.
--
-- A class module supplies only data: which profiles exist, what is in each
-- priority list, and which abilities count as an interrupt, a defensive or an
-- escape. It gets a helper table and never touches the engine's internals.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat
    local book, talents = P.spellbook, P.talents
    local targeting = P.targeting

    local M = {}

    -- --- class identity -----------------------------------------------------

    -- Registry filled by main.lua: class key -> module factory result.
    M.classes = {}

    local CLASS_FALLBACK_IDS = {
        WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5,
        DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8, WARLOCK = 9, MONK = 10,
        DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
    }

    --- Numeric class id for an enum name, via the enums table where it exists.
    ---
    --- The literals above are WoW's own class ids and are stable across every
    --- version this runs on, but the enums table is asked first so a client
    --- that renumbers them still resolves.
    ---@param name string
    ---@return integer|nil
    local function class_id_for(name)
        local enums = P.enums
        if enums and enums.class_id and type(enums.class_id[name]) == "number" then
            return enums.class_id[name]
        end
        return CLASS_FALLBACK_IDS[name]
    end

    local detected_class = nil     -- enum name, e.g. "WARLOCK"
    local detected_id = nil

    --- Reads the player's class. Cached: it cannot change within a session,
    --- and the read happens on every rotation tick otherwise.
    ---@return string|nil name
    function M.detect_class()
        if detected_class then return detected_class end

        local player = units.player()
        if not player then return nil end

        local ok, id = pcall(player.get_class, player)
        if not ok or type(id) ~= "number" or id == 0 then return nil end

        for name in pairs(CLASS_FALLBACK_IDS) do
            if class_id_for(name) == id then
                detected_class, detected_id = name, id
                log.fmt("info", "class detected: %s (%d)", name, id)
                ctx.emit("jambix.aio.class_detected", name, id)
                return detected_class
            end
        end

        log.fmt("warn", "unrecognised class id %d", id)
        return nil
    end

    --- The class module for the player's class, or nil when unsupported.
    ---@return table|nil
    function M.active_class()
        local name = M.detect_class()
        if not name then return nil end
        return M.classes[name]
    end

    -- --- helpers handed to class modules ------------------------------------

    local H = {}

    -- WHOSE DEBUFF IS IT? A damage-over-time spell snapshots the caster's
    -- spell power when it lands and ticks at that strength for its whole
    -- duration, so a second warlock's Corruption on the same mob is worth
    -- nothing to us. Reading it as ours means never applying our own -- and
    -- inside a burst window, where the point is to land the set while a
    -- trinket is up, it means landing none of it.
    --
    -- The filter fails open: units.aura accepts any aura whose caster it
    -- cannot determine, so a build that does not populate the field behaves
    -- exactly as before rather than re-applying everything for ever.
    ---@return string|nil
    local function my_guid()
        if not P.opt("rot_own_dots_only", true) then return nil end
        local player = units.player()
        if not player then return nil end
        local ok, guid = pcall(player.get_guid, player)
        return ok and guid or nil
    end

    -- AN AURA THAT IS NO SPELL OF YOURS (1.77.3). These read a name through
    -- your own spellbook, so an aura that is not a spell you can cast never
    -- matched: Weakened Soul, Improved Scorch's Fire Vulnerability, a
    -- Frostbite freeze, the Arcane Blast stack (400573, not the cast's
    -- 400574). Each now also takes a list of aura ids, from the client's tables.
    ---@param name string|integer[]
    ---@return integer[]|nil
    local function aura_ids(name)
        if type(name) == "table" then return name end
        return book.ids(name)
    end

    function H.debuff_up(target, name)
        local ids = aura_ids(name)
        if not ids or not target then return false end
        return units.has_aura(target, ids, my_guid())
    end

    function H.debuff_remaining(target, name)
        local ids = aura_ids(name)
        if not ids or not target then return 0 end
        return units.aura_remaining(target, ids, my_guid())
    end

    function H.debuff_stacks(target, name)
        local ids = aura_ids(name)
        if not ids or not target then return 0 end
        return units.aura_stacks(target, ids, my_guid())
    end

    --- Anyone else's version of this debuff, regardless of who cast it.
    --- A few rules genuinely want this -- a raid debuff only needs to be up
    --- once, no matter whose it is.
    function H.debuff_up_any(target, name)
        local ids = aura_ids(name)
        if not ids or not target then return false end
        return units.has_aura(target, ids)
    end

    function H.buff_up(unit, name)
        local ids = aura_ids(name)
        if not ids or not unit then return false end
        return units.has_aura(unit, ids)
    end

    function H.buff_remaining(unit, name)
        local ids = aura_ids(name)
        if not ids or not unit then return 0 end
        return units.aura_remaining(unit, ids)
    end

    -- A DOT THE CLIENT DOES NOT SHOW (1.74.0). The live log (Forever, a
    -- five-man) had Serpent Sting on the same Lesser Stone Golem every two to
    -- four seconds, three times in five seconds on one: the cast went out, the
    -- client confirmed it, and the sting never appeared on the mob, so every
    -- look found it missing. An immunity says so in the combat log, which
    -- Forever does not give (react/learn.lua cannot hear it). So the landing
    -- watch below (did it land?) now feeds this, from casts the client
    -- CONFIRMED only -- a refused press says nothing about the mob:
    --   once     the cast is taken as ticking for NOSHOW_HOLD seconds
    --   twice    on one mob, while it HAS shown on other mobs this session:
    --            that mob does not take it (immune) and is left alone
    --   a name   two mobs of one name like that, and none that took it: every
    --            mob of that name is left alone from its first look (logged)
    -- A spell that has shown on no mob this session is never left off: the
    -- client may not show it at all, and then it is re-cast on its duration.
    local noshow = {
        rows = {},                -- the landing watch: { name, id, guid, mob, at, confirmed }
        guid = {},                -- guid .. "|" .. spell -> { n, at }
        mob = {},                 -- mob name .. "|" .. spell -> { guids, n, shown, said }
        seen = {},                -- spell -> times it showed on a mob this session
        count = 0,
    }
    local NOSHOW_HOLD, NOSHOW_LEAVE = 12, 2

    --- Why this DoT is not cast again on `target` though it is not there to
    --- see, or nil.
    ---@param target game_object
    ---@param name string
    ---@return string|nil
    function H.dot_noshow(target, name)
        local guid = target and units.guid and units.guid(target)
        if not guid then return nil end
        local now = core.time()
        local shows = (noshow.seen[name] or 0) > 0
        local e = noshow.guid[guid .. "|" .. name]
        if e then
            if shows and e.n >= NOSHOW_LEAVE then
                return string.format("%s never shows on this mob (%d casts)", name, e.n)
            end
            if (now - e.at) < NOSHOW_HOLD then
                return string.format("cast %.0fs ago; the client does not show it", now - e.at)
            end
        end
        if shows then
            local mob = units.name and units.name(target)
            local m = type(mob) == "string" and mob ~= "" and noshow.mob[mob .. "|" .. name] or nil
            if m and not m.shown and m.n >= NOSHOW_LEAVE then
                return string.format("learned: %s never shows on %s", name, mob)
            end
        end
        return nil
    end

    --- The landing watch's verdict on one cast (reap_landings).
    ---@param row table { name, guid, mob, at, confirmed }
    ---@param shown boolean
    function H.dot_verdict(row, shown)
        local name = row.name
        local key = row.guid .. "|" .. name
        local mkey = row.mob and (row.mob .. "|" .. name) or nil
        if shown then
            noshow.seen[name] = (noshow.seen[name] or 0) + 1
            noshow.guid[key] = nil
            if mkey then
                local m = noshow.mob[mkey] or { guids = {}, n = 0 }
                noshow.mob[mkey] = m
                if not m.shown and m.said then
                    log.fmt("info", "%s showed on %s after all: cast on it again", name, row.mob)
                end
                m.shown = true
            end
            return
        end
        if not row.confirmed then return end
        local e = noshow.guid[key]
        if not e then
            e = { n = 0 }
            noshow.guid[key] = e
            noshow.count = noshow.count + 1
        end
        e.n, e.at = e.n + 1, row.at
        local shows = (noshow.seen[name] or 0) > 0
        local m = nil
        if mkey then
            m = noshow.mob[mkey] or { guids = {}, n = 0 }
            noshow.mob[mkey] = m
            if not m.guids[row.guid] then m.guids[row.guid], m.n = true, m.n + 1 end
        end
        if shows and m and not m.shown and not m.said and m.n >= NOSHOW_LEAVE then
            m.said = true
            log.fmt("info", "%s never shows on %s (%d of them, each cast confirmed): left off that mob"
                .. " -- immune, as far as this client says", name, row.mob, m.n)
        elseif shows and e.n == NOSHOW_LEAVE and not (m and m.said) then
            log.fmt("info", "%s does not show on %s after %d confirmed casts: left off it", name,
                row.mob or "the target", e.n)
        elseif e.n == 1 then
            log.fmt("debug", "%s cast on %s and confirmed, but not on it: taken as ticking for %ds",
                name, row.mob or "the target", NOSHOW_HOLD)
        end
        -- A long session meets many mobs: forget the ones long gone.
        if noshow.count > 256 then
            local now = core.time()
            for k, v in pairs(noshow.guid) do
                if (now - (v.at or now)) > 300 then
                    noshow.guid[k] = nil
                    noshow.count = noshow.count - 1
                end
            end
        end
    end

    --- A DoT is worth refreshing when it is nearly gone AND the target will
    --- live long enough to take the ticks. Every damage-over-time rule in
    --- every class module goes through this rather than restating it.
    ---@param s table
    ---@param name string
    ---@param min_ttd? number
    function H.dot_worth_it(s, name, min_ttd)
        if not s.target then return false end
        if H.debuff_remaining(s.target, name) > 2 then return false end
        if H.dot_noshow(s.target, name) then return false end
        return s.ttd > (min_ttd or P.tune_secs("rot_rend_min_ttd", 10))
    end

    ---@param s table
    ---@param pct? number fraction, default 0.2
    function H.execute_phase(s, pct)
        return s.target ~= nil and s.thp > 0 and s.thp <= (pct or 0.2)
    end

    --- Resource as a 0..1 fraction. Lets a mana rule read the same as a rage
    --- one without each class module knowing the power id.
    ---@param s table
    function H.power_fraction(s)
        if s.power_max <= 0 then return s.power_unknown or 0 end
        return s.power / s.power_max
    end

    --- Are we channelling this particular spell right now?
    ---
    --- is_channelling_spell only says that SOMETHING is being channelled,
    --- which is not enough when the answer decides whether to let a channel
    --- finish or talk over it. The active channel's id is compared against
    --- every known rank, because a channel started at rank 3 reports rank 3.
    --- H.channelling, BOUNDED. Every caller of the raw test is deciding
    --- whether to hold something back, so a latched is_channelling_spell would
    --- hold it back for ever. Past the longest channel in the game this is not
    --- a channel any more, whatever the client says.
    local LONGEST_CHANNEL = 30.0
    local channel_since = {}

    ---@param name string
    ---@return boolean
    function H.channel_active(name)
        if not H.channelling(name) then
            channel_since[name] = nil
            return false
        end

        local now = core.time()
        if not channel_since[name] then channel_since[name] = now end
        if (now - channel_since[name]) > LONGEST_CHANNEL then
            log.once("warn", "channel_stuck_" .. name, string.format(
                "%s has read as channelling for over %.0fs; ignoring that",
                name, LONGEST_CHANNEL))
            return false
        end
        return true
    end

    ---@param name string
    ---@return boolean
    function H.channelling(name)
        local player = units.player()
        if not player then return false end

        local ok, channelling = pcall(player.is_channelling_spell, player)
        if not ok or not channelling then return false end

        -- JCore's channel id (1.6.0): on Forever, where the read is sometimes
        -- garbage (3,739,147,998 in the API recorder), an id no spell can have
        -- is nil. A channel we cannot identify is left alone -- not clipped as
        -- "not ours".
        local ok_id, active
        local player_service = P.ctx and P.ctx.player
        if player_service and player_service.channel_spell_id then
            ok_id, active = pcall(player_service.channel_spell_id)
        else
            ok_id, active = pcall(player.get_active_channel_spell_id, player)
        end
        if not ok_id or type(active) ~= "number" then
            -- The client says we are channelling but will not say what. Take
            -- it at its word rather than guessing: a caller asking this
            -- question is deciding whether to interrupt a channel, and the
            -- safe answer when the channel is unidentifiable is to leave it
            -- alone.
            return true
        end

        local ids = book.ids(name)
        if not ids then return false end
        for i = 1, #ids do
            if ids[i] == active then return true end
        end
        return false
    end

    -- --- talents ------------------------------------------------------------
    --
    -- Some talents change WHAT YOU DO, not how hard it hits, and those are the
    -- ones a rotation has to know about. Improved Drain Soul turns Drain Soul
    -- from "a finisher that happens to give a shard" into the warlock's main
    -- source of mana, which reorders the whole execute window. Nightfall turns
    -- Shadow Bolt into an instant that must be consumed before it expires.
    --
    -- Read by NAME, like spells, and for the same reason: a talent id table
    -- would have to be right for Vanilla and TBC separately and would rot.

    ---@param name string
    ---@return integer rank, 0 when untaken
    function H.talent(name)
        if not talents or not talents.rank then return 0 end
        local ok, rank = pcall(talents.rank, name)
        if not ok or type(rank) ~= "number" then return 0 end
        return rank
    end

    ---@param name string
    ---@return boolean
    function H.has_talent(name)
        return H.talent(name) > 0
    end

    -- --- the field ----------------------------------------------------------
    --
    -- What is happening out there, for rules that should behave differently
    -- when the fight changes shape. The judgement lives in modules/field.lua;
    -- these are the thin passthroughs that let a rule read as a sentence.

    --- May this ability fire? False for anything the active class has listed
    --- as key-gated whose key is not currently held.
    ---
    --- Checked in the priority walk AND in the escape lists, because "never
    --- unless I ask" has to mean never -- an ability that is held back in the
    --- rotation and then fired automatically while breaking contact is not
    --- held back.
    ---
    --- A class may gate one on a switch instead of a key (1.8.1, the
    --- hunter's Disengage): a function there, asked, and only a plain true
    --- lets it through.
    ---@param name string
    ---@return boolean
    function H.key_allows(name)
        local class_module = P.rotation and P.rotation.active_class()
        local gated = class_module and class_module.key_gated or nil
        if not gated then return true end

        local key = gated[name]
        if not key then return true end
        if type(key) == "function" then
            local ok, on = pcall(key)
            return ok and on == true
        end

        return P.key_armed ~= nil and P.key_armed(key)
    end

    ---@return string BURN | AOE | CONTROL | SURVIVE | FLEE
    function H.plan()
        local field = P.field
        return field and field.plan() or "BURN"
    end

    ---@return boolean
    function H.in_trouble()
        local field = P.field
        return field ~= nil and field.in_trouble()
    end

    ---@return boolean
    function H.winning()
        local field = P.field
        return field == nil or field.winning()
    end

    --- True when more enemies have joined since the fight started, or are
    --- walking into it. The cue for crowd control and for cooldowns, and the
    --- thing that separates "a hard fight" from "a fight that is about to
    --- become a different fight".
    ---@return boolean
    function H.escalating()
        local field = P.field
        return field ~= nil and (field.escalating() or select(2, field.counts()) > 0)
    end

    ---@return integer engaged
    ---@return integer inbound
    function H.counts()
        local field = P.field
        if not field then return 0, 0 end
        return field.counts()
    end

    --- Should damage be SPREAD rather than concentrated?
    ---
    --- `minimum` is the spell's own property -- Cleave reaches two targets,
    --- Multi-Shot three, Flamestrike more -- and stays with the rule that
    --- declares it. What the field adds is a veto: killing one mob removes
    --- its damage from the fight, and an AoE that leaves everything standing
    --- removes none of it, so against a short pack of elites concentrating
    --- wins even though the count says otherwise.
    ---@param s table
    ---@param minimum? integer
    ---@return boolean
    -- --- range, the way the client measures it (1.58.1) ---------------------
    --
    -- HITBOX TO HITBOX, NOT CENTRE TO CENTRE. A spell's range -- a shot's
    -- reach, and the eight-yard minimum that makes the hunter's dead zone --
    -- is measured between the edges of the two hitboxes: both combat reaches
    -- come off the centre distance. A melee swing reaches max(5, both reaches
    -- + 4/3) from the centre. JCore measures it that way (spells.in_range);
    -- the hunter's rules measured the centre against eight and five, so Auto
    -- Shot was wanted at 8 to 11 yards, which the client still calls too
    -- close ("too close at 10.2y", the Forever trace; "3 presses, 0 shots at
    -- 9.5 to 11 yards", session 26), and Raptor Strike was not wanted against
    -- a big mob the client lets us hit from six or seven.
    local DEFAULT_REACH = 1.5       -- a player's combat reach; a mob's when the client does not say

    local function reach_of(unit)
        local r = unit and units.combat_reach and units.combat_reach(unit) or 0
        if type(r) ~= "number" or r <= 0 then return DEFAULT_REACH end
        return r
    end

    --- Hitbox to hitbox: what a spell's range is measured by. Without the
    --- core's combat reach, the centre distance (as before 1.58.1).
    ---@param unit game_object
    ---@param distance? number its centre distance, when already read
    ---@return number
    function H.gap(unit, distance)
        if not unit then return math.huge end
        local d = distance or units.distance(unit)
        if not units.combat_reach then return d end
        return d - reach_of(unit) - reach_of(units.player())
    end

    --- The centre distance a melee swing reaches this unit from.
    ---@param unit game_object
    ---@return number
    function H.melee_range(unit)
        if not unit or not units.combat_reach then return 5 end
        return math.max(5, reach_of(unit) + reach_of(units.player()) + 4 / 3)
    end

    --- In melee with this unit, as the client counts it.
    ---@param unit game_object
    ---@param distance? number its centre distance, when already read
    ---@return boolean
    function H.in_melee(unit, distance)
        if not unit then return false end
        return (distance or units.distance(unit)) <= H.melee_range(unit)
    end

    --- Should the melee swing be started on the target (1.76.1)? A warrior's
    --- or a rogue's strikes start it; a paladin before Crusader Strike has
    --- nothing that does, so nothing ever did. The live report (Forever, a
    --- level 9 paladin): "it uses blessing using also Seal when out of
    --- combat however it does not hitting the mobs". A seal, a Judgement
    --- every ten seconds and no white damage, which at that level is nearly
    --- all of it.
    ---
    --- Asked by an `Attack` rule marked `direct`: the cast service sends it
    --- as the client's START, which cannot switch a running swing off. Only
    --- in melee reach, only while the swing is off, never at a mob held by
    --- crowd control that damage breaks. Holding fire (1.75.0) is the
    --- walk's own gate, so nothing is pulled by this.
    ---@param s table
    ---@return boolean
    function H.melee_start_wanted(s)
        local target = s.target
        if not target or not s.player then return false end
        if not H.in_melee(target, s.distance) then return false end
        local react = P.react
        if react and react.out_of_fight and react.out_of_fight(target) then return false end
        local ok, attacking = pcall(s.player.is_auto_attacking, s.player)
        return not (ok and attacking == true)
    end

    function H.spread(s, minimum)
        -- WHERE IT LANDS, NOT WHO IS NEAR US (1.56.0). The reaction engine
        -- counts what this area spell would actually hit -- around the target
        -- for a Multi-Shot, around us for an Arcane Explosion -- and answers 0
        -- beside a mob we crowd-controlled or an idle one it would pull. Two
        -- in reach makes it a candidate; the scoring then weighs it against
        -- the single-target spell by what each does (react/adapt.lua).
        local react = P.react
        local reach = (react and react.reach_count and s.asking) and react.reach_count(s.asking, s) or nil
        if reach then
            if reach < math.min(minimum or 2, 2) then return false end
        elseif (s.melee or 0) < (minimum or 2) then
            return false
        end
        local field = P.field
        if not field then return true end
        return field.spread_ok()
    end

    -- --- stealth: when it is worth it ------------------------------------------
    --
    -- STEALTH IS A DECISION, NOT A DEFAULT (1.46.0). The rogue's rule was "out
    -- of combat and not stealthed: Stealth", so every run between quest givers
    -- went at stealth speed and food was cancelled the moment it started. It
    -- pays in two cases, and the world says which:
    --   the opener  a target we are going for -- attackable, not fighting yet,
    --               within OPEN_RANGE: the approach is unseen and the opener
    --               (Ambush, Cheap Shot, Garrote) is there when we arrive
    --   the sneak   a hostile (red, not yellow) that is not fighting us, close
    --               enough to notice us: its aggro reach is about twenty yards
    --               at our level, a yard more or less per level between us, and
    --               a grey one does not come at all. Going past it unseen is a
    --               fight not started
    -- Never mounted, eating or drinking, and never with nothing about: then it
    -- is only slower.
    local OPEN_RANGE = 40
    local SNEAK_MARGIN = 5          -- yards beyond its reach: we are walking towards it
    local SNEAK_ROWS = 8            -- the nearest few, at most
    local GREY_BELOW = 6            -- levels under ours that no longer come at us

    local function level_of(unit)
        local ok, level = pcall(unit.get_level, unit)
        return ok and tonumber(level) or nil
    end

    --- Is Stealth worth pressing now, and why.
    ---@param s table the snapshot
    ---@return boolean
    ---@return string reason
    --- `opts` (1.61.0), for the rogue's Auto-stealth setting; none is the
    --- 1.46.0 behaviour:
    ---   opts.engaging   the opener only for a target the rotation will open
    ---                   on (s.hold_fire not set): auto-target picks a mob in
    ---                   range while the player only walks past it
    ---   opts.no_sneak   no stealth for a hostile that is merely close
    ---@param opts? { engaging?: boolean, no_sneak?: boolean }
    function H.stealth_wanted(s, opts)
        local player = s.player
        if not player or s.in_combat then return false, "in combat" end
        local ok_m, mounted = pcall(player.is_mounted, player)
        if ok_m and mounted then return false, "mounted" end
        if H.buff_up(player, "Food") or H.buff_up(player, "Drink")
            or (P.rest and P.rest.consuming and P.rest.consuming()) then
            return false, "eating or drinking"
        end

        -- The opener: the target we are going for.
        local target = s.target
        if target and target ~= player and target:is_valid() and not target:is_dead()
            and (s.distance or math.huge) <= OPEN_RANGE
            and not (opts and opts.engaging and s.hold_fire) then
            local ok_a, attackable = pcall(player.can_attack, player, target)
            local row = s.target_row
            if ok_a and attackable and not (row and (row.in_combat or row.engaged)) then
                return true, "going for the target"
            end
        end

        -- The sneak: a hostile close enough to notice us.
        if opts and opts.no_sneak then return false, "nothing to open on" end
        local mine = level_of(player)
        local rows = s.enemies or {}
        for i = 1, math.min(#rows, SNEAK_ROWS) do
            local row = rows[i]
            local unit = row and row.obj
            if unit and not row.engaged and not row.in_combat and not row.dead
                and unit:is_valid() and not unit:is_dead() then
                local ok_h, hostile = pcall(player.is_enemy_with, player, unit)
                if ok_h and hostile then
                    local theirs = level_of(unit)
                    local diff = (theirs and mine) and (theirs - mine) or 0
                    if diff > -GREY_BELOW then
                        local reach = math.max(5, math.min(40, 20 + diff)) + SNEAK_MARGIN
                        if (row.dist or math.huge) <= reach then
                            return true, "a hostile close enough to notice"
                        end
                    end
                end
            end
        end
        return false, "nothing about"
    end

    --- The nearly-dead enemy running away. It is about to reach whatever is
    --- behind it and come back with company, which makes a snare on it worth
    --- more than any amount of damage elsewhere.
    ---@return game_object|nil
    function H.runner()
        local field = P.field
        return field and field.runner() or nil
    end

    --- The engaged enemy whose cast finishes soonest.
    ---@return game_object|nil
    function H.enemy_caster()
        local field = P.field
        return field and field.caster() or nil
    end

    --- Are we inside a burst window?
    ---
    --- The one question a cooldown rule should ask. It replaces nine copies of
    --- `P.opt("rot_use_cooldowns") and s.in_combat and s.ttd > 15` -- where the
    --- 15 was 20 on a mage and 25 on a shaman for no reason anyone could have
    --- stated, and where nothing made the three cooldowns overlap.
    ---
    --- modules/burst.lua decides when to open one and fires the ramp
    --- abilities, the trinkets and the racials into it. A rule that wants to
    --- spend something expensive only has to know that the window is open.
    ---@return boolean
    function H.bursting()
        local burst = P.burst
        return burst ~= nil and burst.open()
    end

    ---@return number seconds left in the window, 0 when closed
    function H.burst_remaining()
        local burst = P.burst
        return burst and burst.remaining() or 0
    end

    -- --- resources ----------------------------------------------------------
    --
    -- Thin passthroughs so a class rule reads as a sentence. The judgement
    -- lives in modules/resources.lua; restating any of it here would put the
    -- spiral logic in two places, which is how it got wrong the first time.

    ---@param cost number fraction of max health the trade costs
    ---@param opts? table
    ---@return boolean ok
    ---@return string reason
    function H.may_trade_health(cost, opts)
        local res = P.resources
        if not res then return false, "no resource tracking" end
        return res.may_trade_health(cost, opts)
    end

    ---@return string
    function H.posture()
        local res = P.resources
        return res and res.posture() or "HEALTHY"
    end

    ---@return boolean
    function H.should_recover()
        local res = P.resources
        return res ~= nil and res.should_recover()
    end

    ---@return boolean
    function H.bleeding()
        local res = P.resources
        return res ~= nil and res.bleeding()
    end

    -- --- damage over time, as a set ------------------------------------------
    --
    -- A DoT rule knows when to refresh ITSELF. What no single rule could see is
    -- whether the target is carrying the whole set, and that is the question a
    -- burst window turns on: in Classic a DoT snapshots your spell power when
    -- it is APPLIED and ticks at that strength for its full duration, so a DoT
    -- landed inside a trinket window keeps hitting like that long after the
    -- trinket has gone. Spending those seconds on a filler instead trades a
    -- whole duration of amplified ticks for one amplified cast.
    --
    -- Hence: everything on the target first, fillers after. Rules opt in by
    -- carrying `dot = true`, declared rather than inferred -- a rule predicate
    -- is a closure and there is no asking a closure what it would have done.

    --- Names of the active profile's damage-over-time rules.
    ---@return string[]
    function H.dot_names()
        local rot = P.rotation
        local class_module = rot and rot.active_class()
        if not class_module then return {} end
        local profile = rot.active_profile and rot.active_profile(class_module)
        if not profile or not profile.rules then return {} end

        local out = {}
        for i = 1, #profile.rules do
            local rule = profile.rules[i]
            if rule.dot then out[#out + 1] = rule[1] end
        end
        return out
    end

    --- How many of them are missing from the target.
    ---
    --- ONLY SPELLS WE ACTUALLY KNOW COUNT. A level 20 warlock has no Siphon
    --- Life and never will until it is talented, and counting it as "missing"
    --- would hold the filler back for the whole session -- the fail-closed
    --- shape that has caused every silent rotation in this plugin so far.
    ---@param s table
    ---@return integer
    function H.dots_pending(s)
        local names = H.dot_names()
        if #names == 0 then return 0 end

        -- ACROSS EVERYTHING ENGAGED, not just what is selected. Three mobs
        -- each carrying a Corruption is three times the damage for the same
        -- three global cooldowns, so a set that is only complete on the
        -- current target is not complete.
        -- ONLY WHAT WE WILL ACTUALLY APPLY. With spreading switched off the
        -- set is complete when the target carries it, and counting the rest of
        -- the pack would hold the filler waiting for casts that are never
        -- coming.
        local list = s.engaged_units
        if P.spread_allowed and not P.spread_allowed() then list = nil end
        if not list or #list == 0 then
            if not s.target then return 0 end
            list = { s.target }
        end

        local missing = 0
        for u = 1, #list do
            local unit = list[u]
            if unit and unit:is_valid() and not unit:is_dead() then
                for i = 1, #names do
                    local name = names[i]
                    if book.known(name) and not H.debuff_up(unit, name) then
                        missing = missing + 1
                    end
                end
            end
        end
        return missing
    end

    --- May a filler be cast, or is the set still going up?
    ---
    --- Only inside a burst window. Outside one the ordinary priority list is
    --- already correct: the DoTs sit above the filler, so they go up first
    --- anyway, and forcing the filler to wait would mean standing still
    --- through a global cooldown whenever a DoT was merely out of range.
    ---@param s table
    ---@return boolean
    function H.filler_after_dots(s)
        if not H.bursting() then return true end

        local pending_dots = H.dots_pending(s)
        if pending_dots == 0 then return true end

        -- AND THE HOLD IS BOUNDED, because an unbounded one is a silent
        -- rotation waiting to happen. A DoT that is missing because it is out
        -- of range, or because the target is immune to it, or because a rank
        -- exists that we cannot actually land, would otherwise keep the filler
        -- shut for the whole window -- thirty seconds of a character standing
        -- still, which is exactly the failure this plugin keeps rediscovering.
        --
        -- The bound is the time it should TAKE: one global cooldown per DoT
        -- still to go up, and one spare. Past that the set is not going up,
        -- whatever the reason, and damage is better than waiting.
        local elapsed = P.burst and (P.burst.window_length() - P.burst.remaining()) or 0
        local allowed = (pending_dots + 1) * 1.5
        if elapsed > allowed then
            log.once("debug", "dot_hold",
                "burst window: stopped waiting for the damage-over-time set")
            return true
        end

        return false
    end

    -- --- wanding ------------------------------------------------------------
    --
    -- A WAND IS A TOGGLE, NOT A CAST. "Shoot" starts auto-repeat; pressing it
    -- again STOPS it. A priority rule that requests it every tick therefore
    -- flickers the wand on and off and never lands a single shot -- the same
    -- shape of bug as re-pressing food, and just as invisible.
    --
    -- is_current_spell is the client's own answer to "is this auto-repeat
    -- running", which is the only reliable way to tell.
    --
    -- Why it matters more than it looks: levelling a caster is a mana game
    -- rather than a damage race. The guides are explicit that a priest wins by
    -- recovering faster and sitting down less, and the wand is what makes that
    -- possible -- damage for no mana at all.

    -- THE SAME SHAPE TWICE. A hunter's Auto Shot is the wand's twin: a toggle
    -- spell that auto-repeats, that a second press STOPS, and that the client
    -- reports through the same is_current_spell reading with the same trust
    -- problem. So the press logic below is built per spell name, and the
    -- wand is one instance of it; hunter.lua asks for another.

    local RANGED_SLOT = 18   -- INVSLOT_RANGED, where a wand lives

    --- The press logic for one auto-repeat spell.
    ---
    --- THE READING WE CANNOT TAKE AT FACE VALUE. Whether this build reports
    --- auto-repeat through is_current_spell is not something the stub
    --- promises, and a wrong answer deadlocks in one direction or the other:
    ---
    ---   stuck FALSE -> the rotation presses the toggle forever, and since
    ---     each press STOPS it, it fires almost never. That is exactly what
    ---     the live log showed for the wand: Shoot dispatched every three
    ---     seconds for two minutes. Handled by the time lockout in
    ---     press_wanted.
    ---
    ---   stuck TRUE -> the rotation never presses (it believes the toggle is
    ---     already running) and, for the wand, never casts filler either. A
    ---     caster that does nothing at all.
    ---
    --- The discriminator for the second case is that WE never pressed. We
    --- only ever press when the reading is false, so a nonzero pressed_at is
    --- proof the reading is not stuck true -- and an "active" that persists
    --- with no press behind it is either the player's own doing or a lie.
    --- The player's own toggle stops within a fight; a lie does not. So it
    --- gets a grace period, and past that the reading is abandoned for the
    --- session.
    --- THREE SOURCES, NOT ONE. Whether the toggle is running is read from
    --- is_current_spell, from the unit's own auto-attack flag when the toggle
    --- IS the auto attack (a hunter's Auto Shot), and from the cast stream:
    --- a shot reported within the last swing means it is running whatever
    --- the flags say. Any one of them saying "running" is enough to hold the
    --- press back, because a press on a running toggle stops it -- and that
    --- is the bug a wrong "not running" produces: Auto Shot switching itself
    --- off every few seconds.
    ---
    --- AND A QUIET WINDOW -- FOR A TOGGLE THAT WAS RUNNING. A cast pauses
    --- Auto Shot without stopping it, so a gap in the shots right after an
    --- Aimed Shot is not evidence of anything, and no press goes out within
    --- a swing of a cast of ours. But only when the toggle was seen running
    --- just before that cast: a cast cannot have paused something that was
    --- not on. Without that condition every cast silenced the press for a
    --- full swing, the rotation casts something every global cooldown, and
    --- Auto Shot was never started while there was anything else to do --
    --- which is most of a fight.
    ---
    --- AND THE CALLER'S OWN EVIDENCE. The melee auto attack sets the same
    --- unit flag as Auto Shot, and in Classic starting one stops the other:
    --- after a Wing Clip the flag reads "attacking" and Auto Shot is off. The
    --- caller can see what this cannot -- standing, in range, for longer than
    --- a swing, and no shot -- and passes `stale`, which is believed over the
    --- flags once shots have been observed this session at all.
    ---
    --- ONE SHOT PER PRESS (Forever, `rearm`). The Forever beta's recording
    --- (2026-10-03, a level-3 dwarf hunter) has Auto Shot firing ONCE per
    --- press: the shot is reported the moment it is pressed, the mob drops a
    --- quarter of its health, and then nothing -- three seconds of standing in
    --- range with no second shot, until the kept-on guard's "a swing with no
    --- shot" pressed again at 3.5 s, by which time the wolf was in melee. So
    --- there every shot that went out is the cue for the next press: a START
    --- arms the next swing (or, if the client did keep it running, does
    --- nothing), and a press with no shot after it is tried again every
    --- second and a half. Asked for by the hunter on Forever only; Era never
    --- sets it and runs exactly the path below.
    ---@param name string
    ---@param opts? { auto_attack?: boolean, period?: number, shot_at?: fun(): number, keep_on?: boolean, rearm?: boolean }
    local function make_auto_repeat(name, opts)
        opts = opts or {}
        local R = {
            name = name,
            pressed_at = 0,
            confirmed = false,      -- a press was followed by an active read
            broken = false,         -- "active" with no press behind it, ever
            active_since = 0,
            active_seen = 0,        -- last time the toggle read as running
            last_fired = 0,         -- the toggle's own last reported shot
            last_cast = 0,          -- our last cast of anything else
            period = opts.period or 3.0,   -- one swing, plus slack
            auto_attack = opts.auto_attack == true,
            -- An outside reader of the last real shot (the weave's, which
            -- also reads the swing timer addon), so a shot the cast stream
            -- missed still counts.
            shot_at = type(opts.shot_at) == "function" and opts.shot_at or nil,
            -- THE CLIENT'S OWN ANSWER. The game fires START_AUTOREPEAT_SPELL
            -- when Auto Shot or a wand starts and STOP_AUTOREPEAT_SPELL when
            -- it stops -- the exact state, from the source, with none of the
            -- guesswork below. Once one of those has been seen this session
            -- it is the only reading used: no flags, no quiet window, no
            -- inferred staleness. Everything else here is the fallback for a
            -- build that does not relay them.
            event_state = nil,      -- true running | false stopped | nil never told
            events_seen = false,
            -- KEPT ON. A toggle pressed through the client's auto-attack
            -- START (the hunter's Auto Shot) cannot be switched off by a
            -- press, so a wrong guess costs a press that does nothing and
            -- none of the readings below has to be trusted. See would_press.
            keep_on = opts.keep_on == true,
            starts = nil,           -- does a press START it; nil until asked
            switched_at = 0,        -- the last new target: earlier shots were at another mob
            fresh = false,          -- a new target that has not had its press yet
            -- ONE SHOT PER PRESS (Forever): every shot is followed by a press.
            rearm = opts.rearm == true,
            shots = 0,              -- shots of this toggle seen this session, for readouts
            -- A melee swing stopped it (the hunter's AOE melee weave, back
            -- out of melee, 1.7.6): the next press goes at once, like a new
            -- target's.
            restarting = false,
        }

        --- A melee swing has stopped the toggle: press again as soon as the
        --- caller can shoot, whatever the guard last read.
        function R.restart()
            R.restarting = true
        end

        --- Fed from the game's auto-repeat events.
        ---@param on boolean
        function R.on_autorepeat(on)
            R.event_state = on == true
            R.events_seen = true
            if on then R.active_seen = core.time() end
        end

        --- Seconds since the toggle's last shot was seen, from any source.
        ---@return number
        function R.since_shot()
            if R.shot_at then
                local ok, at = pcall(R.shot_at)
                if ok and type(at) == "number" and at > R.last_fired then R.last_fired = at end
            end
            if R.last_fired == 0 then return math.huge end
            return core.time() - R.last_fired
        end

        --- Has a shot of this toggle been observed at all this session? Until
        --- one has, the absence of shots means nothing.
        ---@return boolean
        function R.shots_seen()
            R.since_shot()
            return R.last_fired > 0
        end

        --- A new target: the toggle stopped when the old one died, so
        --- nothing seen before now says anything about it running, and no
        --- cast since then can have paused it. Calibration is kept.
        function R.forget()
            R.active_seen = 0
            R.last_cast = 0
            R.pressed_at = 0
            R.switched_at = core.time()
            R.fresh = true
        end

        --- Seconds since a shot at the CURRENT target. A shot at the mob
        --- before the switch says nothing about this one: the toggle stops
        --- with its target, and reading that shot as "running" is what kept
        --- Auto Shot off for a whole swing or more after every switch.
        ---@return number
        function R.since_shot_here()
            local since = R.since_shot()
            if R.last_fired < R.switched_at then return math.huge end
            return since
        end

        --- A new target that has not been pressed for yet.
        ---@return boolean
        function R.is_fresh()
            return R.fresh
        end

        --- Does a press go out as the client's START for this attack, which
        --- cannot switch it off? Asked of the same helper the cast service
        --- sends it through, once it is trained.
        ---@return boolean
        function R.starts_safely()
            if R.starts == nil then
                local id = book.id(name)
                if not id then return false end
                local yes = false
                local ok, helper = pcall(require, "common/utility/auto_attack_helper")
                if ok and type(helper) == "table" and type(helper.is_spell_auto_attack) == "function" then
                    local ok_a, answer = pcall(helper.is_spell_auto_attack, helper, id)
                    yes = ok_a and answer == true
                end
                R.starts = yes
            end
            return R.starts
        end

        --- Seconds a shot is taken as proof the toggle is running. A hunter
        --- sets this from the weapon's speed.
        ---@param seconds number
        function R.set_period(seconds)
            if type(seconds) == "number" and seconds > 0.5 then R.period = seconds end
        end

        --- Fed from the cast stream with every cast of ours.
        ---@param spell_id integer
        function R.observe(spell_id)
            local ids = book.ids(name)
            if ids then
                for i = 1, #ids do
                    if ids[i] == spell_id then
                        R.last_fired = core.time()
                        R.shots = R.shots + 1
                        return
                    end
                end
            end
            R.last_cast = core.time()
        end

        --- The client's raw answer, from every source it offers.
        ---@return boolean
        function R.active()
            if R.since_shot() < R.period then return true end

            local id = book.id(name)
            if not id then return false end
            local ok, current = pcall(core.spell_book.is_current_spell, id)
            if ok and current == true then return true end

            if R.auto_attack then
                local player = units.player()
                if player then
                    local ok_a, attacking = pcall(player.is_auto_attacking, player)
                    if ok_a and attacking == true then return true end
                end
            end
            return false
        end

        --- The raw answer, filtered through whether it has earned any trust.
        ---@return boolean
        function R.reads_active()
            if R.events_seen then return R.event_state == true end
            if R.broken then return false end

            if not R.active() then
                R.active_since = 0
                return false
            end

            if R.pressed_at > 0 then
                R.confirmed = true
                R.active_seen = core.time()
                return true
            end

            if R.active_since == 0 then R.active_since = core.time() end
            if (core.time() - R.active_since) > 20 then
                R.broken = true
                log.once("warn", "auto_repeat_" .. name,
                    "the client reports " .. name .. " running but we never "
                    .. "started it and it never stops; ignoring that reading "
                    .. "this session")
                return false
            end
            R.active_seen = core.time()
            return true
        end

        --- True only when pressing would START it. The caller has already
        --- decided it wants the toggle running; this answers whether a press
        --- right now would do that rather than the opposite.
        ---
        --- The time lockout SELF-CALIBRATES: once a press has been followed
        --- by an active reading, the check is known to work on this build
        --- and the lockout shrinks to a short re-arm window. Until then it
        --- stays long, because a false "not active" must never become a
        --- press every tick.
        ---@param recheck number Seconds between presses before calibration.
        ---@param stale? boolean The caller's evidence that it is NOT running.
        ---@return boolean
        function R.press_wanted(recheck, stale)
            if not R.would_press(recheck, stale) then return false end
            R.pressed_at = core.time()
            R.fresh = false
            R.restarting = false
            return true
        end

        --- The same answer as press_wanted, without arming the lockout: a
        --- read for something that wants to know whether the rule WOULD
        --- press if it ran now. The weave asks this before it stops a
        --- running character so the rule can press -- a hold the rule
        --- cannot use is a stutter for nothing.
        ---@param recheck number
        ---@return boolean
        ---@param stale? boolean
        function R.would_press(recheck, stale)
            -- The game has said whether it is running: believe it, and
            -- nothing else. A short gap between presses is all that is left,
            -- so a press whose START has not arrived yet is not repeated.
            if R.events_seen then
                if R.event_state then return false end
                return (core.time() - R.pressed_at) >= 1.0
            end

            -- KEPT ON, and on this client the usual case: the auto-repeat
            -- events above are not in the core's relay list, so they never
            -- arrive. A press is a START that cannot stop it. A new target
            -- gets one straight away -- the toggle stopped with the old one,
            -- or did not follow the switch -- and after that, a swing with
            -- no shot at THIS target while the caller says it could shoot
            -- is another, at most every second and a half. If it was running
            -- after all, the press did nothing.
            if R.keep_on and R.starts_safely() then
                if R.fresh or R.restarting then return true end
                -- One shot per press: the shot that went out after the last
                -- press is the cue for the next one, a quarter of a second
                -- on (the upkeep holds it to one a second). A press that has
                -- had no shot yet is waiting on the swing timer, or was
                -- refused; it is tried again after a second and a half.
                if R.rearm then
                    local now = core.time()
                    local shot = R.since_shot_here()
                    if shot < math.huge and R.last_fired >= R.pressed_at then
                        return shot >= 0.25 and (now - R.pressed_at) >= 0.75
                    end
                    return (now - R.pressed_at) >= 1.5
                end
                if R.since_shot_here() < R.period then return false end
                return (core.time() - R.pressed_at) >= 1.5
            end

            -- The caller's evidence outranks the flags, but only once a shot
            -- has ever been seen: before that, "no shot" is not a reading.
            -- A swing that stopped it (`restarting`) is the same evidence.
            local trusted_stale = (stale == true or R.restarting) and R.shots_seen()

            if not trusted_stale and R.reads_active() then
                return false                            -- pressing again stops it
            end

            local now = core.time()
            -- The quiet window: a cast pauses the toggle, it does not stop
            -- it, and pressing into that pause is what stops it. Only for a
            -- toggle that was running when the cast went out.
            if (now - R.last_cast) < R.period
                and R.active_seen > 0 and (R.last_cast - R.active_seen) < R.period
                and not trusted_stale then
                return false
            end

            local window = R.confirmed and 1.5 or (recheck or 6)
            if trusted_stale then window = math.min(window, 1.5) end
            if (now - R.pressed_at) < window then return false end
            return true
        end

        return R
    end

    local repeaters = {}

    --- The auto-repeat state for a spell, one per name for the session.
    ---@param name string "Shoot", "Auto Shot"
    ---@param opts? { auto_attack?: boolean, period?: number } Used on first ask.
    ---@return table
    function H.auto_repeat(name, opts)
        local r = repeaters[name]
        if not r then
            r = make_auto_repeat(name, opts)
            repeaters[name] = r
        end
        return r
    end

    --- Every cast of ours, from the stream below, so a toggle can tell its
    --- own shots from a pause.
    local function observe_repeat(spell_id)
        for _, r in pairs(repeaters) do r.observe(spell_id) end
    end

    -- The game's own word on the auto-repeat toggle. A character has one
    -- auto-repeat spell that matters (Auto Shot, or a wand's Shoot), so the
    -- event, which names neither, is handed to every repeater.
    local autorepeat_seen = false
    local function on_autorepeat(on)
        if not autorepeat_seen then
            autorepeat_seen = true
            log.info("auto-repeat events are relayed by this client; the toggle state is now exact")
        end
        for _, r in pairs(repeaters) do r.on_autorepeat(on) end
    end
    ctx.on("jcore.game_event.START_AUTOREPEAT_SPELL", function() on_autorepeat(true) end)
    ctx.on("jcore.game_event.STOP_AUTOREPEAT_SPELL", function() on_autorepeat(false) end)

    local wand = H.auto_repeat("Shoot")

    ---@param s table
    ---@return boolean
    function H.has_wand(s)
        -- "Shoot" only exists in the spellbook while a wand is equipped, so
        -- its presence is most of the answer. The slot is checked too because
        -- the book refreshes on a timer and equipping a wand should register
        -- sooner than that.
        if not book.known("Shoot") then return false end
        local ok, row = pcall(s.player.get_item_at_inventory_slot, s.player, RANGED_SLOT)
        return ok and type(row) == "table" and row.object ~= nil
    end

    ---@return boolean
    function H.wand_active()
        return wand.active()
    end

    --- True only when pressing Shoot would START the wand.
    ---@param s table
    ---@return boolean
    function H.wand_wanted(s)
        if not P.opt("rot_use_wand", true) then return false end
        if not s.target then return false end
        if not H.has_wand(s) then return false end
        if s.player:is_moving() then return false end  -- cannot wand while moving
        return wand.press_wanted(P.opt("rot_wand_recheck", 6))
    end

    ---@return boolean confirmed  whether a press was ever seen to take effect
    function H.wand_detection_works()
        return wand.confirmed
    end

    --- May we spend mana on filler right now?
    ---
    --- False while the wand is already doing the work AND mana is the binding
    --- constraint. That is the levelling-caster strategy stated as a rule:
    --- above the threshold, casting kills faster and is worth the mana; below
    --- it, the wand does free damage and the mana bar refills instead.
    ---
    --- It reads the wand through the same filter as wand_wanted, so the two
    --- can never disagree about whether the wand is running -- which is what
    --- made the silent-caster deadlock possible.
    ---@param s table
    ---@return boolean
    function H.filler_ok(s)
        if not P.opt("rot_use_wand", true) then return true end
        if not wand.reads_active() then return true end
        return H.power_fraction(s) > P.tune("rot_wand_below_mana", 60)
    end

    H.P, H.units, H.combat, H.book, H.talents, H.targeting =
        P, units, combat, book, talents, targeting

    M.helpers = H

    -- --- situation ----------------------------------------------------------

    local S = {}
    local active_key = nil      -- the profile the rotation is running (profile selection, below)

    -- JUST STOPPED IS NOT STANDING (1.36.0). The client's moving flag drops for
    -- a frame between two movement keys, and the live log has a Mend Pet
    -- pressed on that frame: "Can't do that while moving". A cast or channel
    -- waits until the character has been still this long.
    local SETTLE = 0.25
    local moved_at = -math.huge

    --- `profile` may override the class resource. A druid is the reason: the
    --- same class reads mana in caster form, rage in bear and energy in cat,
    --- so the resource belongs to the profile rather than the class.
    local function build_situation(class_module, profile)
        local player = units.player()
        if not player then return nil end

        local target = combat.target()
        if target and (not target:is_valid() or target:is_dead()) then target = nil end
        -- AT NO HEALTH IT IS DEAD (1.74.0). The live log (Forever, a
        -- five-man) had a Hunter's Mark at every mob the group killed, each
        -- refused "Your target is dead": the mob's auras are gone the moment
        -- its health is, and the client's dead flag comes a moment later.
        if target and units.health and units.max_health and units.health(target) <= 0
            and units.max_health(target) > 0 then
            target = nil
        end
        if target and not player:can_attack(target) then target = nil end

        S.player = player
        S.target = target
        S.hp = units.health_fraction(player)
        S.thp = target and units.health_fraction(target) or 0
        S.in_combat = combat.in_combat()
        S.ttd = target and combat.time_to_die(target) or 0

        -- Primary resource, whatever the class calls it.
        local resource = (profile and profile.power) or class_module.power
        -- The profile's own bar, for the burst window (1.80.0). Nothing set
        -- this, so burst.lua fell back to the class's power: a druid's MANA
        -- held Berserk back below 35% energy or rage, and closed it below 10%.
        S.profile_power = resource
        S.power = P.power(resource)
        S.power_max = P.power_max(resource)
        -- A bar the client cannot read (mana on Forever) is "no information",
        -- not "empty" -- or dry for a moment after the client said so. JCore
        -- answers nil wherever the read works.
        if P.power_unread then S.power_unknown = P.power_unread(resource) end
        S.combo = P.power("COMBOPOINTS")

        local radius = P.opt("rot_aoe_radius", 8)
        S.melee = targeting.aoe_count(radius)
        S.cluster, S.cluster_centre = targeting.best_cluster(radius)
        S.loose = targeting.loose(P.tune_secs("rot_target_range", 30))
        S.context = targeting.context()

        -- Lowest-health ally in range, for healing rules. Computed once here
        -- rather than per rule.
        S.ally = units.lowest_health_ally(P.tune_secs("rot_heal_range", 40))
        S.ally_hp = S.ally and units.health_fraction(S.ally) or 1

        -- What is actually happening out there. One read per tick: the shape
        -- of the fight, the plan that follows from it, and whether the race
        -- between their health and ours is one we are winning.
        -- Everything in combat with us, weakest first. A damage-over-time
        -- spell belongs on ALL of them, not only on whatever is targeted:
        -- three mobs each carrying a Corruption is three times the damage for
        -- the same three global cooldowns, and it is the entire reason the
        -- class has damage-over-time spells at all.
        S.engaged_units = P.field and P.field.by_weakest() or {}

        -- The add: something engaged with us that is not what we are killing.
        -- Generic because every class with a fear, a root or a nova wants the
        -- same unit, and none of them want the one already being focused.
        S.add = nil
        for i = 1, #S.engaged_units do
            local unit = S.engaged_units[i]
            if unit ~= S.target and unit:is_valid() and not unit:is_dead() then
                S.add = unit
                break
            end
        end

        S.field = P.field and P.field.state or nil
        S.plan = S.field and S.field.plan or "BURN"
        S.shape = S.field and S.field.shape or "IDLE"
        S.engaged = S.field and S.field.count or 0
        S.inbound = S.field and S.field.inbound or 0
        S.winning = S.field == nil or S.field.winning

        -- Resource posture. One read per tick, shared by every rule, so that
        -- a class file asks "can I afford this" instead of re-deriving it.
        S.res = P.resources and P.resources.state or nil
        S.posture = S.res and S.res.posture or "HEALTHY"
        S.fight_left = P.resources and P.resources.fight_left() or math.huge

        S.form = P.forms and P.forms.current() or nil
        S.reclaim = nil

        -- --- awareness ------------------------------------------------------
        --
        -- The core's picture of every hostile -- position, motion, target,
        -- cast, control, threat -- folded into the snapshot, so a rule can
        -- ask "is anything closing on me" or "who is casting, and can it be
        -- stopped" without reading a native. This is the difference between
        -- a rotation that reacts to what it is targeting and one that reacts
        -- to what is happening.
        local enemies = ctx.enemies
        if enemies then
            S.enemies = enemies.all()
            S.enemy_count = enemies.count()
            S.target_row = target and enemies.get(target) or nil
            S.arriving, S.arrives_in = enemies.first_arrival()
            S.caster_row, S.caster_cast = enemies.next_cast(true)
            local on_me, attacking, closing, casting = 0, 0, 0, 0
            for i = 1, S.enemy_count do
                local row = S.enemies[i]
                if row.targeting_me then on_me = on_me + 1 end
                if row.activity == "attacking" then attacking = attacking + 1 end
                if row.activity == "approaching" then closing = closing + 1 end
                if row.casting then casting = casting + 1 end
            end
            S.on_me, S.attacking, S.closing, S.casting_count = on_me, attacking, closing, casting
        else
            S.enemies, S.enemy_count, S.target_row = {}, 0, nil
            S.arriving, S.arrives_in = nil, math.huge
            S.caster_row, S.caster_cast = nil, nil
            S.on_me, S.attacking, S.closing, S.casting_count = 0, 0, 0, 0
        end

        S.distance = target and units.distance(target) or math.huge
        local ok_moving, moving = pcall(player.is_moving, player)
        S.moving = ok_moving and moving == true
        local now_still = core.time()
        if S.moving then moved_at = now_still end
        S.still_for = S.moving and 0 or (now_still - moved_at)

        -- What this character can DO right now, by role, from the catalogue:
        -- the trained slows, interrupts, defensives and so on. Refreshed once
        -- a second; the spellbook does not change faster than that.
        S.can = M.capabilities()
        return S
    end

    M.build_situation = build_situation

    -- --- engagement ---------------------------------------------------------
    --
    -- SELECTING A TARGET IS NOT ATTACKING IT. Auto-targeting picks the mob
    -- that matters; whether the rotation OPENS on it is a separate decision,
    -- and the default answer is no. Out of combat nothing offensive fires
    -- until one of these is true:
    --
    --   * the mob has engaged you or your pet (it is looking at you, or the
    --     threat table says it is in combat with you)
    --   * you attacked it yourself (auto attack is on)
    --   * the engage key is held, or the "start fights" switch is on
    --
    -- The pet reads the same answer before it is sent in, because a pet in
    -- assist mode charging whatever is targeted is the same auto-pull by
    -- another route.

    --- Is auto-loot working a corpse in reach (world.looting, 1.57.1)? A
    --- pull opened then cancels the press under way and blocks the next
    --- until that fight is over, so the "start fights" switch and the
    --- class's own opener wait for it. The engage key, a mob we already
    --- pressed something at, and one that came for us do not.
    local function looting_first()
        local world = P.world
        if not (world and world.looting) then return false end
        local ok, yes = pcall(world.looting)
        return ok and yes == true
    end
    M.looting_first = looting_first

    --- May the rotation open on this unit?
    ---@param target game_object|nil
    ---@return boolean
    function M.may_engage_unit(target)
        if combat.in_combat() then return true end
        if not target or not target:is_valid() then return false end
        if P.key_armed("rot_engage_key") then return true end
        -- ASSISTING THE TANK (1.70.0, modules/assist.lua): the pull is the
        -- tank's. A mob not in combat yet waits for it; one in combat with
        -- the group is joined, though we are not in combat ourselves yet.
        local assist = P.assist
        if assist and assist.engage then
            local ok, verdict = pcall(assist.engage, target)
            if ok and verdict ~= nil then return verdict end
        end
        -- FOLLOWING THE GUIDE (1.7.4, modules/guidewalk.lua): the mob the
        -- guide walk stopped in range of, for the step. Pulled because the
        -- switch "Follow the guide with Sentinel Navigation" asks for it.
        local walker = P.guidewalk
        if walker and walker.pulling then
            local ok, yes = pcall(walker.pulling, target)
            if ok and yes == true then return true end
        end
        local looting = looting_first()

        -- NOTHING PULLS BY ITSELF (1.75.0). The user, 2026-10-04: "i shouldnt
        -- be just auto initiating fights either. Should be when I go into
        -- Attack mode". A hunter's opener used to be asked here with "Start
        -- fights" off: whatever auto-targeting selected in shot range was
        -- marked and shot. Now, with the switch off, a fight starts when YOU
        -- start it -- Attack or a right-click (the attack flag), your own shot
        -- or spell (the mob is then on you) -- or when the mob comes for you
        -- or your pet; the engage key forces it.
        --
        -- With the switch on, a class that knows how it opens (`may_open`: a
        -- hunter's in shot range, never a player or somebody else's fight,
        -- only where pulls are ours) says which selected mobs; without one,
        -- every selected mob.
        if not looting and P.opt("rot_open_combat", false) then
            local class_module = M.active_class()
            if not (class_module and type(class_module.may_open) == "function") then return true end
            local ok, yes = pcall(class_module.may_open, target)
            if not ok or yes == true then return true end
        end

        local player = units.player()
        if not player then return false end

        -- You started it.
        local ok_a, attacking = pcall(player.is_auto_attacking, player)
        if ok_a and attacking == true then return true end

        -- You started it by pressing something at it. A mark does not put a
        -- Classic mob in combat, so a pull we opened used to be dropped the
        -- moment the marked mob wandered out of the opening range or closer
        -- than eight yards -- one to six seconds of a hunter standing still
        -- between the mark and the first shot.
        local mem = P.react and P.react.memory
        if mem and mem.attacked then
            local guid = units.guid(target)
            if guid and mem.attacked(guid, 20) then return true end
        end

        -- It started it.
        local enemies = ctx.enemies
        local row = enemies and enemies.get(target) or nil
        if row and (row.targeting_me or row.targeting_pet or row.engaged) then return true end

        local ok_t, their = pcall(target.get_target, target)
        if ok_t and their and their:is_valid() then
            local guid = units.guid(their)
            if guid and guid == units.guid(player) then return true end
            local pet = P.pet and P.pet.pet()
            if pet and guid and guid == units.guid(pet) then return true end
        end
        return false
    end

    -- --- capabilities -------------------------------------------------------

    local CAPABILITY_ROLES = {
        "interrupt", "slow", "root", "stun", "cc", "defensive", "escape",
        "heal", "dot", "aoe", "cooldown", "dispel", "threat_drop",
    }
    local capabilities_cache, capabilities_at = nil, 0

    --- Trained abilities by role, from the catalogue. Empty lists when the
    --- class has no catalogue yet.
    ---@return table<string, string[]>
    function M.capabilities()
        local now = core.time()
        if capabilities_cache and (now - capabilities_at) < 1.0 then return capabilities_cache end
        capabilities_at = now

        local out = {}
        local catalog = P.catalog
        for i = 1, #CAPABILITY_ROLES do
            local role = CAPABILITY_ROLES[i]
            local names = {}
            if catalog then
                local rows = catalog.with_role(role, true)
                for j = 1, #rows do names[#names + 1] = rows[j].name end
            end
            out[role] = names
        end
        capabilities_cache = out
        return out
    end

    --- The awareness picture as the readout shows it, from the last tick's
    --- snapshot. Plain values only, so the page can format them.
    function M.awareness()
        local s = S
        if not s.player then return nil end
        local out = {
            enemies = s.enemy_count or 0,
            on_me = s.on_me or 0,
            attacking = s.attacking or 0,
            inbound = s.closing or 0,
            casting = s.casting_count or 0,
            arriving = s.arriving and units.name(s.arriving.obj) or nil,
            arrives_in = s.arrives_in or math.huge,
            caster = s.caster_row and units.name(s.caster_row.obj) or nil,
            caster_remaining = s.caster_cast and s.caster_cast.remaining or 0,
            moving = s.moving,
        }
        local row = s.target_row
        if row then
            out.target = {
                name = units.name(row.obj),
                dist = row.dist,
                closing = row.closing,
                arrives = row.time_to_reach,
                activity = row.activity,
                hp = row.hp,
                casting = row.casting ~= nil,
                interruptible = row.casting and row.casting.interruptible or false,
                remaining = row.casting and row.casting.remaining or 0,
                controlled = row.control ~= nil,
            }
        end
        local can = s.can or {}
        local parts = {}
        for _, role in ipairs({ "interrupt", "slow", "root", "stun", "defensive", "escape" }) do
            local names = can[role]
            if names and #names > 0 then
                parts[#parts + 1] = role .. ": " .. table.concat(names, "/")
            end
        end
        out.can = #parts > 0 and table.concat(parts, "   ") or "nothing catalogued"
        return out
    end

    -- --- deadlock breaker ---------------------------------------------------
    --
    -- See the long note in the previous revision: the engine delegates every
    -- "can I press this" rule to is_usable_spell, and if that does not cover
    -- stance or form, an ability reports ready, never fires, and starves the
    -- list below it. This watches for the symptom instead of re-implementing
    -- the rules, and stays dormant until it has proven the signal works.

    local last_submitted = {}
    local pending = {}
    local failures = {}
    local backoff = {}
    local on_swing = {}           -- name -> { at, id }: pressed, waiting on the melee swing
    local confirmations_seen = 0

    local UNOBSERVED_AFTER, BACKOFF_AFTER, BACKOFF_SECONDS = 2.0, 3, 15

    local function since_cast(name)
        local at = last_submitted[name]
        if not at then return math.huge end
        return core.time() - at
    end
    H.since_cast = since_cast

    -- Names we have seen confirmed at least once. THE GLOBAL COUNTER WAS NOT
    -- ENOUGH, and the live log shows why: Corruption, Shoot and Life Tap were
    -- each backed off for fifteen seconds immediately after the dispatcher had
    -- logged them casting. Confirmations were arriving -- so the breaker
    -- considered itself calibrated -- but they were not matching these spells,
    -- which is exactly what a wrong UNIT_SPELLCAST_SUCCEEDED argument order
    -- would look like, and that order is on the unverified list.
    --
    -- One counter cannot tell "this ability never fires" from "I cannot see
    -- this ability's confirmations". Per NAME it can: an ability that has been
    -- confirmed once is one whose confirmations we can read, and only those
    -- have earned the right to be judged.
    local confirmed_names = {}

    local function observe_cast(spell_id)
        confirmations_seen = confirmations_seen + 1
        if not spell_id then return end
        -- The landing watch's casts of this spell, confirmed (1.74.0).
        local watched = noshow.rows
        if #watched > 0 then
            local now = core.time()
            for i = 1, #watched do
                local w = watched[i]
                if w.id == spell_id and not w.confirmed and (now - w.at) <= 2.0 then w.confirmed = true end
            end
        end
        for name, row in pairs(pending) do
            if row.id == spell_id then
                pending[name] = nil
                failures[name] = nil
                confirmed_names[name] = true
            end
        end
        for name, row in pairs(on_swing) do
            if row.id == spell_id then on_swing[name] = nil end
        end
    end

    ctx.on("jcore.spell.cast", function(data)
        if type(data) ~= "table" or not data.spell_id then return end
        local player = units.player()
        if not player then return end
        if data.caster and data.caster.get_guid
            and data.caster:get_guid() ~= player:get_guid() then
            return
        end
        observe_cast(data.spell_id)
        observe_repeat(data.spell_id)
    end)

    ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
        if type(args) ~= "table" or args[1] ~= "player" then return end
        local id = type(args[3]) == "number" and args[3] or nil
        observe_cast(id)
        if id then observe_repeat(id) end
    end)

    local function reap_pending()
        local now = core.time()
        local calibrated = confirmations_seen > 0

        -- A request made while a long cast was in flight was never going to
        -- land, and blaming the ABILITY for that is what produced the false
        -- "Corruption reported castable but never fired" warnings in the live
        -- log. Give a pending entry the benefit of the doubt for as long as
        -- the character is actually busy.
        -- Guarded for the same reason the service now guards its own reads:
        -- this is the FIRST line of the priority walk, so anything that
        -- raises here stops the rotation dead rather than degrading it.
        local ok_busy, remaining = pcall(combat.cast_remaining)
        local busy = ok_busy and type(remaining) == "number" and remaining > 0

        for name, row in pairs(pending) do
            if busy then
                -- Push the deadline out rather than judging it now.
                row.at = now
            elseif (now - row.at) > UNOBSERVED_AFTER then
                pending[name] = nil
                if calibrated and confirmed_names[name] then
                    failures[name] = (failures[name] or 0) + 1
                    if failures[name] >= BACKOFF_AFTER then
                        backoff[name] = now + BACKOFF_SECONDS
                        failures[name] = 0
                        log.fmt("warn",
                            "%s reported castable but never fired; backing off %ds",
                            name, BACKOFF_SECONDS)
                        ctx.emit("jambix.aio.rotation_stuck", name)
                    end
                end
            end
        end
    end

    -- --- a press that left no trace ------------------------------------------
    --
    -- Two patterns in the live log, one cause. Raptor Strike went out eleven
    -- times in one second, and Arcane Shot twenty times in three. Neither
    -- rule had an upkeep, and neither press left anything for the next tick
    -- to see: no global cooldown, no cooldown, no confirmation. So the next
    -- tick asked the same question, got the same answer and pressed again,
    -- as fast as the cast service's own duplicate filter let it.
    --
    -- ON THE NEXT SWING. Raptor Strike, Heroic Strike, Cleave and Maul do not
    -- fire when pressed; they wait for the next melee swing, and the client
    -- calls them ready until that swing lands and starts the cooldown. They
    -- cost no global cooldown either, so they ride the off-GCD lane. One is
    -- held while the client says it is queued (is_current_spell), and for
    -- one swing after a press on a build that does not say. They are not
    -- judged by the confirmation breaker: the confirmation comes with the
    -- swing, which on a slow weapon is later than its deadline.
    --
    -- A PRESS THE CLIENT REFUSED. A shot it will not take -- too close, not
    -- facing, out of sight -- is refused without a cooldown, and the answer
    -- on the next frame is the same. A press that went out and has not been
    -- confirmed is retried once a second rather than every frame. That is
    -- shorter than any global cooldown, so a cast that DID land and is only
    -- waiting on its confirmation is never held by this.

    -- The catalogue's on_next_swing is the first word; these names are the
    -- fallback for a class the catalogue does not describe yet.
    local NEXT_SWING = {
        ["Heroic Strike"] = true, ["Cleave"] = true,
        ["Maul"] = true, ["Raptor Strike"] = true,
    }

    ---@param rule table
    ---@param row table|nil the catalogue row
    ---@return boolean
    local function rides_swing(rule, row)
        if rule.next_swing ~= nil then return rule.next_swing == true end
        if row and row.on_next_swing ~= nil then return row.on_next_swing == true end
        return NEXT_SWING[rule[1]] == true
    end

    --- Seconds between melee swings, from the weapon; a bounded guess when
    --- the client will not say.
    ---@return number
    local function swing_period()
        local player = units.player()
        if player then
            local ok, speed = pcall(player.get_attack_speed, player)
            if ok and type(speed) == "number" then
                if speed > 100 then speed = speed / 1000 end   -- milliseconds
                if speed >= 1 and speed <= 5 then return speed end
            end
        end
        return 3.0
    end
    -- For a class that times something to the swing (1.77.4: a paladin's
    -- Twist of Light, one seal swap a swing).
    H.swing_period = swing_period

    --- Is this on-next-swing ability already waiting on the swing?
    ---@param name string
    ---@return boolean
    local function waiting_on_swing(name)
        local id = book.id(name)
        if id then
            local ok, current = pcall(core.spell_book.is_current_spell, id)
            if ok and current == true then return true end
        end
        local row = on_swing[name]
        return row ~= nil and (core.time() - row.at) < swing_period()
    end

    local sent_at = {}            -- spell id -> when the cast service last sent it
    local RETRY_AFTER = 1.0

    ctx.on("jcore.cast.sent", function(request)
        if type(request) == "table" and request.spell_id then
            sent_at[request.spell_id] = core.time()
        end
    end)

    --- Sent within the last second and still unconfirmed?
    ---@param name string
    ---@return boolean
    local function unanswered(name)
        local row = pending[name]
        if not row then return false end
        local at = sent_at[row.id]
        return at ~= nil and (core.time() - at) < RETRY_AFTER
    end

    -- --- the cast gate, and why it must fail OPEN ---------------------------
    --
    -- Skipping the global cooldown while a cast is in flight fixed the warlock
    -- DoT problem, and then stopped the rotation casting at all.
    --
    -- The reason is the shape of the check rather than the idea. It rests on
    -- get_active_spell_cast_end_time being in the same millisecond time base
    -- as core.game_time(), which the stub never states -- it is one of the
    -- assumptions already listed as unverified. If the two disagree, or if
    -- is_casting_spell latches true, `remaining` is a large positive number
    -- forever and the gate closes permanently.
    --
    -- A gate that can silence the entire rotation must therefore be incapable
    -- of staying shut. Two independent escapes:
    --
    --   1. A remaining time longer than any real cast is nonsense, not a cast.
    --   2. A watchdog on how long we have BELIEVED we are casting, in wall
    --      clock, which catches a latched flag even when the arithmetic looks
    --      plausible.
    --
    -- Either one trips and the gate opens and says so, which is the difference
    -- between a bug you can see and a plugin that quietly does nothing.

    -- The ceiling is set by the LONGEST LEGITIMATE CHANNEL, not the longest
    -- damage cast. Tame Beast is twenty seconds, Hearthstone and the mage
    -- portals are ten, a bandage is eight. A twelve-second ceiling would have
    -- declared a hunter taming a pet to be a broken API and thrown the gate
    -- away for the rest of the session. Thirty is clear of everything real
    -- and still far below "this flag is stuck on".
    local MAX_SANE_CAST = 30.0
    local busy_since = 0
    local gate_distrusted = false
    local last_busy = false       -- for the readout, which must not mutate state

    ---@return boolean
    function M.cast_gate_busy()
        if gate_distrusted then
            last_busy = false
            return false
        end
        if not P.opt("rot_respect_cast", true) then
            last_busy = false
            return false
        end
        -- A pet heal channel that would get us killed if it ran on gives way
        -- (react/petcare.lua): the walk may press and the kite may step out.
        local react = P.react
        if react and react.yielding and react.yielding() then
            last_busy = false
            return false
        end

        local ok, remaining = pcall(combat.cast_remaining)
        if not ok or type(remaining) ~= "number" then
            busy_since, last_busy = 0, false
            return false
        end

        -- The slider is in centiseconds so it can be a whole number.
        local slack = P.optpct("rot_cast_slack", 25)

        if remaining <= slack then
            busy_since, last_busy = 0, false
            return false
        end

        if remaining > MAX_SANE_CAST then
            gate_distrusted = true
            last_busy = false
            log.once("warn", "cast_gate_range", string.format(
                "cast time reads %.1fs, which is longer than any real cast or "
                .. "channel; ignoring cast detection for this session", remaining))
            return false
        end

        local now = core.time()
        if busy_since == 0 then busy_since = now end

        if (now - busy_since) > MAX_SANE_CAST then
            gate_distrusted = true
            last_busy = false
            log.once("warn", "cast_gate_stuck", string.format(
                "have appeared to be casting for over %.0fs without stopping; "
                .. "ignoring cast detection for this session", MAX_SANE_CAST))
            return false
        end

        last_busy = true
        return true
    end

    ---@return boolean
    function M.cast_gate_trusted()
        return not gate_distrusted
    end

    --- The gate's last answer, without asking it again.
    ---
    --- The readout runs off a menu title provider, which is called on frames
    --- the rotation does not run -- including while the rotation is switched
    --- off entirely. Calling the gate from there would start the watchdog
    --- clock on a cast we are not even trying to act on.
    ---@return boolean
    function M.cast_gate_last()
        return last_busy
    end

    local function backed_off(name)
        local until_time = backoff[name]
        if not until_time then return false end
        if core.time() >= until_time then
            backoff[name] = nil
            return false
        end
        return true
    end

    function M.stuck_abilities()
        local out, now = {}, core.time()
        for name, until_time in pairs(backoff) do
            if until_time > now then
                out[#out + 1] = string.format("%s (%.0fs)", name, until_time - now)
            end
        end
        table.sort(out)
        return out
    end

    -- --- did it actually land? ----------------------------------------------
    --
    -- The deadlock breaker watches whether a spell we won arbitration for was
    -- ever CAST. Nothing watched whether the debuff then APPEARED, and those
    -- are different failures: a full resist, an immunity, a dispel or a mob
    -- that died on the travel time all produce a cast that landed nothing.
    --
    -- It was diagnostics only, ON PURPOSE: something that silently swallowed
    -- a rule because "it never lands" would be one more way for the rotation
    -- to go quiet. Since 1.74.0 a cast the client CONFIRMED that never shows
    -- feeds H.dot_noshow (above), which holds the DoT on that mob -- out loud
    -- (the log says which spell, which mob) and never for a spell that has
    -- not shown on any mob, so a client that does not show it at all still
    -- gets it, on its duration.

    local landing = noshow.rows   -- { name, id, guid, mob, at, confirmed } awaiting a verdict
    local applied = {}            -- name -> times it appeared
    local missed = {}             -- name -> times it did not

    -- Long enough for a travel-time spell to arrive and the next unit sweep to
    -- see it; short enough that the answer is still about this cast.
    local LANDING_GRACE = 2.0

    ---@param name string
    ---@param target game_object
    local function watch_landing(name, target, spell_id)
        if not target then return end
        local ok, guid = pcall(target.get_guid, target)
        if not ok or not guid then return end
        local mob = units.name and units.name(target) or nil
        if mob == "" then mob = nil end
        landing[#landing + 1] = { name = name, id = spell_id, guid = guid, mob = mob, at = core.time() }
    end

    local function reap_landings()
        if #landing == 0 then return end
        local now = core.time()

        for i = #landing, 1, -1 do
            local row = landing[i]
            if (now - row.at) >= LANDING_GRACE then
                table.remove(landing, i)

                local unit = units.by_guid(row.guid)
                if not unit or not unit:is_valid() or unit:is_dead() then
                    -- The mob died or walked out of the sweep. That is not the
                    -- spell failing, and counting it as a miss would make
                    -- every finished pull look like a resist.
                elseif H.debuff_up(unit, row.name) then
                    applied[row.name] = (applied[row.name] or 0) + 1
                    H.dot_verdict(row, true)
                else
                    missed[row.name] = (missed[row.name] or 0) + 1
                    H.dot_verdict(row, false)
                    log.once("debug", "dot_miss_" .. row.name, string.format(
                        "%s was cast but is not on the target", row.name))
                    ctx.emit("jambix.aio.dot_missed", row.name, row.guid,
                        missed[row.name])
                end
            end
        end
    end

    --- Which debuffs are failing to land, and how often.
    ---
    --- A handful of misses is ordinary: resists happen, and a mob dying on a
    --- travel-time spell counts once. A name that has never landed is the
    --- interesting case, and is what the readout shows.
    ---@return table[] rows sorted worst first
    function M.landing_report()
        local rows = {}
        local names = {}
        for name in pairs(applied) do names[name] = true end
        for name in pairs(missed) do names[name] = true end

        for name in pairs(names) do
            local hit, fail = applied[name] or 0, missed[name] or 0
            if fail > 0 then
                rows[#rows + 1] = { name = name, applied = hit, missed = fail,
                                    rate = fail / math.max(1, hit + fail) }
            end
        end
        table.sort(rows, function(a, b)
            if a.rate ~= b.rate then return a.rate > b.rate end
            return a.missed > b.missed
        end)
        return rows
    end

    -- --- the priority walk --------------------------------------------------

    local last_choice, last_fast
    -- The tick counter the shared snapshot is keyed on, and the tick the
    -- priority walk last ran in (1.8.0; the reactions' after-job asks). The
    -- tick is counted by a job of its own, ahead of everything; without a
    -- scheduler (a hand-built bundle in the tests) the clock stands in.
    local epoch, walk_epoch = 0, -1
    local counted = false            -- true once the counting job has run
    if ctx and ctx.tick then
        ctx.tick(function()
            epoch = epoch + 1
            counted = true
        end, { priority = -990 })
    end
    local function tick_key()
        if counted then return epoch end
        return core.time()
    end

    --- Resolves the unit a rule acts on.
    ---
    --- Four shapes, and they are not interchangeable:
    ---   self     - the player (buffs, shouts, self-centred AoE)
    ---   heal     - the lowest-health ally in range
    ---   retarget - a unit the predicate chose, e.g. a loose mob to taunt
    ---   default  - the current target
    local function resolve_target(rule, s)
        if rule.self then return s.player end
        if rule.heal then return s.ally end
        if rule.retarget then return nil end   -- filled after the predicate
        return s.target
    end

    -- A CHANNEL IS NOT A CAST, and this is the third time that distinction
    -- has cost something. The wand was the first: pressing Shoot again stops
    -- it. This is the same shape and worse -- re-requesting a running Drain
    -- Soul RESTARTS it, so the channel never reaches the tick that kills the
    -- mob, and that tick is the only one that pays the Improved Drain Soul
    -- refund. The live log shows four and five dispatches inside one second,
    -- and the spell queue purging its own duplicates.
    --
    -- Bounded, because is_channelling_spell latching true would otherwise
    -- wedge the rule for ever. Past the longest channel in the game it is not
    -- a channel any more, whatever the client says.
    ---@param rule table
    ---@return boolean
    local function channel_running(rule)
        return rule.channel == true and H.channel_active(rule[1])
    end

    -- --- what the catalogue says --------------------------------------------
    --
    -- A rule used to carry every fact about its ability itself: that Aimed
    -- Shot needs standing, that a sting replaces a sting, that Intimidation
    -- needs the pet on the mob. With the catalogue those facts live once,
    -- and the walk enforces them for every rule that names a described
    -- ability. A class file may still say them; it no longer has to.
    --
    -- Everything here is a reason NOT to press. Nothing here presses.

    --- The pet's target's guid, once per call.
    local function pet_target_guid()
        local pet = P.pet
        if not pet then return nil end
        -- The pet module's reading (1.8.1): the client's answer, else the mob
        -- it was sent at, for a client that does not say (Forever).
        local held = (pet.fighting and pet.fighting()) or pet.pet_target()
        if not held then return nil end
        local ok, guid = pcall(held.get_guid, held)
        return ok and guid or nil
    end

    --- Is another sting of ours on the target? A new sting replaces the old
    --- one, so an unintended second sting is a lost first one.
    ---@param row table the catalogue row of the sting about to be cast
    ---@param target game_object
    local function other_sting_up(row, target)
        local catalog = P.catalog
        if not catalog then return false end
        local stings = catalog.with_role("debuff") -- every sting is a debuff
        for i = 1, #stings do
            local other = stings[i]
            if other ~= row and other.stacks == "sting" and other.applies and other.applies.aura
                and H.debuff_up(target, other.applies.aura) then
                return true
            end
        end
        return false
    end

    --- Why the catalogue says this rule cannot fire now, or nil.
    ---@param rule table
    ---@param row table the catalogue row
    ---@param s table
    ---@param target game_object|nil
    ---@return string|nil reason
    local function catalog_blocks(rule, row, s, target)
        -- Aspects are the player's, switched in their own window
        -- (modules/aspects.lua, 1.49.0). Neither this walk nor a reaction
        -- (press_blocked) casts one, whatever a rule or a role asks, and no
        -- rule can opt out of this.
        if row.exclusive == "aspect" then return "aspects are switched in the Aspects window" end
        -- A rule may opt out of a check it knows better about.
        if rule.ignore_catalog then return nil end

        local needs = row.needs
        if needs then
            for i = 1, #needs do
                local need = needs[i]
                if need == "standing" then
                    if s.player:is_moving() then return "moving" end
                    -- Only for a cast bar or a channel: a toggle's press only
                    -- arms it (Auto Shot waits for its own aim), and an
                    -- instant has nothing for movement to break.
                    if (s.still_for or math.huge) < SETTLE and ((tonumber(row.cast) or 0) > 0
                        or row.kind == "channel" or (tonumber(row.channel) or 0) > 0) then
                        return "just stopped moving"
                    end
                elseif need == "pet_alive" or need == "pet" then
                    if not (P.pet and P.pet.alive()) then return "no pet" end
                elseif need == "pet_on_target" then
                    if not target then return "no target" end
                    -- CAST ON YOURSELF (1.8.1): Intimidation is, and lands
                    -- on whatever the pet hits next. It was compared with
                    -- YOUR guid, which the pet never attacks, so it was
                    -- refused every time, by the rotation and by every
                    -- reaction. On yourself the need is the pet on a mob;
                    -- which mob is the rule's to say.
                    local ok, guid = pcall(target.get_guid, target)
                    local ok_p, mine = false, nil
                    if s.player then ok_p, mine = pcall(s.player.get_guid, s.player) end
                    if target == s.player or (ok and ok_p and guid ~= nil and guid == mine) then
                        if pet_target_guid() == nil then return "pet not on a mob" end
                    elseif not ok or not guid or pet_target_guid() ~= guid then
                        return "pet not on target"
                    end
                elseif need == "out_of_combat" then
                    -- Forever lets a hunter lay traps in combat (Icy Veins'
                    -- class overview and Mobalytics' levelling guide, 1.80.0);
                    -- on Era a trap still waits for the fight to end.
                    if s.in_combat and not (P.forever and row.kind == "trap") then return "in combat" end
                elseif need == "no_pet" then
                    if P.pet and P.pet.alive() then return "pet is out" end
                elseif need == "target_beast" then
                    if target then
                        local ok, kind = pcall(target.get_creature_type, target)
                        if ok and type(kind) == "number" and kind ~= 1 then return "not a beast" end
                    end
                elseif need == "target_has_mana" then
                    if target then
                        local ok, max_mana = pcall(target.get_max_power, target, 0)
                        if ok and type(max_mana) == "number" and max_mana <= 0 then return "target has no mana" end
                    end
                elseif need == "no_other_sting" then
                    if target and not rule.replace and other_sting_up(row, target) then
                        return "another sting is up"
                    end
                end
                -- ranged_weapon, ammo, facing, melee_weapon, after_dodge,
                -- after_parry: the client's own usability answer covers
                -- these, and it is asked right after this.
            end
        end

        -- What it applies is already there. A dot rule decides its own
        -- refresh (H.dot_worth_it looks at the remaining time); everything
        -- else that puts an aura on something is not re-cast over itself.
        local applies = row.applies
        if applies and applies.aura and not rule.dot and not rule.reapply then
            local on = applies.on
            if on == "target" then
                -- A debuff that STACKS (Sunder Armor to five) is meant to be
                -- re-cast while it is up, until it is full.
                local max_stacks = tonumber(applies.stacks) or 1
                if target and max_stacks > 1 then
                    if H.debuff_stacks(target, applies.aura) >= max_stacks
                        and H.debuff_remaining(target, applies.aura) > 1.5 then
                        return "already fully stacked"
                    end
                elseif target and H.debuff_remaining(target, applies.aura) > 1.5 then
                    return "already on the target"
                end
            elseif on == "self" then
                if H.buff_remaining(s.player, applies.aura) > 1.5 then return "already on you" end
            elseif on == "pet" then
                local pet = P.pet and P.pet.pet()
                if pet and H.buff_remaining(pet, applies.aura) > 1.5 then return "already on the pet" end
            end
        end

        return nil
    end

    --- The catalogue row for a rule's ability, or nil.
    local function catalog_row(name)
        local catalog = P.catalog
        return catalog and catalog.ability(name) or nil
    end

    -- --- range, from the catalogue ------------------------------------------
    --
    -- The client's castable check evaluates range from ITS OWN range data for
    -- the spell. Where that data is missing the answer is "in range" only at
    -- touching distance, and an ability the catalogue describes as reaching
    -- a hundred yards is pressed only when the mob is in your face. The
    -- catalogue says what every described ability reaches, so for those the
    -- range is decided here and the client is asked about everything else
    -- (cooldown, resources, line of sight) with range skipped.

    --- Range for a described ability: min, max in yards, or nil when the
    --- catalogue has no opinion (melee, self, pet, party, undescribed).
    ---@param row table
    ---@return number|nil min
    ---@return number|nil max
    local function catalog_range(row)
        local r = row and row.range
        if type(r) == "number" then return 0, r end
        if type(r) == "table" then return r.min or 0, r.max end
        if r == "ranged" then
            local data = P.catalog and P.catalog.current()
            local band = data and data.ranges and data.ranges.ranged
            local min = band and band.min or 8
            local max = band and band.max or 35
            -- Hawk Eye: two yards per rank on every ranged shot.
            local hawk = P.talents and P.talents.rank("Hawk Eye") or 0
            return min, max + 2 * hawk
        end
        return nil, nil
    end

    --- Whether the client will take this ability on this target now, with
    --- the range decided by the catalogue where it can be.
    ---@param name string
    ---@param row table|nil
    ---@param s table
    ---@param target game_object
    ---@return boolean usable
    ---@return string|nil reason
    local function usable_on(name, row, s, target)
        -- WHAT IT TAKES (1.77.4). A class may say a spell works only on some
        -- creature types (`creature_types`: Repentance humanoids, Exorcism
        -- demons and undead). The client refuses anything else with red text,
        -- and a reaction -- Repentance as an interrupt or on an add -- had no
        -- way to know. A type the client does not say lets it through.
        if target ~= s.player then
            local class_module = M.active_class()
            local only = class_module and class_module.creature_types and class_module.creature_types[name]
            if type(only) == "table" then
                local ok_k, kind = pcall(target.get_creature_type, target)
                if ok_k and type(kind) == "number" and kind > 0 then
                    local takes = false
                    for i = 1, #only do
                        if only[i] == kind then takes = true break end
                    end
                    if not takes then return false, "does not work on this creature type" end
                end
            end
        end
        -- What the fights taught (react/learn.lua): immune, evading, and the
        -- real range edges on this mob.
        local learn = P.react and P.react.learn
        if learn and target ~= s.player then
            local why = learn.blocks(name, target)
            if why then return false, why end
        end
        -- What another player is wearing right now (react/pvp.lua, 1.81.0):
        -- Divine Shield or Ice Block takes nothing, Blessing of Protection
        -- nothing physical, Berserker Rage no fear, a druid's form no sheep.
        local pvp = P.react and P.react.pvp
        if pvp and target ~= s.player then
            local ok, why = pcall(pvp.blocks, name, target)
            if ok and why then return false, why end
        end
        local min, max = catalog_range(row)
        local learned = false
        if min ~= nil and learn and target ~= s.player then
            min, max, learned = learn.range(name, target, min, max)
        end
        if min ~= nil and target ~= s.player then
            -- Hitbox to hitbox, as the client measures it (1.58.1); half a
            -- yard of slack on the outside for a reading a frame old.
            local distance = H.gap(target, (target == s.target and s.distance) or units.distance(target))
            if distance > max + 0.5 then
                return false, string.format("out of range (%.0fy from its edge, reaches %.0fy)", distance, max)
            end
            -- And slack on the inside edge while the gap is closing: the press
            -- reaches the server a moment later, and a mob running in covers a
            -- yard and more in that moment ("Target too close" at a reading of
            -- eight yards, live log 138:23).
            local inner = min
            if min > 0 then
                local tr = target == s.target and s.target_row or nil
                local closing = tr and tonumber(tr.closing) or 0
                if closing > 0.5 then inner = min + math.min(2, 0.5 + closing * 0.2) end
            end
            if distance < inner then
                if inner > min then
                    return false, string.format("inside minimum range (%.0fy from its edge, needs %.0fy while it closes)", distance, inner)
                end
                return false, string.format("inside minimum range (%.1fy from its edge, needs %.1fy%s)", distance, min,
                    learned and ", learned on this mob" or "")
            end
            if not book.castable(name, target, { skip_range = true }) then
                return false, "client: not castable (cooldown, resources, sight)"
            end
            return true, nil
        end
        if not book.castable(name, target) then
            return false, "client: not castable on target (range, sight)"
        end
        return true, nil
    end

    --- The catalogue's range for an ability: minimum and reach, or nil for
    --- one it does not describe. The reaction engine's lessons need it.
    ---@param name string
    ---@return number|nil min
    ---@return number|nil max
    function M.range_of(name)
        return catalog_range(catalog_row(name))
    end

    --- Why the walk's own gates would refuse this ability on this target now,
    --- or nil. The reaction engine validates with this rather than restating
    --- the catalogue's rules and the range logic a second time.
    ---@param name string
    ---@param s table|nil the snapshot
    ---@param target game_object|nil
    ---@return string|nil
    function M.press_blocked(name, s, target)
        if backed_off(name) then return "backed off after unconfirmed casts" end
        if not s or not s.player or not target then return nil end
        if P.classwin and P.classwin.owns(name) then return "the class window keeps it" end
        local row = catalog_row(name)
        if row then
            local why = catalog_blocks({ name }, row, s, target)
            if why then return "catalogue: " .. why end
        end
        local ok, why = usable_on(name, row, s, target)
        if not ok then return why or "not usable" end
        return nil
    end

    -- --- why is this rule not firing? ----------------------------------------
    --
    -- A rotation that holds a rule looks identical to a broken one until it
    -- says why. This walks the same gates the priority walk applies to one
    -- named rule, against the current snapshot, and answers in words. A class
    -- module lists the rules worth watching (`watch = { "Hunter's Mark" }`),
    -- and the tick logs the answer whenever it changes.

    --- Why the named rule in the active profile would not fire right now,
    --- or that it would.
    ---@param name string
    ---@param profile? table
    ---@param s? table
    ---@return string
    function M.explain(name, profile, s)
        local class_module = M.active_class()
        if not class_module then return name .. ": no class module" end
        profile = profile or class_module.profiles[active_key or M.active_profile_key(class_module)]
        if not profile then return name .. ": no profile" end
        s = s or S
        if not s or not s.player then return name .. ": no snapshot yet" end

        local rule = nil
        for i = 1, #profile.rules do
            if profile.rules[i][1] == name then rule = profile.rules[i] break end
        end
        if not rule then
            return string.format("%s: no such rule in the %s profile", name, profile.label or "?")
        end

        if not book.known(name) then
            -- The most likely reason of all, and the one nothing else can
            -- see: the client spells it differently. Show what it has.
            local needle = name:lower():match("^(%w+)") or name:lower()
            local like, names = {}, book.names()
            for i = 1, #names do
                if names[i]:lower():find(needle, 1, true) then like[#like + 1] = names[i] end
            end
            return string.format("%s: NOT IN THE SPELLBOOK as spelled (client has: %s)",
                name, #like > 0 and table.concat(like, ", ") or "nothing similar")
        end

        local parts = {}
        local target = resolve_target(rule, s)
        if not target and not rule.retarget then parts[#parts + 1] = "no target" end
        if rule.upkeep and since_cast(name) < rule.upkeep then
            parts[#parts + 1] = string.format("upkeep lockout (%.1fs since last press)", since_cast(name))
        end
        if backed_off(name) then parts[#parts + 1] = "backed off after unconfirmed casts" end
        if channel_running(rule) then parts[#parts + 1] = "its channel is running" end
        if not H.key_allows(name) then parts[#parts + 1] = "its key is not held" end
        local row = catalog_row(name)
        local swing = rides_swing(rule, row)
        if swing and waiting_on_swing(name) then parts[#parts + 1] = "queued on the next swing" end
        if unanswered(name) then parts[#parts + 1] = "pressed under a second ago, not confirmed yet" end
        if row and target then
            local why = catalog_blocks(rule, row, s, target)
            if why then parts[#parts + 1] = "catalogue: " .. why end
        end
        if P.classwin and P.classwin.owns(name) then parts[#parts + 1] = "the class window keeps it" end
        if s.hold_fire and (target == s.target or rule.retarget) and not rule.self and not rule.heal then
            local why = "holding fire: target not engaged"
            if looting_first() then
                why = "holding fire: looting first"
            elseif not P.opt("rot_open_combat", false) then
                -- 1.75.0: nothing is pulled by itself.
                why = why .. " (waiting for you to attack it, or the engage key)"
            elseif type(class_module.may_open) == "function" and s.target then
                local ok, yes, reason = pcall(class_module.may_open, s.target)
                if ok and yes == true then
                    why = why .. " (class says open; gate disagrees)"
                else
                    why = why .. " (start fights: " .. tostring(ok and reason or yes) .. ")"
                end
            end
            parts[#parts + 1] = why
        end
        if not (rule.fast or swing) and M.cast_gate_busy() then parts[#parts + 1] = "a cast is in flight" end
        local react = P.react
        if react and react.gate and react.observing and react.observing() then
            local why = react.gate(name, target)
            if why then parts[#parts + 1] = "memory: " .. why end
        end
        if target then
            if rule.direct or (row and row.kind == "toggle") then
                -- A toggle's rule presses when it is asked, so it is not
                -- asked here; the class may say what it would do instead.
                -- Firing at this target answers everything, so it ends the
                -- line.
                local status = class_module.toggle_status and class_module.toggle_status[name]
                if type(status) == "function" then
                    local ok, held, running = pcall(status, s)
                    if ok and running then return name .. ": " .. running end
                    if ok and held then parts[#parts + 1] = held end
                else
                    parts[#parts + 1] = "(toggle: rule not evaluated here)"
                end
            else
                s.asking = name
                local ok, passes = pcall(rule[2], s)
                if not ok then
                    parts[#parts + 1] = "rule raised: " .. tostring(passes)
                elseif not passes then
                    parts[#parts + 1] = "rule says no"
                elseif react and react.adapt and react.observing and react.observing() and not rule.fixed then
                    -- The rule says yes and the fight says wait (the pet's
                    -- threat, a cast on the move): the walk drops it, so say so.
                    local ok_a, _, _, refuse = pcall(react.adapt, rule, row, s, { target = target })
                    if ok_a and refuse then parts[#parts + 1] = "the fight: " .. refuse end
                end
            end
            if not book.ready(name) then parts[#parts + 1] = "client: not ready (cooldown or not usable)" end
            local usable, why = usable_on(name, row, s, target)
            if not usable then parts[#parts + 1] = why or "not usable" end
        end

        if #parts == 0 then return name .. ": would fire now" end
        return name .. " held: " .. table.concat(parts, "; ")
    end

    local watch_said = {}      -- name -> last explanation logged
    local watch_at = 0

    --- Logs the explanation for every watched rule when it changes.
    local function watch(class_module, profile, s)
        local list = class_module.watch
        if type(list) ~= "table" or #list == 0 then return end
        local now = core.time()
        if (now - watch_at) < 1.0 then return end
        watch_at = now
        for i = 1, #list do
            local name = list[i]
            local ok, text = pcall(M.explain, name, profile, s)
            text = ok and text or ("explain failed: " .. tostring(text))
            if text ~= watch_said[name] then
                watch_said[name] = text
                log.fmt("info", "watch: %s", text)
            end
        end
    end

    function M.watched()
        local out = {}
        for name, text in pairs(watch_said) do out[#out + 1] = text end
        table.sort(out)
        return out
    end

    -- --- the walk, SCORED (1.33.0) -------------------------------------------
    --
    -- THE ROTATION CHANGES WITH THE FIGHT. It used to press the first rule
    -- that passed, in the order the class file wrote: the same order against
    -- one boar and against four, on the move and standing, at full mana and
    -- empty, on a mob with a minute to live and one with two seconds.
    --
    -- Now every rule that passes is a CANDIDATE. Its place in the class's
    -- list is its starting score -- the author's order is still the prior,
    -- half a point a place -- and the reaction engine's picture of the fight
    -- moves it (modules/react/adapt.lua): area damage up in a pack and down on
    -- one target, damage-over-time down on something about to die, a cast the
    -- target will not live through down, a cast while moving out entirely,
    -- expensive spells down as the mana runs out, slows up on a runner or a
    -- mob closing in, control up and damage down when the fight goes wrong.
    -- Every point carries its reason, and the reaction readout shows the
    -- rotation's candidates beside the reactions.
    --
    -- WHAT DID NOT CHANGE: every gate that keeps a press from repeating or
    -- misfiring (upkeep, back-off, the swing, the unanswered second, the
    -- channel, the key, the catalogue, holding fire, the memory) runs before
    -- scoring, exactly as before; the lanes are separate as before; and with
    -- no reaction engine the scores are the list order and the walk presses
    -- exactly what it always did.

    local ROTATION_BASE, ROTATION_STEP = 50, 0.5

    -- Asking these ARMS them (the toggle's press lockout), so they are asked
    -- only when their turn in the score order comes, as the old walk did.
    local TOGGLE_NAMES = { ["Auto Shot"] = true, ["Shoot"] = true, ["Attack"] = true }

    local function asks_once(rule, row)
        return rule.direct == true or (row ~= nil and row.kind == "toggle") or TOGGLE_NAMES[rule[1]] == true
    end

    --- Asks a candidate's rule, with the spread and the retarget, and fills
    --- in the unit it acts on. False when the rule says no.
    local function ask(c, s)
        local rule = c.rule
        local target = c.target
        -- Which spell is asking: H.spread counts where that one lands.
        s.asking = rule[1]
        local ok, passes = pcall(rule[2], s)

        -- A SPREAD RULE IS ASKED ABOUT EVERY ENGAGED ENEMY, not just the one
        -- selected. The predicate already knows how to answer "is this worth
        -- casting on s.target", so the unit is swapped underneath it rather
        -- than every class file learning to iterate. The real target is tried
        -- first, so nothing changes in a single-target fight.
        if rule.spread and not (ok and passes)
            and (P.spread_allowed == nil or P.spread_allowed()) then
            local restore = s.target
            local list = s.engaged_units or {}
            -- A predicate may cap how far it spreads (1.84.0: a hunter's
            -- Serpent Sting on up to three): `s.spreading` is set while it
            -- is asked about a unit other than the selected target.
            s.spreading = true
            for u = 1, #list do
                local other = list[u]
                if other ~= restore and other:is_valid() and not other:is_dead() then
                    s.target = other
                    s.thp = units.health_fraction(other)
                    s.ttd = combat.time_to_die(other)
                    local ok2, passes2 = pcall(rule[2], s)
                    -- ONE IT CAN REACH (1.8.1). The first mob the predicate
                    -- took used to be the answer, and press() then found it
                    -- out of reach -- an add in melee inside a hunter's dead
                    -- zone, out of range, out of sight -- and the spell went
                    -- nowhere, while the mobs it could reach waited. The
                    -- user: "the Rotation doesn't automatically Look for All
                    -- targets in combat with us and drop a Sting on them".
                    -- So the next is asked. usable_on reads the snapshot's
                    -- distance for the real target only: it is put back.
                    if ok2 and passes2 then
                        s.target = restore
                        local reach = rule.prefix or usable_on(rule[1], c.row, s, other)
                        s.target = other
                        if reach then
                            ok, passes, target = true, true, other
                            break
                        end
                    end
                end
            end
            s.spreading = nil
            s.target = restore
            s.thp = restore and units.health_fraction(restore) or 0
            s.ttd = restore and combat.time_to_die(restore) or 0
        end

        if ok and passes and rule.retarget then target = s[rule.retarget] end
        if not (ok and passes) or not target then return false end
        c.target = target
        return true
    end

    --- Presses a candidate if the client will take it. True when it went out.
    local function press(c, s)
        local rule, row = c.rule, c.row
        -- A rule marked `prefix` names a spell LINE whose ranks carry
        -- different names -- Create Healthstone (Minor), (Lesser), ... An
        -- exact lookup resolves for one rank out of five. Written as a
        -- branch, NOT as `rule.prefix and X or Y`: that idiom yields Y
        -- whenever X is false, and a prefix rule whose line is not ready would
        -- fall through to the exact-name lookup and cast the wrong thing.
        local spell_id, usable
        if rule.prefix then
            spell_id = book.id_prefix(rule[1])
            usable = book.ready_prefix(rule[1])
        else
            spell_id = book.id(rule[1])
            usable = c.target ~= nil and usable_on(rule[1], row, s, c.target) or false
        end
        if not (spell_id and usable) then return false end

        -- A toggle rule is pressed once and never queued: a queued second
        -- press is what switches it off.
        local direct = rule.direct == true or (row ~= nil and row.kind == "toggle")
        ctx.cast({
            spell_id = spell_id,
            target = c.target,
            priority = ctx.PRIORITY.ROTATION,
            reason = rule[1],
            fast = c.fast,
            direct = direct,
        })
        if rule.dot then watch_landing(rule[1], c.target, spell_id) end
        last_submitted[rule[1]] = core.time()
        -- A toggle is NOT judged by the confirmation breaker (its first shot
        -- can come a whole swing after the press, and a press that stopped it
        -- reports nothing), nor is an on-next-swing ability (confirmed by the
        -- swing, not the press).
        if c.swing then
            on_swing[rule[1]] = { at = core.time(), id = spell_id }
        elseif not direct and not pending[rule[1]] then
            pending[rule[1]] = { at = core.time(), id = spell_id }
        end
        return true
    end

    local function by_score(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.index < b.index
    end

    local last_candidates = {}

    --- The candidates of the last walk, scored, for the reaction readout.
    ---@return table[]
    function M.last_candidates() return last_candidates end

    --- Learned at all, so a candidate: one rank of a spell line named by
    --- prefix, or the spell itself. A rule for a spell you have not learned
    --- could never be pressed (press() needs its id), and listing it showed
    --- unlearned spells in the reaction readout as "(not usable)" (1.54.1).
    local function trained(rule)
        if rule.prefix then return book.id_prefix(rule[1]) ~= nil end
        return book.known(rule[1]) == true
    end

    local function run_rules(profile, s)
        reap_pending()
        reap_landings()
        walk_epoch = tick_key()

        local chose_gcd, chose_fast = false, false
        last_choice, last_fast = nil, nil

        -- ALREADY CASTING? THEN THE GCD LANE IS NOT OURS TO SPEND. A warlock
        -- casting Shadow Bolt for forty minutes almost never landed a DoT:
        -- every frame of the cast the walk submitted again, each request
        -- displaced the DoT that had just won its slot, and the breaker then
        -- backed the DoTs off as broken. Off-GCD abilities are exempt: a
        -- next-swing attack or a trinket is exactly what you CAN press mid-cast.
        local busy = M.cast_gate_busy()
        if busy then last_choice = "(casting)" end

        -- Out of combat with a target nobody has engaged: upkeep only. The
        -- readout says so, because a rotation holding fire looks identical
        -- to a broken one until it does.
        local hold_fire = s.hold_fire == true
        if hold_fire and s.target then
            last_choice = looting_first() and "(holding fire: looting first)" or "(holding fire: target not engaged)"
        end

        -- THE PICTURE OF THE FIGHT (modules/react, built in its own pass
        -- before this one, 1.8.0): its memory gates a press (a spell a
        -- reaction pressed a moment ago, a one-per-caster debuff on a
        -- flapping target), and the fight scores the candidates. Read only
        -- while it is this tick's; the reactions themselves may be off.
        local react = P.react
        local live = react ~= nil and react.observing ~= nil and react.observing()
        local gate = (live and react.gate) or nil
        local adapt = (live and react.adapt) or nil

        local cands = {}
        for i = 1, #profile.rules do
            local rule = profile.rules[i]
            local row = catalog_row(rule[1])
            -- An on-next-swing ability costs no global cooldown.
            local swing = rides_swing(rule, row)
            local want_fast = (rule.fast or swing) and true or false

            -- While a cast is in flight only the off-GCD lane is available.
            -- A spell you have not learned is never a candidate.
            if trained(rule) and not (busy and not want_fast) then
                local target = resolve_target(rule, s)
                local blocked = (rule.upkeep and since_cast(rule[1]) < rule.upkeep)
                    or backed_off(rule[1])
                    or (swing and waiting_on_swing(rule[1]))
                    or unanswered(rule[1])
                    or channel_running(rule)
                    or not H.key_allows(rule[1])
                    or (row ~= nil and catalog_blocks(rule, row, s, target) ~= nil)
                    -- The class window keeps it (1.62.0): an aura, seal,
                    -- armor, stance or buff picked or kept there.
                    or (P.classwin ~= nil and P.classwin.owns(rule[1]))
                    -- Holding fire: anything aimed at the enemy waits. Self
                    -- buffs and heals are not an attack and go through.
                    or (hold_fire and (target == s.target or rule.retarget) and not rule.self and not rule.heal)
                    or (gate ~= nil and gate(rule[1], target) ~= nil)

                if not blocked and (target or rule.retarget) then
                    local c = {
                        rule = rule, row = row, index = i, swing = swing, fast = want_fast,
                        target = target, lazy = asks_once(rule, row),
                        score = ROTATION_BASE - (i - 1) * ROTATION_STEP, reasons = nil,
                    }
                    local keep = c.lazy or ask(c, s)
                    -- Toggles and rules marked `fixed` keep their place: a
                    -- toggle is a running state, not a choice between spells.
                    if keep and adapt and not c.lazy and not rule.fixed then
                        local ok, bonus, reasons, refuse = pcall(adapt, rule, row, s, c)
                        if ok then
                            if refuse then
                                keep = false
                                c.refused = refuse
                            else
                                c.score = c.score + (bonus or 0)
                                c.reasons = reasons
                            end
                        end
                    end
                    if keep then cands[#cands + 1] = c end
                end
            end
        end

        -- And against each other, by what each one does: damage per second
        -- of the lane, the killing blow, the window (react/adapt.lua weigh).
        local weigh = (live and react.weigh) or nil
        if weigh then pcall(weigh, cands, s) end

        table.sort(cands, by_score)
        for k = 1, #cands do
            local c = cands[k]
            if (c.fast and chose_fast) or (not c.fast and chose_gcd) then
                c.state = "outscored"
            elseif c.lazy and not ask(c, s) then
                c.state = "rule says no"
            elseif press(c, s) then
                c.state = "pressed"
                if c.fast then
                    chose_fast, last_fast = true, c.rule[1]
                else
                    chose_gcd, last_choice = true, c.rule[1]
                end
            else
                c.state = "not usable"
            end
            if chose_gcd and chose_fast then
                for r = k + 1, #cands do cands[r].state = cands[r].state or "outscored" end
                break
            end
        end
        last_candidates = cands
    end

    -- The walk on its own, for the headless tests: the tick around it needs
    -- the whole bundle.
    M.run_rules = run_rules

    -- --- forecast -----------------------------------------------------------
    --
    -- WHAT COMES NEXT, WITHOUT PRESSING ANYTHING. The spell window shows the
    -- next few presses, and the walk above cannot say what they are: it stops
    -- at the first rule that fires, so nothing below that rule is ever asked.
    -- This asks every rule against the same snapshot and plays the answers
    -- forward a few global cooldowns.
    --
    -- It is a projection from now, not a simulation of the fight. Each
    -- predicate is asked once, about the present, and a projected press does
    -- not change the snapshot -- so what the press would have settled is
    -- settled by rule instead:
    --
    --   * an upkeep, a damage-over-time spell, a self buff, a heal or
    --     anything the catalogue says applies an aura appears ONCE: once it
    --     has landed its own predicate would say no;
    --   * an ability with a cooldown comes back when the cooldown is over;
    --   * anything else is a filler and may repeat (Shadow Bolt, Shadow Bolt).
    --
    -- Left out: toggles (Auto Shot, a wand), which are a running state rather
    -- than a press and would fill the row; and a rule the walk has just
    -- pressed and is waiting to see land, which is already in flight.
    --
    -- HOLDING FIRE IS IGNORED HERE ON PURPOSE. With a mob selected and no
    -- fight yet the walk presses nothing at it; the forecast shows the opener
    -- it will use, which is the useful answer on a mob you are about to pull.
    --
    -- No native call beyond what the walk makes: cooldown and usability come
    -- from the core's per-tick spell cache, range from the catalogue and the
    -- snapshot's distance. No castable() and no line-of-sight trace.

    local FORECAST_EVERY = 0.2      -- seconds between projections
    local FORECAST_HORIZON = 12.0   -- nothing further out than this is shown
    local FORECAST_GCD = 1.5

    -- Up only while the forecast is asking the predicates. A predicate that
    -- keeps state between calls must not let the forecast write it: the
    -- forecast asks about targets the walk is not acting on yet (it ignores
    -- holding fire), so state it started would make the fight itself go
    -- differently with the window open. The hunter's wait for the pet is
    -- the case that made this necessary -- selecting a mob started its
    -- two-second "has the pet been sent" clock, and an engage after that
    -- shot before the pet was sent.
    local forecasting = false

    --- Is this predicate being asked by the forecast rather than the walk?
    --- A predicate that keeps state reads it then, and never writes it.
    ---@return boolean
    function H.forecasting()
        return forecasting
    end

    local candidates   -- defined after forecast(), which calls it

    -- spell id -> base cooldown in seconds. Static for the session.
    local base_cd_cache = {}

    --- The ability's own cooldown: the catalogue's figure, else the client's
    --- base cooldown, else none.
    ---@param row table|nil
    ---@param spell_id integer
    ---@return number seconds
    local function base_cooldown(row, spell_id)
        local cd = row and tonumber(row.cooldown)
        if cd then return cd end
        local cached = base_cd_cache[spell_id]
        if cached then return cached end
        cd = 0
        local fn = core.spell_book and core.spell_book.get_spell_base_cooldown
        if fn then
            local ok, info = pcall(fn, spell_id)
            if ok and type(info) == "table" and type(info.cooldown_ms) == "number" then
                cd = info.cooldown_ms / 1000
            end
        end
        base_cd_cache[spell_id] = cd
        return cd
    end

    --- Seconds a press holds the global cooldown lane: the cast, or the
    --- global cooldown when the cast is shorter.
    ---@param row table|nil
    ---@param spell_id integer
    ---@return number
    local function lane_time(row, spell_id)
        local cast = row and tonumber(row.cast)
        local spells = ctx.spells
        if cast == nil and spells and spells.info then
            local ok, info = pcall(spells.info, spell_id)
            if ok and type(info) == "table" then cast = tonumber(info.cast_time) end
        end
        return math.max(FORECAST_GCD, cast or 0)
    end

    --- Within the catalogue's range, when it has one. Without one the client
    --- decides at press time, and the forecast assumes yes.
    local function in_reach(row, s, target)
        if target == s.player then return true end
        local min, max = catalog_range(row)
        if min == nil then return true end
        local distance = (target == s.target and s.distance) or units.distance(target)
        if type(distance) ~= "number" then return true end
        distance = H.gap(target, distance)
        return distance <= max + 0.5 and distance >= min
    end

    --- Seconds until the spell is off cooldown, from the core's tick cache.
    local function cooldown_left(spell_id)
        local spells = ctx.spells
        if spells and spells.cooldown then
            local ok, cd = pcall(spells.cooldown, spell_id)
            if ok and type(cd) == "number" then return cd end
        end
        return 0
    end

    --- The client's own "could I press this" -- resources, stance, a
    --- required aura -- which does not count the cooldown.
    local function affordable(spell_id)
        local spells = ctx.spells
        if spells and spells.usable then
            local ok, usable = pcall(spells.usable, spell_id)
            if ok then return usable == true end
        end
        return true
    end

    --- The next presses this profile would make, soonest first.
    ---@param profile table
    ---@param s table the snapshot
    ---@param count integer
    ---@return table[] rows { name, id, at = seconds from now, fast }
    local function forecast(profile, s, count)
        local out = {}
        if not profile or not s or not s.player or (count or 0) <= 0 then return out end

        -- The lane is free once the global cooldown and any cast in flight
        -- are both done. A cast reading longer than any real one is the
        -- broken read the cast gate already distrusts.
        local gcd = 0
        local spells = ctx.spells
        if spells and spells.gcd then
            local ok, value = pcall(spells.gcd)
            if ok and type(value) == "number" then gcd = value end
        end
        local ok_cast, casting = pcall(combat.cast_remaining)
        casting = (ok_cast and type(casting) == "number" and casting <= MAX_SANE_CAST) and casting or 0
        local t0 = math.max(0, gcd, casting)

        -- The predicates are asked with the flag up, and it comes down
        -- whatever happens: a flag stuck up would turn the walk's own
        -- questions into a forecast's.
        forecasting = true
        local ok_cands, cands = pcall(candidates, profile, s)
        forecasting = false
        if not ok_cands then error(cands, 0) end

        -- Played forward: at each moment the highest-priority candidate that
        -- is ready goes; when none is, time skips to the first one that will
        -- be. Bounded twice over -- by the count and by the horizon.
        local t = t0
        for _ = 1, count * 4 do
            if #out >= count then break end
            local pick = nil
            for i = 1, #cands do
                local c = cands[i]
                if not c.spent and c.ready_at <= t + 0.05 then
                    pick = c
                    break
                end
            end
            if not pick then
                for i = 1, #cands do
                    local c = cands[i]
                    if not c.spent and (not pick or c.ready_at < pick.ready_at) then pick = c end
                end
                if not pick or pick.ready_at > t0 + FORECAST_HORIZON then break end
                t = pick.ready_at
            end

            out[#out + 1] = { name = pick.name, id = pick.id, at = t, fast = pick.fast }
            if pick.once then
                pick.spent = true
            elseif pick.cd > 0 then
                pick.ready_at = t + pick.cd
            end
            t = t + pick.step
        end
        return out
    end
    M.forecast = forecast

    --- Every rule that would fire once its cooldown allows, in priority
    --- order. A name listed twice (Aimed Shot as opener and as filler) is
    --- taken from the first of its rules that passes.
    ---@param profile table
    ---@param s table
    ---@return table[]
    candidates = function(profile, s)
        local cands, named = {}, {}
        local react = P.react
        local adapt = (react ~= nil and react.adapt ~= nil and react.observing ~= nil and react.observing())
            and react.adapt or nil
        for i = 1, #profile.rules do
            local rule = profile.rules[i]
            local name = rule[1]
            local row = catalog_row(name)
            local toggle = rule.direct == true or (row ~= nil and row.kind == "toggle")
            if not toggle and not named[name] then
                local swing = rides_swing(rule, row)
                local target = resolve_target(rule, s)
                local held = (rule.upkeep and since_cast(name) < rule.upkeep)
                    or (swing and waiting_on_swing(name))
                    or unanswered(name)
                    or channel_running(rule)
                    or backed_off(name)
                    or not H.key_allows(name)
                    or (row ~= nil and catalog_blocks(rule, row, s, target) ~= nil)
                    or (P.classwin ~= nil and P.classwin.owns(name))

                if not held and (target or rule.retarget) then
                    s.asking = name
                    local ok, passes = pcall(rule[2], s)
                    if ok and passes and rule.retarget then target = s[rule.retarget] end

                    local spell_id
                    if rule.prefix then
                        spell_id = book.id_prefix(name)
                    else
                        spell_id = book.id(name)
                    end

                    if ok and passes and target and spell_id
                        and in_reach(row, s, target) and affordable(spell_id) then
                        local wait = cooldown_left(spell_id)
                        if wait <= FORECAST_HORIZON then
                            local fast = (rule.fast or swing) and true or false
                            local cd = base_cooldown(row, spell_id)
                            -- An off-GCD ability with no cooldown of its own
                            -- would otherwise repeat in place for ever.
                            if fast and cd <= 0 then
                                cd = swing and swing_period() or FORECAST_GCD
                            end
                            -- Scored as the walk scores it; a candidate the
                            -- fight rules out (a cast while moving) is not next.
                            local score = ROTATION_BASE - (i - 1) * ROTATION_STEP
                            local refused = nil
                            if adapt and not asks_once(rule, row) and not rule.fixed then
                                local ok_a, bonus, _, refuse = pcall(adapt, rule, row, s,
                                    { target = target, index = i })
                                if ok_a then
                                    refused = refuse
                                    score = score + (bonus or 0)
                                end
                            end
                            named[name] = true
                            cands[#cands + 1] = {
                                score = score, index = i, refused = refused,
                                rule = rule, row = row, target = target, lazy = asks_once(rule, row),
                                name = name, id = spell_id, ready_at = wait, cd = cd, fast = fast,
                                once = (rule.upkeep or rule.dot or rule.self or rule.heal
                                    or (row ~= nil and row.applies ~= nil)) and true or false,
                                step = fast and 0 or lane_time(row, spell_id),
                            }
                        end
                    end
                end
            end
        end
        -- Highest score first, the list order breaking ties; nothing the
        -- fight rules out; weighed against each other as the walk weighs them.
        local kept = {}
        for k = 1, #cands do
            if not cands[k].refused then kept[#kept + 1] = cands[k] end
        end
        if adapt and react.weigh then pcall(react.weigh, kept, s) end
        table.sort(kept, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.index < b.index
        end)
        return kept
    end

    -- What the spell window reads: names, ids and times, never a unit
    -- handle, so it stays safe to read on a later frame.
    local projection = { rows = {}, at = 0, label = nil, live = false }
    -- The snapshot the tick built this frame, handed to the projection that
    -- runs straight after it in the same job, then dropped.
    local tick_s, tick_profile = nil, nil
    local forecast_failed = false

    local function project()
        local s, profile = tick_s, tick_profile
        tick_s, tick_profile = nil, nil

        local timeline = P.timeline
        local count = timeline and timeline.wants_forecast and timeline.wants_forecast() or 0
        if type(count) ~= "number" or count <= 0 then return end

        local now = core.time()
        if (now - projection.at) < FORECAST_EVERY then return end
        projection.at = now
        projection.live = s ~= nil

        if not s then
            -- The rotation is off, paused or idle this frame. Suggest what it
            -- would press, from a snapshot of our own -- at the projection's
            -- rate, not the frame rate.
            if not P.opt("rot_hud_suggest", true) then
                projection.rows = {}
                return
            end
            local class_module = M.active_class()
            profile = class_module and M.active_profile(class_module) or nil
            if not profile then
                projection.rows = {}
                return
            end
            s = build_situation(class_module, profile)
            if not s or s.player:is_dead() or s.player:is_mounted() then
                projection.rows = {}
                return
            end
        end

        projection.label = profile.label
        projection.rows = forecast(profile, s, count)
    end

    --- Refreshes the spell window's projection. Runs after the tick in the
    --- same job. Guarded: nothing here may take the rotation down with it.
    function M.forecast_tick()
        local ok, err = pcall(project)
        if not ok then
            projection.rows = {}
            tick_s, tick_profile = nil, nil
            if not forecast_failed then
                forecast_failed = true
                log.fmt("warn", "spell forecast failed: %s", tostring(err))
            end
        end
    end

    --- The latest projection: { rows, at, label, live }.
    function M.projection()
        return projection
    end

    --- For the headless tests: hand the projection a snapshot, as the tick does.
    function M._forecast_snapshot(profile, s)
        tick_s, tick_profile = s, profile
    end

    -- --- generic combat behaviours ------------------------------------------

    --- Emergency defensives, from the class module's own list, in its order.
    -- One attempt per ability per lockout. THIS BECAME NECESSARY the moment
    -- defensives started firing on "we are losing the race" instead of only on
    -- a health percentage: losing is a SUSTAINED condition, true on every tick
    -- for as long as it lasts, so an unguarded rule re-requests the same
    -- ability every frame. book.ready() does not save us either -- a defensive
    -- with no cooldown, like Drain Life, is always ready.
    local defensive_at = {}
    local DEFENSIVE_LOCKOUT = 6

    -- THE FIXED SEQUENCE BELOW -- defensives, racials, dispel, interrupts,
    -- breaking contact -- RUNS ONLY IF THE REACTION ENGINE FAILS (1.32.0).
    -- Its switches are gone with the rest of the options the engine took
    -- over, and its lines come from P.derived, never from a removed slider.
    local function derived(id, fallback_pct)
        if P.derived then return P.derived(id, fallback_pct) end
        return fallback_pct / 100
    end

    local function defensives(class_module, s)
        if not s.in_combat then return false end

        -- TWO WAYS TO NEED A DEFENSIVE, and the old code knew one.
        --
        -- A health percentage is a lagging indicator: by the time it trips,
        -- the damage that tripped it has already landed. The field module
        -- measures the race directly -- how long until everything on us is
        -- dead against how long until we are -- and it turns negative the
        -- moment a second mob arrives, several seconds before the bar moves.
        --
        -- Either is enough. The percentage stays because it also catches the
        -- case the race cannot see: one enormous hit out of nowhere.
        local low = s.hp <= derived("rot_defensive_hp", 35)
        local losing = P.field ~= nil and P.field.in_trouble()
        if not low and not losing then return false end

        local why = low
            and string.format("at %.0f%% health", s.hp * 100)
            or (P.field and P.field.state.reason or "losing the fight")

        local now = core.time()
        local list = class_module.defensives or {}
        for i = 1, #list do
            local name = list[i]
            -- AND WE MUST BE ABLE TO PAY FOR IT. The warlock defensive list
            -- is Death Coil then Drain Life, and Drain Life on an empty mana
            -- bar is the death spiral wearing an emergency badge: it returns
            -- nothing, costs the global cooldown, and the bar it needed was
            -- the reason we were in trouble. The cost is the real one the
            -- client reports.
            local affordable = true
            if P.auto and s.power_max > 0 then
                local cost = P.auto.cost_fraction(name)
                -- Not merely "can it be cast" but "does casting it leave us
                -- able to do anything else". Spending the last of the bar on
                -- a defensive is how a warlock ends a fight alive for four
                -- more seconds and then out of options.
                if cost and ((s.power / s.power_max) - cost)
                    < P.tune("res_critical_power", 10) then
                    affordable = false
                end
            end

            if book.ready(name) and affordable
                and (now - (defensive_at[name] or 0)) > DEFENSIVE_LOCKOUT then
                defensive_at[name] = now
                ctx.cast({
                    spell_id = book.id(name), target = s.player,
                    priority = ctx.PRIORITY.EMERGENCY,
                    reason = string.format("%s %s", name, why),
                    fast = true,
                })
                return true
            end
        end
        return false
    end

    --- Break contact, when the field says the fight is not winnable.
    ---
    --- SEPARATE FROM THE HARDCORE BAIL-OUT ON PURPOSE. That one triggers on a
    --- health percentage and only exists when hardcore utilities are switched
    --- on. This one triggers on the race -- their health against our damage,
    --- our health against theirs -- and applies to everybody, because a level
    --- 20 character that pulled four mobs has the same problem whether or not
    --- the character can be resurrected afterwards.
    ---
    --- The escape list belongs to the CLASS, in its own order: a fear or a
    --- blink breaks contact with everything at once, a slow only helps
    --- against one pursuer.
    local last_escape = 0

    -- WHOM AN ESCAPE IS CAST ON. Both escape paths -- this one and the
    -- hardcore layer's emergency -- used to cast every escape on the player.
    -- Half the class lists are cast on the ENEMY: Wing Clip, Fear, Blind,
    -- Gouge, Hammer of Justice, Frost Shock, Entangling Roots, Hibernate,
    -- Death Coil. Aimed at ourselves the client refuses them, so a hunter in
    -- trouble had Feign Death or nothing. The catalogue's range says which is
    -- which where it describes the ability ("self" is ours); these names are
    -- the fallback for the classes it does not describe yet.
    local ENEMY_ESCAPES = {
        ["Wing Clip"] = true, ["Disengage"] = true, ["Scatter Shot"] = true,
        ["Entangling Roots"] = true, ["Hibernate"] = true,
        ["Hammer of Justice"] = true, ["Blind"] = true, ["Gouge"] = true,
        ["Frost Shock"] = true, ["Fear"] = true, ["Death Coil"] = true,
        -- The warlock's second defensive drains the ENEMY (1.80.0): cast on
        -- ourselves, the client refused it and the heal never came.
        ["Drain Life"] = true,
    }

    --- The unit an escape is cast on, or nil when the enemy it needs is not
    --- in reach -- then the next escape in the list is tried instead.
    ---@param name string
    ---@param s table
    ---@return game_object|nil
    function H.escape_target(name, s)
        local row = catalog_row(name)
        local on_enemy
        if row and row.range ~= nil then
            on_enemy = row.range ~= "self"
        else
            on_enemy = ENEMY_ESCAPES[name] == true
        end
        if not on_enemy then return s.player end
        local target = s.target
        if not target or not book.castable(name, target) then return nil end
        return target
    end

    local function break_contact(class_module, s)
        if not s.in_combat then return false end
        if not P.field or P.field.plan() ~= "FLEE" then return false end

        -- One attempt per few seconds. An escape that did not work is not
        -- improved by pressing it eight more times, and the global cooldown
        -- is better spent on the defensive that might.
        local now = core.time()
        if (now - last_escape) < 5 then return false end

        local list = class_module.escapes or {}
        for i = 1, #list do
            local name = list[i]
            local target = book.ready(name) and H.key_allows(name)
                and H.escape_target(name, s) or nil
            if target then
                last_escape = now
                ctx.cast({
                    spell_id = book.id(name), target = target,
                    priority = ctx.PRIORITY.EMERGENCY,
                    reason = "breaking contact: " .. P.field.state.reason,
                })
                log.fmt("warn", "%s to break contact -- %s",
                    name, P.field.state.reason)
                return true
            end
        end
        return false
    end

    -- --- defensive racials ---------------------------------------------------
    --
    -- No race detection and no item database. Racials resolve by NAME out of
    -- the spellbook, so whichever one the character actually has is the one
    -- that resolves and the rest simply do not exist -- the same trick the
    -- class rules use, applied to a list that spans every race.
    --
    -- The offensive racials live in modules/burst.lua instead, so they land
    -- inside the same window as the class cooldowns.

    -- Ordered by how much trouble they get you out of. Stoneform clears
    -- bleed, poison and disease at once; Will of the Forsaken breaks fear,
    -- charm and sleep; Escape Artist only handles roots and snares.
    local DEFENSIVE_RACIALS = {
        "Stoneform",
        "Will of the Forsaken",
        "Every Man for Himself",
        "War Stomp",
        "Escape Artist",
        "Shadowmeld",
    }

    local function racials(s)
        if not s.in_combat then return false end

        -- Defensive first: a racial that breaks a fear is worth more than one
        -- that adds damage, and the health check is what separates them.
        if s.hp <= derived("rot_defensive_hp", 35) then
            for i = 1, #DEFENSIVE_RACIALS do
                local name = DEFENSIVE_RACIALS[i]
                if book.ready(name) then
                    ctx.cast({
                        spell_id = book.id(name), target = s.player,
                        priority = ctx.PRIORITY.EMERGENCY,
                        reason = "racial: " .. name, fast = true,
                    })
                    return true
                end
            end
        end

        -- The OFFENSIVE half used to live here, on its own `ttd > 12` timer.
        -- It now belongs to modules/burst.lua, because a damage racial fired
        -- on a different tick from the class cooldown it should have been
        -- multiplying is a racial wasted. This function keeps only the
        -- defensive half, which genuinely is its own decision.
        return false
    end

    -- --- dispel -------------------------------------------------------------
    --
    -- Driven by the aura's TYPE, not its name. The enum has MAGIC, CURSE,
    -- DISEASE and POISON members, and a class declares which of those each of
    -- its dispel spells can remove. A name list would need every debuff in
    -- two expansions and would still miss anything custom.

    local function dispel_types()
        local enums = P.enums
        if not enums or not enums.buff_type then return nil end
        return enums.buff_type
    end

    --- Finds a debuff on `unit` that `spell_types` can remove.
    ---@param unit game_object
    ---@param spell_types table<integer, boolean>
    ---@return boolean
    local function has_dispellable(unit, spell_types)
        local ok, auras = pcall(unit.get_auras, unit)
        if not ok or type(auras) ~= "table" then return false end
        for i = 1, #auras do
            local aura = auras[i]
            if aura and aura.type and spell_types[aura.type] then return true end
        end
        return false
    end

    local last_dispel = 0

    --- Cleanses the player first, then the lowest-health ally.
    ---
    --- Self first on purpose: a poison ticking on you is the one that kills
    --- you, and you are the only target you can always reach.
    local function dispel(class_module, s)

        local list = class_module.dispels
        if type(list) ~= "table" or #list == 0 then return false end

        local types = dispel_types()
        if not types then return false end

        local now = core.time()
        if (now - last_dispel) < 1.5 then return false end

        for i = 1, #list do
            local entry = list[i]
            local name = entry.spell
            if book.ready(name) then
                -- Resolve the declared type names to ids once per attempt.
                local removable = {}
                for _, type_name in ipairs(entry.types or {}) do
                    local id = types[type_name]
                    if type(id) == "number" then removable[id] = true end
                end

                for _, candidate in ipairs({ s.player, s.ally }) do
                    if candidate and has_dispellable(candidate, removable) then
                        last_dispel = now
                        ctx.cast({
                            spell_id = book.id(name), target = candidate,
                            priority = ctx.PRIORITY.UTILITY,
                            reason = "dispel with " .. name,
                        })
                        local ok_name, who = pcall(candidate.get_name, candidate)
                        if P.narrate then
                            P.narrate.say("action", "Dispel",
                                string.format("%s on %s", name, (ok_name and who) or "you"),
                                "dispel")
                        end
                        return true
                    end
                end
            end
        end
        return false
    end

    -- --- group buffs --------------------------------------------------------
    --
    -- Out of combat only, and one buff per pass. Buffing costs a global
    -- cooldown each and there is no hurry between pulls; doing it mid-fight
    -- would trade damage for a buff that was probably already up.

    local last_buff = 0

    local function group_buffs(class_module, s)
        if not P.opt("rot_group_buff", true) then return false end
        if s.in_combat then return false end

        local list = class_module.buffs
        if type(list) ~= "table" or #list == 0 then return false end

        local now = core.time()
        if (now - last_buff) < 2.0 then return false end

        -- Self first, then party. A buff you are missing helps you now; one a
        -- party member is missing helps on the next pull either way.
        --
        -- A class whose own buff its profile picks (`buff_others_only`, the
        -- paladin's blessing, 1.77.1) is not buffed from this list: Kings or
        -- Might went on you here first, so a Protection paladin never got
        -- Sanctuary and a Holy one never got Wisdom.
        local candidates = class_module.buff_others_only and {} or { s.player }
        if P.opt("rot_buff_party", true) then
            -- PARTY MEMBERS, as the switch says (1.77.1). Every friendly
            -- player in range was a candidate, so a paladin blessed each
            -- stranger it passed in town, an hour-long blessing on Forever.
            local in_group = {}
            local group = ctx.group
            if group and group.objects then
                local ok, members = pcall(group.objects)
                if ok and type(members) == "table" then
                    for i = 1, #members do
                        local guid = units.guid(members[i])
                        if guid then in_group[guid] = true end
                    end
                end
            end
            local me = units.guid(s.player)
            local allies = units.allies_within(P.tune_secs("rot_heal_range", 40))
            for i = 1, #allies do
                local guid = units.guid(allies[i])
                if allies[i]:is_player() and guid and in_group[guid] and guid ~= me then
                    candidates[#candidates + 1] = allies[i]
                end
            end
        end
        if #candidates == 0 then return false end

        for i = 1, #list do
            local entry = list[i]
            local name = type(entry) == "table" and entry.spell or entry
            local replaces = type(entry) == "table" and entry.replaces or nil

            -- On you, a buff the class window keeps is its own (1.62.0).
            local window_keeps = P.classwin ~= nil and P.classwin.owns(name)
            if not window_keeps and P.classwin and replaces then
                for _, other in ipairs(replaces) do
                    if P.classwin.owns(other) then window_keeps = true break end
                end
            end
            if book.ready(name) then
                for _, unit in ipairs(candidates) do
                    local have = H.buff_up(unit, name) or (window_keeps and unit == s.player)
                    -- A greater version of the same buff counts as having it.
                    if not have and replaces then
                        for _, other in ipairs(replaces) do
                            if H.buff_up(unit, other) then have = true break end
                        end
                    end
                    if not have and book.castable(name, unit) then
                        last_buff = now
                        ctx.cast({
                            spell_id = book.id(name), target = unit,
                            priority = ctx.PRIORITY.IDLE,
                            reason = "buff: " .. name,
                        })
                        return true
                    end
                end
            end
        end
        return false
    end

    -- For the headless tests, as run_rules.
    M.group_buffs = group_buffs

    --- Interrupts, from the class module's own list.
    ---
    --- Asking for each in turn and letting usability decide is what keeps the
    --- stance-locked pairs (Pummel in Berserker, Shield Bash in Battle or
    --- Defensive) working without encoding that mapping anywhere.
    local function interrupts(class_module, s)
        local list = class_module.interrupts or {}
        if #list == 0 then return false end

        -- The target first, read straight off the unit. Then ANY hostile the
        -- awareness picture says is casting something that can be stopped:
        -- the healer at the back is the cast worth kicking, and it was never
        -- the target.
        local victim = nil
        if s.target and s.target:is_casting_spell() then
            local ok, interruptible = pcall(s.target.is_active_spell_interruptable, s.target)
            if not (ok and interruptible == false) then victim = s.target end
        end
        if not victim then
            local row = s.caster_row
            if row and row.obj and row.obj:is_valid() and not row.obj:is_dead() then
                victim = row.obj
            end
        end
        if not victim then return false end

        for i = 1, #list do
            if book.castable(list[i], victim) then
                ctx.cast({
                    spell_id = book.id(list[i]), target = victim,
                    priority = ctx.PRIORITY.INTERRUPT,
                    reason = "interrupt with " .. list[i],
                })
                return true
            end
        end
        return false
    end

    -- --- profile selection --------------------------------------------------

    -- active_key is declared with the snapshot, above: M.explain reads it too.

    ---@param class_module table
    ---@return string key
    --- Are we the group's tank? The role the group gives us (the dungeon
    --- finder's, or the raid's assignment), not a setting.
    ---@return boolean
    local function tanking_role()
        local group = ctx.group
        if not group or type(group.in_group) ~= "function" or type(group.is_tank) ~= "function" then
            return false
        end
        local ok_in, in_group = pcall(group.in_group)
        if not ok_in or not in_group then return false end
        local player = units.player()
        if not player then return false end
        local ok, yes = pcall(group.is_tank, player)
        return ok and yes == true
    end

    ---@param class_module table
    ---@return string key
    function M.active_profile_key(class_module)
        -- NO SELECTOR (1.33.0). The profile is only which spells you have --
        -- the talents say that -- and what to press with them is decided by
        -- the fight. The one thing talents cannot say is whether this group
        -- wants you to tank; its role assignment can.
        local order = class_module.profile_order or {}
        if class_module.suggest then
            local ok, key = pcall(class_module.suggest, talents, tanking_role())
            if ok and key and class_module.profiles[key] then return key end
        end
        return order[1] or next(class_module.profiles)
    end

    function M.active_profile(class_module)
        return class_module.profiles[M.active_profile_key(class_module)]
    end

    --- Does the active profile have a rule for this ability? A module that
    --- would cast the same spell on its own clock defers to the rule: two
    --- owners with two lockouts cast it twice as often as either intends.
    --- The live log had Mend Pet six times in thirty-three seconds, half from
    --- the hunter's rule and half from the pet module's healing pass.
    ---@param name string
    ---@return boolean
    function M.has_rule(name)
        local class_module = M.active_class()
        if not class_module then return false end
        local profile = class_module.profiles[active_key or M.active_profile_key(class_module)]
        if not profile then return false end
        for i = 1, #profile.rules do
            if profile.rules[i][1] == name then return true end
        end
        return false
    end

    -- --- tick ---------------------------------------------------------------

    local warned_unsupported = false

    -- ONE SNAPSHOT A TICK, SHARED (1.8.0). The reactions run in a job of
    -- their own just before this module's (modules/react/init.lua, priority
    -- 59 against 60) and read the same snapshot: whichever asks first builds
    -- it, the other reuses it. S is one table, so the tick's re-target below
    -- updates what both read. Nil when there is nothing to run: no rotation
    -- for the class, no profile, dead, mounted.
    local snap_epoch, snap_class, snap_profile, snap_s = -1, nil, nil, nil

    ---@return table|nil class_module
    ---@return table|nil profile
    ---@return table|nil s
    function M.snapshot()
        local key = tick_key()
        if snap_epoch == key then return snap_class, snap_profile, snap_s end
        snap_epoch = key
        snap_class, snap_profile, snap_s = nil, nil, nil

        local class_module = M.active_class()
        if not class_module then
            -- Said once, not every frame. This is the whole point of the fix:
            -- an unsupported class does nothing and SAYS so, instead of
            -- silently running somebody else's priority list.
            if not warned_unsupported then
                warned_unsupported = true
                local name = M.detect_class()
                log.fmt("warn", "no rotation for %s; the rotation is idle",
                    name or "an unknown class")
            end
            return nil
        end

        -- Profile FIRST: it decides which resource the snapshot reads, and a
        -- druid reads mana, rage or energy depending on which one is active.
        active_key = M.active_profile_key(class_module)
        local profile = class_module.profiles[active_key]
        if not profile then return nil end

        local s = build_situation(class_module, profile)
        if not s then return nil end
        if s.player:is_dead() or s.player:is_mounted() then return nil end

        -- Decided once per tick, before anything that could attack. Re-done
        -- by the tick if the target changes.
        s.hold_fire = not s.in_combat and not M.may_engage_unit(s.target)

        snap_class, snap_profile, snap_s = class_module, profile, s
        return class_module, profile, s
    end

    --- Did the priority walk run this tick? The reactions' after-job asks,
    --- so the rotation's pick is read only when there was one.
    ---@return boolean
    function M.walked_this_tick() return walk_epoch == tick_key() end

    --- The walk's last GCD choice: a spell name, or a "(...)" state.
    ---@return string|nil
    function M.last_choice() return last_choice end

    --- In a form for getting about (the class module's `travel_forms`), and
    --- out of combat or moving: the rotation leaves it be (1.7.5).
    local function travelling(class_module, s)
        local list = class_module.travel_forms
        if not list or not P.forms or not P.forms.current then return false end
        if s.in_combat and not s.moving then return false end
        local ok, current = pcall(P.forms.current)
        if not ok or not current then return false end
        for i = 1, #list do
            if list[i] == current then return true end
        end
        return false
    end
    M._travelling = travelling

    function M.tick()
        if not P.opt("rot_enabled", false) then return end
        if not P.rotation_active() then return end

        local class_module, profile, s = M.snapshot()
        if not s then return end

        -- The spell window's projection runs after this tick in the same job
        -- and reads this snapshot rather than building a second one. S is
        -- one table, so a re-target below updates what it will read.
        tick_s, tick_profile = s, profile

        -- THE REACTIONS COME FIRST, APART (1.8.0; modules/react on JCore's
        -- framework). They ran in their own job just before this one, on
        -- this same snapshot, and left a verdict: a reaction took the global
        -- cooldown, or something says stop attacking (a hardcore bail-out,
        -- easing off threat), and the rotation gives way. With them switched
        -- off on the Reactions page there is no verdict, and the fixed
        -- sequence below -- defensives, racials, the hardcore bail-out,
        -- breaking contact, dispels, interrupts -- is the rotation's own.
        local react = P.react
        local verdict = (react ~= nil and react.verdict ~= nil) and react.verdict() or nil
        local reacting = verdict ~= nil

        if not reacting then
            defensives(class_module, s)
            racials(s)
        end

        -- Burst is decided once, before the priority walk, and holds a window
        -- open for the rules below to see. Trinkets and offensive racials
        -- live inside that window now rather than on their own timers, which
        -- is the difference between three cooldowns multiplying each other
        -- and three cooldowns being used on three different mobs.
        if P.burst and P.burst.tick(class_module, s) then return end

        if reacting then
            -- A reaction took the global cooldown, or something says stop
            -- attacking (a hardcore bail-out, easing off threat): the
            -- priority walk does not run this tick.
            if verdict.halt or verdict.gcd then return end
        else
            if P.hardcore and P.hardcore.should_stop_fighting(s) then
                P.hardcore.emergency(s)
                return
            end

            -- The field has its own reason to leave, measured rather than read off
            -- a health bar, and it does not require hardcore mode to be on.
            if break_contact(class_module, s) then return end
        end

        local better = targeting.better_target()
        if better then
            targeting.switch_to(better)
            s = build_situation(class_module, profile)
            if not s then return end
            s.hold_fire = not s.in_combat and not M.may_engage_unit(s.target)
        end

        -- Watched rules: say WHY a rule is held, in the log, whenever the
        -- reason changes. Before the early returns below, so a rule held by
        -- one of those is explained too.
        watch(class_module, profile, s)

        -- TRAVELLING (1.7.5). A druid in Travel or Aquatic Form is going
        -- somewhere: the form keeper below shifted it straight back into Cat
        -- or Bear, so the rotation running meant no Travel Form, and the
        -- escape the reactions cast (Travel Form) was undone a moment later.
        -- Out of combat, or in one while moving (running away), nothing runs,
        -- as on a mount. Standing still in a fight, the profile's form again.
        if travelling(class_module, s) then return end

        -- Form or stance upkeep, for the two classes that have one.
        -- A stance or form picked in the class window is held instead (1.62.0).
        local picked = P.classwin and P.classwin.form_choice() or nil
        if picked and P.forms then
            P.forms.maintain(picked, { [picked] = true }, false)
        elseif profile.form and P.forms then
            P.forms.maintain(profile.form, profile.acceptable,
                P.opt("rot_allow_dance", false))
        end

        -- Class housekeeping that is not a spell: using a conjured item,
        -- applying a stone. Out of combat only, because mid-fight every one
        -- of these is a global cooldown spent on the next fight rather than
        -- this one.
        if not s.in_combat and type(class_module.idle) == "function" then
            local ok_idle, acted = pcall(class_module.idle, s)
            if ok_idle and acted then return end
        end

        -- Housekeeping that cannot wait for the fight to end and costs no
        -- global cooldown (1.73.4): the warlock's shard dump. Whatever it
        -- does, the walk below still runs this tick.
        if s.in_combat and type(class_module.combat_upkeep) == "function" then
            pcall(class_module.combat_upkeep, s)
        end

        -- A debuff ticking outranks a global cooldown of damage, and buffing
        -- only ever happens between pulls.
        if not reacting and dispel(class_module, s) then return end
        if group_buffs(class_module, s) then return end

        -- Player interrupt first, then the pet's. A Felhunter's Spell Lock is
        -- the ONLY interrupt a warlock has, so without this second call the
        -- whole class simply never interrupts -- the pet path was built and
        -- then never wired in.
        -- An interrupt is an attack too: not while holding fire.
        if not reacting and s.target and not s.hold_fire then
            if interrupts(class_module, s) then return end
            if P.pet and P.pet.try_interrupt(class_module, s.target) then return end
        end

        run_rules(profile, s)
        -- The reactions' after-job reads the walk's pick (last_choice,
        -- last_candidates) for the readout and the deferred reaction; the
        -- rotation does not call in there.
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local class_module = M.active_class()
        local key = class_module and (active_key or M.active_profile_key(class_module)) or nil
        return {
            class = M.detect_class() or "unknown",
            supported = class_module ~= nil,
            profile = key,
            label = class_module and key and class_module.profiles[key]
                and class_module.profiles[key].label or nil,
            last_gcd = last_choice,
            last_fast = last_fast,
            form = P.forms and P.forms.current() or nil,
            cast_gate = M.cast_gate_trusted(),
            casting = M.cast_gate_last(),
            wand_detect = H.wand_detection_works(),
            sees = M.awareness(),
        }
    end

    --- Every ability name the active class can reference, for the "not
    --- resolved" readout.
    function M.all_ability_names()
        local class_module = M.active_class()
        if not class_module then return {} end

        local seen, out = {}, {}
        local function absorb(list)
            for i = 1, #list do
                local name = type(list[i]) == "table" and list[i][1] or list[i]
                if name and not seen[name] then
                    seen[name] = true
                    out[#out + 1] = name
                end
            end
        end

        for _, key in ipairs(class_module.profile_order or {}) do
            local profile = class_module.profiles[key]
            if profile then absorb(profile.rules) end
        end
        absorb(class_module.interrupts or {})
        absorb(class_module.defensives or {})

        table.sort(out)
        return out
    end

    ctx.tick(function()
        M.tick()
        M.forecast_tick()
    end, { priority = 60 })

    return M
end

-- Jambix AIO / react / intel / score -- the weights, written down
-- (PvP intelligence, Stage 2; grown by every later stage).
--
-- THE RULE: NO NUMBER WITHOUT ITS REASON. Every weight here says where it
-- comes from: a measured line the plugin already draws (detect.lua's danger
-- scale, the base scale of the reactions), a guide, or an estimate marked
-- as one. The threat score is on detect.danger's 0..100 scale, so the two
-- read alike in the readout: 25 is a cast worth stopping, 55 is where
-- detect.lua's danger turns DEFENSIVE, 80 where it turns EMERGENCY.
--
-- All of it is data, and all of it is tunable from here. Nothing in
-- threat.lua carries a literal.

local S = {}

-- --- the indicators: base points -----------------------------------------
--
-- Each is the points the indicator is worth when it is certain and the hit
-- is now; urgency, reliability, health and protection scale it (below).
S.BASE = {
    -- A player on you with a burst cooldown up (Recklessness, Arcane Power...).
    -- rules/pvp.lua answers it at base 82 of 100 among reactions: "ten
    -- seconds of that is the fight". Estimate on the danger scale.
    burst_on_me = 35,
    -- A dangerous cast aimed at you: 20 plus up to 20 by detect.lua's own
    -- weight for the name (a heal 40, a fear 40, a bolt 25, of 45).
    cast_at_me = 20, cast_at_me_by_danger = 20,
    -- The same cast at an ally: half, and more when the ally is the healer
    -- or under half health (tactics.lua weighs the healer 1.6 over a member).
    cast_at_ally = 10, cast_at_ally_by_danger = 10, cast_at_ally_vulnerable = 1.5,
    -- A melee player about to reach you (time_to_reach from JCore's trail).
    melee_closing = 20,
    -- Inside the reach of a control a player of that class throws
    -- (data.CONTROLS), scaled by how much the control takes away
    -- (data.CONTROL_WEIGHT: a stun 1.0, a snare 0.3).
    in_control_reach = 15,
    -- A player targeting an ally (12), the healer or a hurt one (20).
    ally_targeted = 12, ally_targeted_vulnerable = 20,
    -- A gap closer or sprint seen from a player on you, for MOBILITY_HOLD s.
    mobility_used = 20,
    -- Each attacker past the first (detect.danger uses 8 each, to 24).
    extra_attacker = 10, extra_attackers_max = 30,
    -- Rooted or snared with a melee player on you or closing.
    rooted_threatened = 25,
    -- No escape ready with a melee player on you.
    escapes_gone = 15,
    -- Dying: the field's measured race says fewer than LETHAL_WITHIN seconds
    -- to live (detect.danger gives up to 30 for under 12 s). Up to 40.
    lethal = 40, lethal_within = 8,
    -- Under 30% and being hit (detect.lua's critical line is 25%).
    low_and_hit = 20, low_line = 0.30,
    -- A player vanished beside you (react/pvp.lua, within 3 s): an opener is
    -- coming from somewhere you cannot see.
    vanished = 15,
}

-- --- time until it lands --------------------------------------------------
--
-- "The cheapest moment to deal with a threat is before it arrives" (field.lua).
-- Points fall with the seconds until impact; a thing landing now is whole.
S.URGENCY = {
    { within = 0.5, factor = 1.0 },
    { within = 1.5, factor = 0.9 },
    { within = 3.0, factor = 0.7 },
    { within = 6.0, factor = 0.4 },
    { within = math.huge, factor = 0.2 },
}

--- Seconds a mobility ability counts as "just used".
S.MOBILITY_HOLD = 3.0
--- Seconds a melee player must be from reaching you to count as closing.
S.CLOSING_WITHIN = 1.5

-- --- scaling --------------------------------------------------------------
--
-- Health: at full health a threat is worth HEALTH_FLOOR of itself, at no
-- health HEALTH_FLOOR + HEALTH_RANGE (detect.danger adds (1 - hp) * 40 on
-- top of everything; this scales instead, so the reasons keep their size).
-- 0.8 at full health keeps a sheep two seconds out at MODERATE, where
-- detect.lua's "a big cast is coming at you" turns DEFENSIVE; 1.4 at no
-- health puts a burst with a stun in reach at CRITICAL.
S.HEALTH_FLOOR, S.HEALTH_RANGE = 0.8, 0.6
--- Nothing defensive and nothing to escape with: every threat a little
--- worse (behavior.lua's "survival options exhausted" is the extreme).
S.NO_ANSWERS = 1.15
--- Reliability of a measurement: observed 1.0; the field's damage read on
--- Forever (shared out of your own health, enemies.damage_rate) 0.7; an
--- attacker whose class the client did not name 0.6 for anything read from
--- its role.
S.RELIABILITY = { observed = 1.0, forever_damage = 0.7, role_unknown = 0.6 }
--- What an unknown adds to the top of the band, per unknown, on the scale.
S.UNKNOWN_WIDENS = 10

-- --- the levels -----------------------------------------------------------
--
-- Two lines each (latch.lua's rule: a reading on a line must not flip the
-- answer every frame), and a level steps down only after DWELL seconds
-- below its exit line; it steps up at once. The entry lines sit on
-- detect.lua's own: 25 a cast worth stopping, 55 DEFENSIVE, 80 EMERGENCY.
S.LEVELS = {
    { name = "CRITICAL", enter = 75, exit = 62 },
    { name = "HIGH", enter = 50, exit = 40 },
    { name = "MODERATE", enter = 25, exit = 18 },
    { name = "LOW", enter = 8, exit = 5 },
    { name = "INFORMATIONAL", enter = -1, exit = -1 },
}
S.RANK = { INFORMATIONAL = 0, LOW = 1, MODERATE = 2, HIGH = 3, CRITICAL = 4 }
S.DWELL = 0.6

-- --- the cooldown ledger (Stage 3) ------------------------------------------
S.CD = {
    -- How sure a sighting is: a cast event or a combat-log line names the
    -- spell (1.0); a cast that only started may still be interrupted (0.5);
    -- an aura appearing is a proxy -- the buff a cooldown leaves, read by the
    -- same name (0.7, the plan's figure for the proxy path).
    conf_event = 1.0, conf_log = 1.0, conf_start = 0.5, conf_aura = 0.7,
    -- Once the estimated cooldown has run out, the estimate fades over this
    -- many seconds: it may have been used again unseen.
    decay = 30,
    -- A protection "covers" a threat when it answers this much of it with
    -- this many seconds left (Deterrence covers 0.85 of physical).
    cover_enough = 0.8, cover_left = 1.5,
    -- Reserve the last ready control for a melee player this close to
    -- reaching you, and the last ready defensive for a burst cooldown the
    -- ledger says is back within this many seconds.
    reserve_closing = 6.0, burst_soon = 10.0,
    -- "Ready soon" in the readout.
    ready_soon = 5.0,
}

-- --- the tactical states and the ground (Stage 4) ----------------------------
S.TACTIC = {
    -- A state holds at least this long before a non-emergency one replaces
    -- it (behavior.lua's DWELL is 1.5 s; a PvP moment turns faster).
    dwell = 0.8,
    -- The first seconds of a fight with a player are the opening.
    young_fight = 6.0,
    -- Under this health a player is a kill window to look at (Stage 9 weighs
    -- its defences); detect.lua's critical line is 25%.
    kill_hp = 0.25,
    -- Out of combat under these, recover first.
    recover_power = 0.4, recover_hp = 0.6,
    -- A melee player this close to reaching you is "closing" (score.lua
    -- CLOSING_WITHIN for the threat; here the state turns a little earlier).
    closing_within = 2.0,
    -- A burst that ended this many seconds ago is a counter-attack window.
    counter_window = 12.0,
    -- Our Freezing Trap with this much left is a reset (pvphunter's RESET_MIN_LEFT).
    reset_left = 3.0,
}
S.POSITION = {
    -- Auto Shot aims for half a second (kite.lua AIM_TIME); a move inside
    -- that window costs the shot.
    aim_window = 0.6,
    -- Yards past the minimum ranged distance to step out to (kite.lua's
    -- MIN_RANGE + 1).
    step_out_margin = 1.0,
    -- Allies further than this are "far" when the threat is MODERATE or more.
    allies_near = 30.0,
    -- A target getting away this fast, under half health, with others about:
    -- do not pursue.
    fleeing_speed = 3.0,
    -- Line of sight read on Forever is a model-free ray: trees and rocks do
    -- not block it, so a "clear" there is this sure.
    forever_los_conf = 0.6,
}

-- --- the control plan (Stage 6) -------------------------------------------------
S.CC = {
    -- DRList's rule: the window runs this long from the END of the last
    -- control of the category (Era resets between 15 and 20 s; pvpx.lua
    -- used 18 until 2026-10-11).
    dr_window = 18.0,
    -- DRList's multipliers and names by the count already in the window.
    dr_mult = { [0] = 1, 0.5, 0.25, 0 },
    dr_level = { [0] = "full", "half", "quarter", "immune" },
    -- A control with less than this left is not worth holding damage for
    -- (a global cooldown).
    hold_min_left = 1.0,
    -- An aura of ours without a caster field: "yours" at this confidence
    -- (JCore's aura_is_mine fails open the same way).
    unknown_caster_conf = 0.6,
    -- How sure the category is: Era's list (DRList, checked by name),
    -- Forever's own table, and Era's list used on Forever for a name the
    -- table lacks (an effect aura).
    era_conf = 0.85, forever_table_conf = 0.9, forever_era_fallback_conf = 0.5,
    -- The hold reaction's points per value kind, scaled by its confidence
    -- (estimates on the reactions' scale; a hold halts whatever its score,
    -- the points only rank it among the readout's candidates).
    value_points = { survive = 20, stop_heal = 15, stop_burst = 15, kill = 12, peel = 10, distance = 8, reset = 8, none = 0 },
    -- Two landings of the same category within this many seconds are one
    -- (the aura event and the row read of the same control).
    dedupe = 0.6,
    -- A control's expected duration when neither the row nor the tables
    -- say, and the most the tables' PvE figure is trusted for (Polymorph's
    -- top rank says 50 s).
    duration_guess = 8.0, duration_cap = 20.0,
    -- Another player under this health while one is held: "kill"
    -- (TACTIC.kill_hp); you under this with the held one on you: "survive".
    kill_hp = 0.25, survive_hp = 0.5,
}

-- --- opponent prediction (Stage 7) -------------------------------------------
S.PREDICT = {
    -- Two clocks (the 2026-10-12 review): the recent encounter -- this
    -- fight with the player, within recent_window -- fades with the short
    -- half-life (the brief's "about 60 s"); the session tendency, every
    -- fight with it, with the long one.
    half_life_recent = 60.0, half_life_session = 600.0, recent_window = 120.0,
    -- Observations kept per pattern per player (older ones have faded).
    keep = 12,
    -- The prior every pattern starts at, and how much it weighs against the
    -- observations: with 2, one hit alone reads 0.67 and never passes
    -- min_samples; two hits read 0.75; one hit and one miss 0.5.
    prior = 0.5, prior_weight = 2.0,
    -- A prediction is "sure" at this rate with at least this much weighted
    -- evidence (a single sighting is never a prediction).
    threshold = 0.6, min_samples = 1.5,
    -- The evidence behind a rate, apart from it: reliability = n / (n +
    -- evidence_k), so two chances read 0.5 and are LOW whatever the rate;
    -- six read 0.75.
    evidence_k = 2.0,
    reliability_bands = { { below = 0.6, label = "low" }, { below = 0.75, label = "moderate" }, { below = 2, label = "high" } },
    -- The forecast ledger's bands by the rate forecast (below band_low:
    -- low; below threshold: mid; else high).
    band_low = 0.4,
    -- Adaptation: the recent chances (at least this many) disagree with the
    -- earlier ones (at least this many) by this much.
    adapt_min_recent = 1.5, adapt_min_earlier = 2.0, adapt_gap = 0.35,
    -- The readout shows a pattern forming from this rate.
    forming_show = 0.5,
    -- An inferred observation (who interrupted us, unseen) weighs this.
    inferred_weight = 0.5,
    -- The chances: a gap closer within this many seconds of our slow; a
    -- trinket or breaker within this of our control; two bursts within this
    -- are stacked; the distance opening (closing under -retreat_speed yd/s)
    -- within this of our burst; an interrupt cast within this before our
    -- cast broke.
    slow_window = 2.0, control_window = 1.5, burst_window = 10.0, retreat_window = 5.0, retreat_speed = 1.0,
    interrupt_window = 0.8,
    -- The pet: one chance per window of this many seconds in combat with
    -- the pet out (a full-weight hit or miss); a window not read for pet_gap
    -- closes with no answer.
    pet_window = 15.0, pet_gap = 3.0,
    -- The defensive episode: a player in combat under the watch line with a
    -- defensive usable will pop one (the hit, at the health it appears) or
    -- fall to the floor without (the miss). Popped under defensive_low it is
    -- "saved until low".
    defensive_watch = 0.6, defensive_floor = 0.15, defensive_low = 0.35,
    -- The opener: the first cast seen this many seconds into a fight; none
    -- seen is no answer.
    opener_window = 6.0,
    -- Calibration: a confident prediction that fails moves the prior down
    -- this much, one that holds up half of it, within these bounds.
    prior_step = 0.1, prior_min = 0.2, prior_max = 0.8,
}

-- --- bait detection (Stage 8) ------------------------------------------------
S.BAIT = {
    -- No bait at this threat or above (the brief: never while Stage 2 says
    -- HIGH or CRITICAL); the trinket bait, which spends a control, only
    -- while the threat is at most this.
    max_threat = "HIGH", cc_max_threat = "MODERATE",
    -- The cheap shot a mobility bait and a trinket bait press, the real
    -- control the trinket bait follows with, and the cast an interrupt
    -- bait shows (at 26 the hunter's only cancellable cast).
    cheap_slow = "Concussive Shot", cheap_control = "Concussive Shot", real_control = "Freezing Trap",
    cancellable_cast = "Aimed Shot",
    -- The counters a mobility bait wants ready, best first, each scaling
    -- the bait's confidence; `room`: yards between you the trap needs to
    -- be laid and armed before the charge lands (Charge's own minimum is 8).
    counters = {
        { name = "Freezing Trap", factor = 1.0, room = 10 },
        { name = "Scatter Shot", factor = 0.9 },
        { name = "Wing Clip", factor = 0.6 },
    },
    -- A player already this close is not baited into closing.
    melee_gap = 6.0,
    -- The defensive bait: the burst is held when the player is within this
    -- much health of its predicted defensive (the burst would be eaten);
    -- an unseen defensive is held for at this confidence; the fillers need
    -- this much mana to keep the pressure.
    defensive_margin = 0.15, unseen_conf = 0.55, min_power = 0.3,
    -- The reaction's points per bait kind, scaled by the bait's confidence
    -- (the rotation is 40; survival and escape start at 85).
    points = { mobility = 12, cc = 10 },
    -- Once pressed, the same bait on the same player waits this long.
    repeat_after = { mobility = 10, cc = 15 },
}

-- --- the fight debrief (Stage 11-a) -------------------------------------------
S.DEBRIEF = {
    -- Fights kept in the log on disk, moments and lessons kept per fight.
    keep = 50, moments_keep = 24, lessons_keep = 6,
    -- A fight ends when nobody of it has been seen this long (they left),
    -- or nobody fights and you are out of combat this long; no new fight
    -- opens within this of a close (the picture keeps the last one a while).
    gone_after = 10.0, end_after = 6.0, restart_after = 2.0,
    -- A class that can go unseen and return (Vanish, stealth, Prowl) is
    -- waited for this long before "they left": its re-opener is the same fight.
    stealth_gone_after = 30.0, stealthy = { ROGUE = true, DRUID = true },
    -- A window a lesson rests on counts from this many seconds; the trap
    -- lesson from this many seconds of a melee player on you.
    lesson_min = 3.0, trap_min = 5.0,
    -- "Danger" for the defensive lesson: HIGH threat, or under this health.
    low_hp = 0.4,
    -- A melee player on you: within this; "unslowed": no slow of yours cast
    -- in this many seconds.
    melee_reach = 5.0, slow_recent = 8.0,
    -- The kill window: a player under this health for this long that lived.
    kill_hp = 0.25, kill_window_min = 2.0,
    -- Your own control broken by you: it ended with this much left within
    -- this many seconds of your cast at it.
    own_break_left = 1.5, own_break_window = 0.6,
    -- Casts of ours that break a control besides the damage list (data.OUR_DAMAGE).
    breaking_casts = { ["Wing Clip"] = true, ["Counterattack"] = true, ["Strider Kick"] = true, ["Lacerate"] = true,
                       ["Concussive Shot"] = true, ["Hunter's Mark"] = false },
    -- The hunter's trap.
    trap = "Freezing Trap",
}

-- --- the decision episodes (the collector) ----------------------------------
-- The result categories and the exact rule for each (episodes.lua
-- judge_result): SURVIVAL_IMPROVED -- your health held within hp_better
-- and the threat fell a level, or fewer were on you, or the control on
-- you ended; POSITION_IMPROVED -- from melee or the dead zone to ranged,
-- or the gap grew gap_improved yards with the player on you;
-- CONTROL_SUCCESSFUL -- a control of yours on the player held
-- control_held seconds; DAMAGE_OPPORTUNITY_CREATED -- it lost foe_hp_drop
-- of its health while you were free, or its defensive ended;
-- COOLDOWN_SAVED -- it spent a trinket or a burst while you spent no
-- cooldown, or the threat fell with your defensives unspent;
-- OBJECTIVE_PROGRESS -- it died, or you took the flag; SITUATION_WORSENED
-- -- you died, lost hp_worse, the threat rose, you were controlled, or it
-- reached you from range; NO_MEASURABLE_CHANGE -- none of these; UNKNOWN
-- -- the window was cut, or the result would rest on inferred data.
S.EPISODES = {
    max_per_fight = 40, max_open = 6, dedupe_window = 3.0, events_keep = 16, actions_keep = 16,
    hp_better = 0.05, hp_worse = 0.15, gap_improved = 5.0, foe_hp_drop = 0.15, control_held = 2.0,
    -- A predicted defensive threshold counts as hit within this of the health it came at.
    threshold_tolerance = 0.15,
    -- A lesson candidate's confidence from comparable episodes (same type
    -- and class) this session: fewer than low_below is a candidate; the
    -- same result in fewer than `agree` of them is contested; then low,
    -- moderate, high by count. Never a rule from one anecdote.
    confidence = { low_below = 3, moderate_below = 6, high_below = 12, agree = 0.6 },
}

-- --- the field checks (fieldcheck.lua) ----------------------------------------
S.FIELD = {
    -- A trap counts as laid in melee with a hostile within this; its effect
    -- is looked for this long. Disengage: a mob on you within this reach,
    -- turned off you within this long. A sting at an add: its success this
    -- long after the request. Feign Death: the cast's own end plus this.
    melee = 5.0, trap_window = 5.0, disengage_reach = 6.0, disengage_window = 3.0,
    sting_window = 2.0, feign_slack = 0.5,
    -- A control landing this soon after the last one on the same player
    -- ended is the next step of its chain (diminishing returns).
    chain_window = 18.0,
    -- The file is written at most this often.
    save_every = 10.0,
}

-- --- the central database --------------------------------------------------
S.CENTRAL = {
    -- The manifest (and the server's status) are asked for this often, and
    -- once at start, while downloads are on.
    refresh_every = 1800.0,
    -- A pattern's rate from the network seeds a new player's prior only when
    -- the model calls it reliable and this many fights back it.
    min_fights = 10,
    -- The upload queue on disk: at most this many items (the oldest leave
    -- first), each tried this many times, waiting base x 2^(tries-1) up to
    -- the cap between tries.
    queue_max = 60, max_tries = 8, backoff_base = 30.0, backoff_max = 1800.0,
    -- Forecast observations kept per fight; past this they are counted as
    -- censored ("buffer full") in the batch. Decision episodes sent per fight.
    observations_max = 120, episodes_max = 40,
}

return S

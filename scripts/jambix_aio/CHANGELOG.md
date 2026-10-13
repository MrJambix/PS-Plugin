# Changelog

Jambix AIO 1.7.8 · JCore 1.8.1 · Jambix Debug 1.1.0

# Jambix AIO

## 1.7.9 (not released yet)
**What the second batch of real fights showed, fixed (2026-10-13).** Seventeen fights with players in 23 minutes (a hunter 30 on Forever's PvP realm: 12 won, 2 lost both one against five, 3 the enemy ran), read back from the network's issues #14 to #30; the user: "fix all the issues".
- **What is on a player is not always what it did.** A rogue "used" Power Word: Shield twice, a priest Blessing of Protection, a paladin Aimed Shot (no enemy hunter in that fight). An aura's caster came with every UNIT_AURA record and was dropped; the picture now keeps it on the row (`by`: the wearer, another unit, or unknown), and `state.own` reads a row as not the player's own doing when another unit cast the aura or the spell belongs to another class in the client's own tables (`pvp_data.lua`, a name only one class has). Its cooldowns, its habits (the predictor's "uses a defensive at a health line" was learning a priest's shield as the rogue's) and what the debrief says it used now count its own doing only; the rest -- the threat, the kill window, the teamfight, the episodes -- still see the shield on it, which still protects it. The debrief says *Enemy gets Power Word: Shield from another at 40%*, and the feeds line counts *N not the player's own*. Tests: new `aio_intel_attribution_test` (5).
- **Each fight's own clock.** Five fights carried an episode stamped 29 to 66 s into a fight of 0 to 16 s, and one forecast past its fight's end: both read the fight's start off the debrief's last fight, which stays there after it closes, so an episode or a forecast between fights (or on a fight's first tick) was timed from the fight before and sent with the next. Both now read only a fight that is running; at its close each episode is timed from the fight's own start (one that opened just before it at 0) and one whose window closed before the fight began is dropped and counted (`dropped_outside`). Test: `aio_intel_attribution_test`.
- **A fight is never 0 s long.** Two kills under half a second went up as "0 s" and the network set them aside as impossible; the duration sent is whole seconds rounded up.
- **The fight's forecast score is a mean.** The Brier score each fight uploaded was the sum over its forecasts (1.75, 2.71 where 0 to 1 is the scale); it is the mean now, the sum kept beside it (`brier_sum`). The page's line was already right.
- **The records say their revision** (`client.rev = 2`), so the network repairs the older ones and holds these to their numbers (`CENTRAL_NETWORK.md` §14).
- Not yet seen in game.

**What the first real PvP fights showed, fixed (2026-10-12).** The user's three fights with players that evening (a hunter 29 against the rogue Buck twice and the druid Iheart), read back from the fight log, the upload queue and the API recorder; the user: "let's fix the first 9".
- **A player that leaves is not a player that died.** Fight 1 was recorded "won, Buck died" with Buck never under 72% and you at 3%; Buck killed you 26 s later. Fight 3, "won, Iheart died", at full health 4 s in. JCore's `units.is_dead` answers true for a unit that has gone (right for targeting, wrong for an outcome), and a Vanish or a player slipping out of sight is a unit gone. A death is now only a unit still there that the game calls dead (`lib.unit_dead`, the debrief and the episodes both); a rogue or a druid unseen is waited for 30 s (10 s for the rest) before "they left", so a Vanish and its re-opener are one fight. Tests: `aio_intel_debrief_test` (the vanish returning to kill you: one fight, lost; a priest out of sight: fled; a real death still won).
- **Enemy spells: what reaches us, counted.** In all three fights the enemies' "used" lists were empty, while the API recorder shows Forever firing their casts and auras under "target" and "softenemy". The picture now resolves a token through JCore, then the object manager's own lookup, then (for "target") your target, and counts every enemy event it keeps or drops -- dropped ones by the token's kind, not a player, not attackable. Each fight's record, page and uploaded lesson carry it (*Enemy events this fight: 3 cast(s), 1 aura(s) kept; 12 dropped (unresolved: softenemy 12)*), so the next fights say where they go. Meanwhile silence is no evidence: the defensive bait no longer reads "its defensive unseen this session" as anything until an enemy event has been seen at all. Tests: `aio_intel_debrief_test` (the feeds), `aio_intel_bait_test`.
- **"Goes for your pet" is one chance a window.** It was sampled every second at half weight: 60 of the session's 80 checks, 40 in one fight where a rogue simply stayed on you, so the forecast score looked excellent and the network's 20-check bar filled from one fight. Now one chance per 15 s window in combat with your pet out: on the pet within it is the hit, on you through it the miss, a window cut short no answer. Test: `aio_intel_predict_test`.
- **The hold stops an attack already running, and a broken control names what broke it.** Fight 1's Freezing Trap broke with 2.4 s left while the hold stood three times: the hold halts the rotation's walk, but an attack already running went on, and the only stop for it lived inside the walk (and skipped Forever). While the control plan holds the player you have targeted, a running auto attack is now stopped on every client, at most once every 2 s. The debrief blames a damaging cast of yours by name, else your pet on it, else your running attack, else nothing of yours (and no lesson): *your Arcane Shot broke your Freezing Trap Effect on Enemy (6.0s left)*; a Hunter's Mark is no longer "your hit". Tests: `aio_intel_debrief_test`.
- **Upload problems are kept.** The last ten (time, kind, status, error) are saved with the queue (`scripts_data/jambix.aio.central_queue.json`), so the cause of the five-times upload can be read after the next session.
- **Field checks: the game's answers to what was assumed** (`intel/fieldcheck.lua`). A trap laid in melee: did its effect show on a mob in reach within 5 s? Disengage with a mob on you: did it turn off you within 3 s? Serpent Sting sent at a mob that is not your target: did it go out? Feign Death against a player's cast: did the cast fail? And on Forever, how long each of your controls lasted on a player by its place in a chain (the diminishing returns, measured). Counted across sessions in `scripts_data/jambix.aio.fieldchecks.json`, a log line when a verdict forms or changes, and on the Reactions page under the fight debrief (*Field checks -- a trap laid in melee springs under the mob: yes (3 of 3); ...*). Nothing acts on them. Test: new `aio_intel_fieldcheck_test` (5).
- **One issue per fight.** On the GitHub backend a fight's lesson and batch now travel in one issue (`jambix-fight <id>`), halving the issues and the network's work; the service files both (older clients' separate issues still work). Test: `aio_intel_central_test`.
- Not yet seen in game.

**The shared network sent the same fight five times.** The first live uploads (2026-10-12): one fight's batch was filed as issues #2 to #6 while the client counted every try a failure, and the fight's lesson and two more fights waited behind it. Now a 2xx answer is delivered whatever the reply says; after a try that ends with no status or a server error, the next asks GitHub whether the issue is already there (by its title, among the network's last hundred issues) and stops if it is; every failure is logged with its status (`central: batch try 2 failed (status 0): ...`); a queue saved by an earlier session is due at once, and an item tried before is looked for first. `modules/react/intel/central.lua`. Test: `aio_intel_central_test` (+1). Not yet seen in game.

**The kill window (PvP intelligence, Stage 9).** Is the player about to die, or to get away? For each enemy player a verdict -- *no kill*, *build pressure*, *force a defensive*, *prepare the burst*, *a high-confidence kill window*, or *abort* -- weighed from its escapes and defensives seen ready, seen down or never seen (an unseen one counts as available, at a cost: missing information never makes a kill surer), an enemy healer near it, its own heals, your burst and mana, the threat on you, other players on you and allies on it. *Kill: PREPARE_BURST (0.53) -- Enemy at 20%; 3 of its outs never seen (counted as available)*. The KILL_WINDOW state speaks with its words and confidence; the burst window opens at once on a kill window and stays shut on a defensive to draw or an abort; the PvP hunter's "finish the low one" asks it instead of "under 20%". New conditions *The kill window on my target* and *...how sure %*, on the bench too. `intel/killwindow.lua`, `score.lua` KILL, `data.lua` CLASS_ESCAPES / SELF_HEALERS, `states.lua`, `burst.lua`, `rules/hunter_pvp.lua`. Test: new `aio_intel_killwindow_test` (7). Not yet seen in game.

**Teamfights (PvP intelligence, Stage 10).** With more than one player a side, the fight read as a whole: whom the enemies focus (*3 enemies on you*); a peel -- an enemy on your healer or on an ally under half health, with the first tool of yours that reaches it (Scatter Shot past 8 yd, Wing Clip in melee, Intimidation with the pet on it; *nothing of yours reaches it* from the dead zone), never a player an ally already holds; which cast to stop first (a heal on a low enemy, then a control at one of you, then a dangerous cast) and with what; a better target (yours immune, or held by an ally's control -- then no control or damage of yours on it -- or a kill window elsewhere); the enemy healer free, and Viper Sting for its mana; overextended (your group far, enemies near) and outnumbered (disengage). PROTECT_ALLY and INTERRUPT_OPPORTUNITY take its picks. A fourth readout row and Live lines only in a group fight; eight new *Teamfight:* conditions and bench toggles. Allies' cooldowns cannot be read, so only your own overlap is prevented. `intel/team.lua`, `score.lua` TEAM, `data.lua` HEALS / CONTROL_NAMES. Test: new `aio_intel_team_test` (7). Not yet seen in game.

**The history ledger and the scenario bench (Stage 11-b).** Each fight with a player keeps what the layer said and how good it was: forecasts scored this fight and how many were right; your major cooldowns spent, and the ones spent while a defensive already up was enough; your control on a player already held, your defensive over another; how often the advice changed (per 10 s); advice you could not follow (an ability not trained or not ready when it was said). No kill or win rate. The newest 100 fights in `scripts_data/jambix.aio.history.json`, the figures on the Reactions page and in the Reactions window's Live view, and on Forever in the recorder's trace. Switch: *History ledger* (on). The brief's eighteen scenarios -- a warrior's gap closer, a warrior with mobility left, a rogue's opener and its reset, a mage's Blink and its Polymorph on you, a warlock's Fear, a healer under pressure, the dead zone, the pet about to break a trap, several enemies, an immunity, no defensives left, a low enemy with its outs unseen, a class the client does not give, a wrong prediction, PvP turning into PvE, a missing client ability -- each played through the engine with its expected state, the advice it must and must not give, and its fallback; the same eighteen are bench presets (*Situation: Scenario: ...*). They found two gaps, fixed: **polymorphed or stunned by a player, the advice was still Aimed Shot or the clip** -- DEFENSIVE now says you are held and asks for no cast (the break-control reaction decides the trinket); **a rogue's Vanish turned the layer off** unless the PvP hunter's mode was on -- a player vanishing beside you is now itself a sign of a PvP fight. `intel/history.lua`, `score.lua` HISTORY, `custom_data.lua` BENCH_PRESETS, `states.lua`, `state.lua`. Tests: new `aio_intel_history_test` (4), new `aio_intel_scenarios_test` (19). Not yet seen in game.

**What the layer costs (Stage 12).** Measured at 60 frames a second with ten enemy players and four allies: the layer's own calls into the game were 22 a frame, nearly all the fight record asking every player's unit whether it was dead; that answer is now kept a quarter second a unit, and the layer costs 1.4 a frame (the rows still say a death at once). Each module reads at its own pace (the kill window 5 times a second, the team 4, the history 2), line of sight goes through `geometry.sight` only (at most twice a second; the client's `is_line_of_sight` never, it crashes Forever), at most ten players are carried. Stale state now also goes on a new target (the kill window and the team read again at once), a new pet (the recall asked of the old one stands down) and logging out (the fight's history closed and written, every player forgotten). *Chasing through bad terrain*, the tenth pattern, stays unbuilt on purpose: reading it wakes the walk map, whose rays round you every tick are the path the Forever ray crashes came through. Test: new `aio_intel_perf_test` (3). Not yet seen in game.

## 1.7.8 (2026-10-12)
**Released as 1.7.8, with JCore 1.8.1.** The work below was done under the working labels 1.8.0 and 1.8.1, never uploaded; 1.7.8 is the number chosen for this upload (the last version committed to the repository is 1.7.6), and the code's comments still tag things 1.8.0 or 1.8.1. AIO needs JCore 1.8.0 or newer (`MINIMUM_CORE`): released without JCore 1.8.1 it would refuse to start on the live JCore 1.7.9, so the two go up together. The shared PvP network ships off on every client (three consent switches, all off), and with an address only when the release carries the `JAMBIX_CENTRAL_CONFIG` secret.

**From the first live PvP death (2026-10-12): the debrief crash, and PvE threat answers at a player.** The user's log of a Shadowfang Keep run and a world fight with Astro (level 30) that ended in death.
- **The crash.** On your death the fight debrief wrote its record with `os.time`, and the game's Lua has no `os` table: `debrief.lua:530: attempt to index global 'os' (a nil value)`, first in the death handler, then on every tick as *the intel build failed*, so the whole PvP intelligence layer stood still until a reload; the fight was never logged or shared. The network client had the same call in its start-up (`math.randomseed(os.time ...)`), which also meant its random ids were never seeded: every player could have drawn the same contributor id and the same record ids. Now `intel/init.lua` gives the layer one wall clock (the realm's time, else the PC's where `os` exists, else none) and one id maker seeded from what differs between two machines (a fresh table's address, the session clock, the wall clock, your character's id hashed into the seed only); the debrief, the episodes and the network client use them. The end of a fight is five steps (record, local log, log line, banner, share), each protected on its own: one failing is logged (`T.last_error`) and never stops the rest or the layer.
- **Disengage and Growl at a player.** *Shed threat* pressed Disengage at Astro twice ("it left the pet for you"), and the pet's taunt asked for Growl at it. On Forever Disengage only drops threat, and a player has no threat table, so both were wasted presses in a fight that was lost. The situation *the pet lost its mob* is now never true for a player target (which also keeps Intimidation's *give the pet its mob back* off players; its burst and cast-stop uses are unchanged), and the pet's taunt never lists a player.
- Tests: `aio_intel_debrief_test` (a fight lost with no `os` and no `_G`: the close, the log, the queued lesson under a fresh 24-hex id, the next fight opening; it fails with the log's exact error on the old line), `aio_react_test` (a player leaving the pet: no Disengage, no Growl; fails without the fix).
- Not yet seen in game.

**The global learning engine: how the network learns, and what stops it learning wrong.** The user's brief *Global PvP Learning, Prediction & Tactical Knowledge Engine*. Mostly the service side, in `tools/fightlog_server/`, with the client reading what it publishes; `CENTRAL_NETWORK.md` §11 has the whole design.
- **Learning groups** (`groups.js`): every record is filed at four levels -- exact (game, your class, theirs, your level bracket, the encounter, 1v1 or outnumbered), matchup, class, general -- with the game in every key, so Forever and Era never share a number. The client walks them narrowest first (`central.lua` `prior_for`), draws a broader level's rate toward even odds by its certainty (exact 1, matchup 0.85, class 0.7, general 0.5), and the predictor's reason names the level it came from.
- **Opponent models** (`learn.js`): per group and pattern, the chances, hits, misses and censored ones, a rate shrunk toward 0.5, a 95% interval on the effective count (a fight's forecasts are one cluster, not independent draws), the forecast quality as it stood and its calibration, conditional rates by threat and your health, drift by build (a new build that behaves differently sets the old builds aside), and whether a matchup stands apart from its class enough to need its own model. Unreliable entries say why.
- **Tactics as associations**: eight of the brief's nine strategies read off the decision episodes (protecting allies is not measured: no record carries an ally), each comparing two arms within one group, stratified by your health, the attackers, the threat and a ready defensive; an interval, a strength, `causal: false` always, the counterexamples and the condition that told them from the successes, and *stale* when it stopped working in the last 30 days.
- **Poisoning and domination** (`trust.js`): duplicate content under a new id, replayed episodes, impossible numbers (past the fight's end, more than three forecasts a second, fifteen all sure and all right, a shared fight id) and more than 40 fights a day from one contributor are quarantined with the reasons and audited; inside the learner unverified inputs weigh half, no contributor holds more than 40% of a group, an outlier against the median of the others weighs half, and a group one person dominates is not offered.
- **Evaluation and release** (`evaluate.js`, `release.js`): the earlier 70% of fights teach, the later 30% test, against production, the plain prior and the baseline (Brier with its error, calibration, coverage, false positives, by matchup and game, paired fight by fight, plus recommendation stability). Gates: two contributors, usable content, not worse than the prior or production, calibrated, and a material change -- else *hold*, so the model does not flap on noise; with no record since the last cycle it is *unchanged* and writes nothing. Versions carry their gates, evaluation, rollback and limitations; the first goes out full, later ones as a canary to 25% of clients by contributor id, promoted by hand; withdraw rolls back. Each batch now says which model version its client ran under, so a canary's own record in play is read before promotion.
- **On the client**: `prior_for` reads the grouped model (older class-only models still read), honours the canary share, and `advice_for` shows validated tactics as words labelled *association*. No model ever becomes a rule; a test holds it.
- The repository's Action: `evaluate`, `publish` (now gated), `publish --force`, `promote N`, `withdraw N`; the HTTP service gains `/v1/knowledge/tactics`, `/v1/admin/promote`, `/v1/admin/audit`.
- Tests: new `learn.test.js` (10), `test.js` and `github_ingest.test.js` follow the gated publish (Node, 23 in all); `aio_intel_central_test` +4 (the levels and the backoff, the canary, the model version in the batch, no rule from a model).
- Tested on synthetic records only. No contributor has sent a record, so the network has learned nothing yet.

**The crash at the character select screen (2026-10-12).** The loader started the plugins at the character screen, and the game died 0.2 s later: `ASSERT(IsLoaded())` in `WowClientDB2.cpp`. AIO's start-up (spell names for the class tables) ran there, because the plugins load before JCore and start from their own poll. It now waits on JCore 1.8.1's `JCore.in_world()` as well as on JCore. See JCore 1.8.1 below. Not yet seen in game.

**Hunter: the melee weave is Beast Mastery's, the sting on every mob, Disengage on a switch, and the pet kept off crowd control.** The user: "add AOE melee weave into our Normal Beast master rotation no longer alpha/test", "add a button Turn it on if being attacked to disengage", "better Pet management when things like CC kick off on a mob", and "the Rotation doesn't automatically Look for All targets in combat with us and drop a Sting on them how come?"
- **Beast Mastery has the melee weave in it.** The AOE melee weave's switch (*AOE melee weave (ALPHA/TEST)*) and its profile are gone; a value the switch saved changes nothing. Beast Mastery now: Multi-Shot first with two or more mobs where it lands and **never on one** (the weave's rule; the one-mob quick shot when Aimed Shot would not land is gone, and Aimed Shot gives the shared cooldown to Multi-Shot from two mobs, not three); two hawks at all times, the refill included; Rapid Fire on two or more mobs or one that lives 10 s, in melee or out (it waits for the pet's first hit, like the hawks); in melee, Immolation Trap (Explosive Trap round two or more), Raptor Strike, Mongoose Bite, Strider Kick, Counterattack, Lacerate and the swing, at a mob on you or one on the pet you walked up to; Auto Shot pressed again the moment you are back out. You walk in and out yourself: once Tame Beast is trained, the step out stands aside while Beast Mastery runs (the run-and-shoot before it is still the kite's). The class window's line under the hunter's switches says which side you are on, the stings and the hawks.
- **Why the sting missed the other mobs, and the fix.** Two reasons, both fixed. (1) The engine's spread took the first mob the sting rule liked and pressed there; when that mob could not be reached -- an add hitting you in melee, inside the dead zone, out of range or out of sight -- the press failed and no other mob was tried. Now the spread skips a mob the spell cannot reach and asks the next (`rotation.lua` `ask`, every class's spread, the warlock's DoTs too), and the sting rule itself leaves out a mob in the dead zone. (2) The wait for the pet's first hit was asked about every add with one clock, so each add restarted it for the next: while the pull's target was not yet on the pet or on you, two adds were never stung. Only the pull's target waits now. **Serpent Sting on** gains *Every mob fighting you*, now the default (it was *Up to 3 mobs*; a value you saved stays). The spread never stings a mob held by crowd control.
- **The target swap is a fallback.** The weave's reaction moved your target from mob to mob for the stings, and with it Auto Shot and the assisting pet. The stings now go straight onto each mob, your target kept; the reaction, renamed *Beast Mastery: sting the next mob*, moves the target only to a mob that has gone 4 s needing a sting all the same, and only while Beast Mastery runs.
- **Disengage when a mob hits you** (hunter option, off; the class window and Hunter options). Forever's Disengage is Classic's threat drop -- the client's `SpellEffect` gives its three ranks one effect, 63, as Era's -141/-281/-406, melee range, 5 s cooldown -- not a leap. On, the new reaction *Disengage when hit* hands a mob hitting you in melee back to the pet fighting it (in a group, to the tank), your target first, else the nearest; never with nobody else on the mob, never on a player. It needs Reactions on. Off, nothing presses Disengage for you: the class gates it through `key_gated`, which the rotation, every reaction (*Shed threat* included), the escapes and the hardcore bail-out all ask; `key_gated` now takes a function as well as a key.
- **Intimidation was never pressed, on any client.** The user: "what about intimidation? I learned it recently from my talents but i dont see it being used". Two gates. (1) Its catalogue row needs the pet on the target, and the rule casts it on yourself: the gate compared *your* guid with the pet's target, which never matches, so the rotation and all three Intimidation reactions (*save the pet*, *give the pet its mob back*, *stop the cast*) were refused every time. On yourself the need now reads "the pet is on a mob" (which mob is the rule's to say); aimed at a mob, the pet on that mob, as before. (2) Forever does not say what the pet is attacking (1.73.1), and the rule (and Bestial Wrath's) asked the client alone. The pet module now answers `P.pet.fighting()`: the client's answer, else the mob the pet was last sent at while it lives, for 30 s -- the reading the reactions already used. **Kept for when it counts.** The user, next: "it stunts target and next sucess full attack gains 100% critical chance and Generate high threat so it should be used ina Burst, Interrupt (stunt) or when I really need a mob off me and Disengage is not available". Intimidation is no longer a rotation filler. (a) **The burst:** it joins the class's burst sequence after Bestial Wrath (the pet's next hit a sure crit inside the window), vetoed while the pet is on nothing or the mob is held by crowd control; the rotation's own rule presses it only inside a burst window (a window whose sequence went by before the pet was on the mob), never on a mob about to die. (b) **The stun on a cast:** *Stop the cast with crowd control*, unchanged (Scatter Shot first, Intimidation when the pet is on the caster). (c) **A mob off you:** *Intimidation: give the pet its mob back* now only for a mob actually on you (not one whose threat says it is about to turn), only when Growl cannot, and only when Disengage cannot hand it back -- its switch off, untrained, on its cooldown, or the mob out of its melee reach -- and not for 2 s after a Disengage went out (the mob turns back a moment later; without the wait both went on one mob). *Intimidation: save the pet* (the pet about to die under its mob) stays. A whole-plugin Forever run with a pet the client says nothing about presses it once, inside the fight's one burst window.
- **When the hunter bursts in PvE, from the guides.** The user: "Let's look at the Burst Window when we should burst in PVE and what skills should be considered for busrt look up guide on this". No Forever guide has a cooldown section yet (read 2026-10-11). wowtbc.gg: "Cast Rapid Fire, Bestial Wrath, and any on-use effects" then "Cast Intimidation"; Mobalytics: Rapid Fire solo only "on harder encounters" because it "might pull enemies off your pet", freely in groups; Icy Veins (Classic): everything "together on pull" with a tank. The user chose Mobalytics' rule. **What:** Rapid Fire, Bestial Wrath, Intimidation, the racial, the trinkets (unchanged but for Intimidation). **When, solo:** a harder fight only -- an elite, rare or boss, 3+ mobs, a fight being lost, or a mob living 20 s+ -- and once the pet holds the mob; the ordinary levelling mob no longer opens one ("burst freely" took any 9 s fight). **With a tank:** freely, as before. Rapid Fire (the weave's own rule fired it on any pack or 10 s mob) and Bestial Wrath (on its cooldown while levelling) now go out in a burst window only. New in `burst.lua`: the reason a window would open (`losing`, `pack`, `elite`, `freely`) and a class's `burst_veto(s, kind, lasting)`; the hunter's is the solo rule.
- **The pet and crowd control.** 1.7.6 kept the pet off *your target* while it was held. Now nothing sends the pet at a mob held by control that damage breaks (a sheep, sap, blind, fear, your Freezing Trap, Scatter Shot or Scare Beast) or aims a pet skill there, whoever asks: the assist, the defence, Tank, Focus, a reaction's send or a custom reaction's. The mob the pet is actually biting is checked every pass, so one sheeped under it is left for your target if that is free and in the fight, else for what is hitting the pet or you, else the pet comes home; it is kept off that mob 3 s while it turns round, and an assignment on a mob that gets held ends. On Forever JCore reads a mob's control from its debuffs only in a fight, so a sap, or a trap or sheep laid before the pull, read free: `out_of_fight` now reads the debuffs itself for a mob within 40 yd that is out of a fight (JCore's breakable names, at most every 0.25 s per mob).
- Internal: `classes/hunter.lua` (the weave's helpers now `weave_*`; `weave_running`, `weave_status`, `key_gated`; `suggest` remembers its answer; the `aoe_weave` profile, `aoe_running`, `aoe_status` gone; `lead`/`first` skip the wait while spreading; `spread_ok` asks crowd control); `react/rules/hunter.lua` (the renamed sting reaction with its grace, *Disengage when hit*); `pet.lua` (`cc_held`, `off_held`, the guards in `send`, `cast`, `assigned`); `react/init.lua` (`out_of_fight`'s debuff read); `rotation.lua` (`ask`'s reach check, `H.key_allows` with a function, the catalogue's `pet_on_target` on a self-cast, `pet_target_guid` through `P.pet.fighting`); `kite.lua`, `classwin.lua`, `classwin_data.lua`, `custom_data.lua`.
- Tests: `aio_hunter_test` (the weave tests rewritten for Beast Mastery; the spread without the pet's wait; the default cap, a held mob and the dead zone; the pet off crowd control; the Disengage gate; the kite standing aside only from the pet levels), `aio_hunter_pvp_test` (the sting reaction's grace; *Disengage when hit*), `aio_rotation_test` (the spread past an unreachable mob; `key_gated` with a function), `aio_forever_class_hunter_aoe_test` (the old switch on runs Beast Mastery), new `aio_forever_class_hunter_intimidation_test` (Intimidation pressed with a pet the client never names a target for; `mock/forever_class.lua` gains the `hunter_intimidation` loadout and `pet_blind`), and in `aio_rotation_test` / `aio_hunter_test` the self-cast gate, `pet.fighting` and the Intimidation and Bestial Wrath rules.
- Not yet seen in game. To check there: that a sting goes onto an add you are not facing (the spellbook skips the facing check; if the client refuses, the 4 s fallback moves the target); that Explosive and Immolation Trap laid in melee spring; that Disengage hands the mob back on Forever.

**The decision episodes: a fight as training records a reader can check.** The user's brief *PvP Combat Experience & Lessons Learned Collector*: `modules/react/intel/episodes.lua`, `CENTRAL_NETWORK.md` §10.
- **A bounded window round each tactical moment** the brief lists -- a melee player closing the gap, a rogue opening on you, a mage's Blink, an enemy's burst, a root with players on you, the dead zone, the pet on a control, a kill window, the opponent's defence changing, several players on you -- opened on its observable trigger, 4 to 10 s long, at most six open and forty a fight.
- **Each answers the brief's ten questions** from named sources: the state before (the threat as the previous tick read it: before the behaviour, not with it), the trigger with its source and whether it was observed, the tied pattern's prediction as it stood, the recommendation as it stood (the state's first action, the move, the bait, the hold), your casts and whether you moved, the events, the state after; then the prediction's outcome (HIT, MISS, CENSORED, INVALID, NONE), the recommendation's (FOLLOWED, NOT_FOLLOWED, UNKNOWN, each with its reason) and the result, one of nine categories by a rule written in `score.lua EPISODES` with the measure in words.
- **Nothing contaminates**: duplicate triggers open nothing and are counted; an inferred trigger makes the prediction INVALID; missing feeds make it INVALID; a window cut is CENSORED and its result UNKNOWN; a result that would rest on inferred data reads UNKNOWN; under the test harness every episode is test data, the network client refuses the fight, and the service refuses the record.
- **Lessons never from one anecdote**: a candidate per episode, its confidence from the comparable episodes of the session (candidate under three, contested below 60% agreement, then low, moderate, high); the fight's summary keeps one per type, class and result; the service validates an episode lesson only with six measured episodes from two contributors agreeing, and publishes the result shares when the recommendation was followed and when not.
- Where it shows: the fight's record and the page (*Episodes: 7 -- predictions hit 3, miss 1 ...; Results: ...; Candidate (low): ...*), the batch to the network (compact, no names, forty at most). Switch: *Decision episodes* on the Reactions page.
- Tests: `aio_intel_episodes_test` (13), `test.js` (+2).

**Fight debriefs: the lessons of each fight with a player.** The user: "each PvP fight should also be a lessons learned: what the player used, what I could have used to win or play better." `modules/react/intel/debrief.lua`, the brief's Phase 16 in part:
- **Each fight is recorded** from the first tick a player is on you (or your player target fights) to its end -- they died (won), you died (lost), they left (fled), you got away low (reset), everyone standing (draw): who was in it (class, role, health low, died, fled, time on you), what each used (their cast and aura events, bursts, trinket, defensives), the controls they put on you, what you used, your health low and seconds under control, the threat's peak, the states, the baits offered, the holds, and up to 24 moments in words.
- **The lessons** rest on seconds of a window and name what they rest on: a defensive that stayed ready through danger (HIGH threat or under 40%), a melee player on you with a slow ready and none cast, the trap never laid while a melee player spent 5 s on you, a kill window (under 25% for 2 s) that got away, your own control broken by your own hit, dangerous casts not stopped with a stopper ready; what beat you (the controls, a burst that took the fight, a trinket spent); what held (the trap laid and won, the controls kept); the predictor's forecasts this fight. The longest window first, six at most.
- **Where it shows**: the log (one line), a banner (the outcome and the first lesson, a warning on a loss), the Reactions page's new section *Fight debriefs and the shared network* (the last fight: how it ended, what each side used, your lows, the lessons), and `scripts_data/jambix.aio.fights.json` (the last 50, your own file, names kept). Switches: *Fight debriefs*, *Say each fight's outcome and first lesson*.
- A fight's death is read off the enemy rows and the unit (the picture drops a dead player at once); no new fight opens within 2 s of a close; a player counts as seen only with a row this second.
- Tests: new `aio_intel_debrief_test` (8).

**The shared PvP intelligence network: the client, the service, and the repository as the service.** The user: "all those fights recorded in a central point where all players use my reactions, so it learns from a database" -- then the full brief (*Central PvP Intelligence Network*) -- then "the database can be GitHub: MrJambix/PS-Plugin". `scripts/jambix_aio/CENTRAL_NETWORK.md` is the design, audit and status; in short:
- **Consent, off by default.** Three switches on the Reactions page -- *Contribute my fights*, *include extra detail*, *Download the network's learning* -- and two buttons: *Delete queued local submissions*, *Request deletion of my uploaded records and start a new identifier*. The section says what goes up, when, what never does, how long it is kept and how to withdraw.
- **The client** (`modules/react/intel/central.lua`): every forecast the predictor scores is an observation (the forecast as it stood, the outcome, the evidence, the input reliability, the context); each fight's batch and lesson are queued on disk (60 at most, the oldest first out), sent one at a time with backoff (30 s doubling to 30 min, 8 tries, a refusal for good dropped at once), through JCore's net service, never in a combat tick's way; the model comes down by a manifest (schema, plugin range, active or withdrawn), only a compatible active version is adopted, a withdrawn one is dropped, the cache serves offline; a reliable entry with enough fights seeds a new player's prior in the predictor and says so. No name travels: the records carry classes, roles, ability names and codes under a random contributor id (a pseudonym, replaced on request).
- **Two backends.** The GitHub repository itself (`github = { repo, branch, token }`: the uploads are issues the repository's Action files away, the model is read off the data branch), or an HTTP service (`url`, `key`). Configured by `modules/central_config.lua` (shipped; `central_config.example.lua` shows both forms) or `scripts_data/jambix.aio.central.json`.
- **The service** (`tools/fightlog_server/`): `server.js` (the versioned routes: batches, lessons, manifest, models, knowledge, client status, privacy delete; a shared key, body and rate limits, validation with the reason, duplicates by id, retention, deletion by id; publish and withdraw under an admin key), `validate.js` (every bound; forbidden fields such as a name refused anywhere), `learn.js` (per opponent class and pattern: the rate, the chances, the fights, the contributors, the forecast quality as a Brier score, the verified-input share, `unreliable` with `why`; the matchup lessons that told won from lost; abilities per fight; calibration bands), `github_ingest.js` (the issues to the data branch, publish, withdraw) and `.github/workflows/jambix-central.yml`.
- **Not learning yet**: no contributor has sent a record; an entry is offered only once several contributors, enough chances and a measured forecast quality back it.
- Tests: `aio_intel_central_test` (8: off by default; the batch and lesson one at a time with no name; offline with backoff, refusal and 429; the bounded queue, deletion, the id replaced; downloads, compatibility, withdrawal; GitHub as the service; the issue body limit; the cache offline, a malformed model); `node --test tools/fightlog_server/test.js` (8) and `github_ingest.test.js` (3).
- Not yet run against a live service or repository from a live client.

**The predictor reworked on review: seven changes.** The user's review of Stage 7 (2026-10-12), each point taken in `modules/react/intel/predict.lua`, `data.lua` `PATTERNS` and `score.lua` `PREDICT`:
1. **Every pattern is a question with four parts**, written in `data.lua`: the chance (when it is asked), the hit, the miss, the attribution; and two more that were missing: the inputs a miss rests on, and the ability the player must have usable. New: the defensive episode (in combat under 60% with a defensive of its class usable, it pops one or falls under 15% without -- before, there was no miss); a stacked-burst window that passes quietly is now the miss (before, only the next burst could record one); an Aimed Shot that goes through a player in its interrupt's reach with the interrupt usable is now the interrupt pattern's miss (before, no miss existed); an opener not seen within 6 s of a fight is no answer, not a miss; a Rapid Fire with the player's movement never read is unverified, not a miss.
2. **The rate and the evidence are two numbers.** `p` is the estimated rate; `reliability` is `n / (n + 2)` on the weighted chances, labelled low under 0.6, moderate under 0.75, high above: two chances read 0.5 and LOW whatever the rate. Both are carried everywhere -- the readout (*p 0.75, reliability low, n2.0*), the banner, the Live view, the window (`target.pattern_reliability`, `prediction_reliability("...")`, the bench's *the evidence behind it*) -- and the bait's confidence is the rate times the evidence (two chances: half).
3. **The player's abilities, from the ledger**: ready (seen, back), down (seen, running), estimated (never seen, the tables have it), unknown. A slow on a player whose gap closers are all down, a control on one whose trinket is down and breakers down, a defensive episode for a class without one: not a chance -- skipped, counted and said in the basis (*1 skipped: Charge back in 12s, Intercept back in 25s*).
4. **Two clocks.** The recent encounter (this fight with the player, within 120 s, a 60 s half-life) and the session tendency (every fight, a 600 s half-life). The headline follows the recent when it has evidence, the session otherwise, and says which (*basis*); a tendency learned two fights ago still predicts, as it did not before.
5. **Adaptation.** When the recent chances disagree with the earlier ones by 0.35 or more (at least 1.5 recent, 2 earlier), the player is *adapting*: the prediction is withdrawn, the readout says *predict: adapting -- earlier 0.80 over 3.0 chance(s), now 0.25 over 2.0: it changed*, the window's pattern reads none, and the baits stand down with that reason.
6. **Forecasts scored when made.** Every chance snapshots the forecast as it stood -- the prior on the first, a weak 0.67 on the second, a sure one later -- and the outcome is scored against that snapshot: a Brier score, counts by band (low under 0.4, mid, high), how many fell on the right side of 0.5, and the sure ones' hit count; nothing later rewrites a past forecast (`W.intel.predict.ledger`, per pattern, for Stage 11). The prior still moves on a sure forecast only.
7. **Inputs instrumented** (`W.intel.predict.inputs`, the Live view's *Inputs* line: *casts 12, auras 4, interrupted 0 (unverified), control ends 2, targets 31, motion 40*): enemy casts, enemy auras, our interrupted casts, controls ending, enemy target reads, player movement. A miss is recorded only once the inputs it rests on have been seen live this session; until then the chance is unverified, counted and said -- on Forever, where enemy events are unverified, a silent feed can no longer read as a player that never answers.
- Tests: `aio_intel_predict_test` rewritten (16): the switches; rate against evidence with the labels and the banner; chances skipped (a priest's slow, a warrior's closers down); a miss unverified until its input is live; the two clocks and the fade; adaptation and the bait standing down; the forecast ledger scored at the time, weak forecasts included, the prior on the sure one; the defensive episode's hit, miss and skip; the interrupt's observed, inferred and let-through; escape, stacked bursts, the pet, the opener with no cast seen, backing off with and without movement read; the window and the Live view. `aio_intel_bait_test` reads the scaled confidence. A test lesson: the ledger settles an ability's state on the tick, so a test that moves the clock steps before asking.

**PvP intelligence, Stage 8: the bait -- a moment to make a player spend its charge, its defensive, its kick or its trinket.** The brief's Phase 7 (bait opportunity detection), as `modules/react/intel/bait.lua`: the first stage to act on a prediction, and only through `intel.sure` with the evidence line met, only with the counter ready, and never while the threat is HIGH or CRITICAL.
- **Four baits on the current target.** *Mobility*: it closes the gap the moment it is slowed (the predictor), it is not on you yet, Concussive Shot is ready and a counter is -- the trap with 10 yd of room for it (full confidence), Scatter Shot (0.9) or the clip (0.6). *Defensive*: Rapid Fire or Bestial Wrath ready and the mana to keep the pressure with the fillers, and its class's defensive unseen this session (the ledger) or, once the predictor knows the health it pops at, the player within 15% of it -- the burst is held and said so. *Interrupt*: it interrupts your casts, its interrupt reaches you (Kick, Pummel 5 yd; Counterspell, Spell Lock, Silence 30; Earth Shock 20; Feral Charge 25) and Aimed Shot is ready: advice to show the cast and stop it, nothing is cancelled here (the user's own reaction with `stop_cast` may). *Trinket*: it breaks a control at once, its trinket not seen used, no burst up on it, the threat at most MODERATE, Concussive Shot and the trap ready: the cheap control first, the trap after. The surer bait wins; the list keeps them all.
- **The gates, before any bait**: the threat under HIGH; you not controlled; no control of ours being kept on it (the control plan's hold); its defensive not up; the target a living player.
- **One reaction, *Intel: the bait*** (utility, priority 52, under the survival and escape bands), presses the Concussive Shot a mobility or a trinket bait asks for, validated by the engine like any other, and not again on the same player for 10 / 15 s. The defensive bait presses nothing: it is `W.intel.bait.hold_burst` for the burst's own gate to read (burst.lua is the hunter session's file today) and advice until then. The interrupt bait presses nothing.
- **Where it shows.** The third intel row (*bait: bait its charge: Concussive Shot with Freezing Trap ready (0.75)*, or *bait: none -- threat HIGH* while a prediction stands); the Live view's *Bait* line and *Rapid Fire kept: a defensive bait* among what is kept; the condition *PvP bait on my target* (`fight.bait`: mobility, defensive, interrupt, cc, none), on the bench too.
- The switch *Cooldown baiting* on the Reactions page (built, no longer under advanced). Weights in `score.lua` `BAIT`; data in `data.lua` (`CLASS_DEFENSIVES`, `CLASS_INTERRUPT`, `INTERRUPT_REACH`), each with its source.
- Tests: new `aio_intel_bait_test` (7): the switch; the mobility bait pressed once and its counters; the defensive bait's hold, the seen defensive and the threshold; the interrupt bait's reach; the trinket bait and a burst up; the three gates with the Live view and the condition; precedence. `aio_intel_window_test` checks the condition on the bench.
- Not yet seen in game. The baits rest on the predictor's inputs, so the same Forever probes stand.

**PvP intelligence, Stage 7: what each player tends to do, from this session, never from one sighting.** The brief's Phase 6 (opponent prediction), as `modules/react/intel/predict.lua` on the picture, the control plan and our own casts. Nothing here decides or presses: the predictions are the readout's, the Live view's, a banner's, the window's conditions, and Stage 8's bait detection reads them through `intel.sure`.
- **Nine of the brief's ten patterns, counted per player (by GUID, this session only)**: *closes the gap when slowed* (our Wing Clip or Concussive Shot, then a gap closer within 2 s); *a defensive at about N% health* (the health when a defensive aura appeared, averaged) and *saves its cooldowns until low* (under 35%); *interrupts your casts* (our cast broken with an interrupt seen cast within 0.8 s, observed; none seen, the player on you, inferred at half weight and the basis says so); *escapes control at once* (a trinket or breaker within 1.5 s of our control, from the control plan); *stacks its bursts* (two within 10 s); *goes for your pet* (one sample a second in combat, half weight each); *the same opener* (its first cast of each fight against the last fights'); *backs off under pressure* (the distance opening within 5 s of our Rapid Fire or Bestial Wrath). The tenth, *chasing through bad terrain*, is listed as not built: it needs the walk map's clear line behind the player.
- **How sure.** Each observation is a hit or a miss with a weight, fading with a 60 s half-life, blended with a prior of 0.5 that weighs two observations: one hit alone reads 0.67 and never passes the evidence line (1.5 weighted samples), two read 0.75, one and one read 0.5. A prediction is "sure" at 0.6 with the evidence line met; the readout shows one forming from 0.5. **Calibration**: when a confident prediction stood as a chance began and the outcome came in, the pattern's prior moves -- down a step (0.1) on a miss, up half a step on a hit -- and `W.intel.predict.calibration` counts predicted against right per pattern, for Stage 11's ledger. A zone change, a death or entering the world forgets every player (the picture's own reset); nothing is persisted.
- **Where it shows.** The third intel row (*predict: it closes the gap the moment it is slowed (0.75, n2.0)* or *predict: forming (...)*); the Live view's *Predict* lines (the surest first, with the response; a forming one with its basis); one banner per player and pattern when a prediction forms, as a guess with its number (*prediction -- Enemy: it closes the gap the moment it is slowed (0.75)*), behind the state's and the move's banners. **Conditions**: *Target's surest pattern this session* (`target.pattern`), *Confidence in the target's surest pattern %* (`target.pattern_conf`), and in Lua `prediction_confidence("mobility_when_slowed")` (0 to 1). The bench has the two. Each pattern carries its consequence, the hunter's response and a fallback (`data.lua` `PATTERNS`).
- **Two switches** on the Reactions page, now built: *Opponent prediction* (off: nothing predicted, nothing counted) and *Opponent pattern learning* (off: the counts freeze, the predictions stand), the second under advanced.
- Weights in `score.lua` `PREDICT`; data in `data.lua` (`PATTERNS`, `NOT_BUILT_PATTERNS`, `OUR_SLOW_CASTS`, `OUR_BURSTS`, `INTERRUPTS`), each with its source. The engine hands the predictor our own `UNIT_SPELLCAST_SUCCEEDED` and `UNIT_SPELLCAST_INTERRUPTED` (the "player" token the picture's handlers skip).
- Tests: new `aio_intel_predict_test` (11): the switches; one sighting then two, the banner once, a miss and the prior; the defensive's threshold and saving-until-low; the observed and the inferred interrupt; escape after control; stacked bursts; the pet; the same opener; backing off; decay and the zone change; the window's readers and the Live view. `aio_intel_window_test` checks the two conditions and the function on the bench.
- Not yet seen in game. Unverified there: the same two Forever probes as Stage 6 (enemy `UNIT_AURA`, the aura list's caster), and that `UNIT_SPELLCAST_INTERRUPTED` arrives for "player" on Forever.

**The decision panel names the last press again.** The on-screen panel's *Rotation: Arcane Shot 39.5* line now carries what came of it underneath (*pressed Arcane Shot*, or *last Arcane Shot 0.4s ago; next Serpent Sting*), as it did before the engine's move to JCore; `aio_react_test`'s end-to-end hunter checked for it and had failed since.

**PvP intelligence, Stage 6: the control plan -- whose control, what breaks it, its diminishing returns, what it is worth, and the one thing to hold.** The brief's Phase 8 (crowd control and pet control awareness), as `modules/react/intel/ccplan.lua` on the picture and the ledger; one engine, and the only thing it does is a hold.
- **Every control on every enemy player**, each tick: its name, kind and seconds left (JCore's row: Era's loss-of-control read, Forever's debuff read); **whose** it is -- the aura's caster where the client's aura list carries one, "yours" at 0.6 when it carries none (JCore's own aura matching fails open the same way), "not yours" when another unit's; **what the player could break it with** (its trinket as seen used, its class's breakers as the ledger saw them); **who of ours would break it** (the pet on it; a Serpent or Viper Sting, an Immolation or Explosive Trap of ours ticking on it); **what keeping it is worth**, in the order a fight asks -- you under half health with it on you (survive), it heals (stop_heal), its burst is up (stop_burst), another player under a quarter (kill), it was on an ally (peel), a melee player held (distance), you low on health or mana (reset), or nothing; and **the chain**: the trap under a scattered player while Freezing Trap is ready.
- **Diminishing returns, tracked again** (the deleted PvP extras were the only tracker): each control landing is counted per category from the aura events and the row read (the same landing twice is one). On **Classic Era** the categories are DRList-1.0's list by name and the rule is DRList's -- full, half, quarter, immune, an 18 s window from the end of the last one, a landing where the rule said immune starts a new chain. On **Forever** the category comes from the client's own table (`SpellCategories.DiminishType`, extracted into `pvp_data.lua`: 1 root, 4 stun, 8 Mind Control, 16 incapacitate, 32 fear, 64 silence, 128 Kidney Shot, 256 Distract; an effect aura the table lacks, such as *Freezing Trap Effect*, takes Era's list at 0.5), the count is observed, and **the multiplier is UNKNOWN: nothing on Forever ever claims a halved duration**. The hunter's trap rules (*trap first* in the class, the PvP hunter's *Scatter into the trap*) ask the plan: on Era "immune" holds the trap back, on Forever it is laid.
- **One reaction, *Intel: keep the control on your target*** (category cc, a hold): no damage on the current target while a control that damage breaks has at least a global cooldown left on it and keeping it is worth something, or the trap could follow a Scatter Shot. Anyone's control counts (an ally's sheep on a healer is not yours to break). A hold stops the rotation's presses and nothing else: on Era an Auto Shot already running is stopped by the hunter class's own hands-off (Forever fires one shot per press). With a tick of yours on it there is no hold -- the control is as good as gone -- and the readout says so. Behind *Crowd control planning* on the Reactions page (now built, no longer under advanced).
- **The pet** is not recalled by this layer: pet.lua's own "the pet kept off crowd control" (this version) does that; the plan says the reason (`W.intel.cc.pet`: "the pet is on X, held by Y (4.1s): its next bite breaks it") and the window's *My pet is on a player held by a control that damage breaks* now reads the plan.
- **pvphunter.held checks the caster** (the audit's defect 10): another hunter's trap no longer reads as ours, so the trap-reset walk and the CROWD_CONTROL_SETUP / RESET_FIGHT states fire on our own control only; an aura without a caster field still counts as ours, marked unread.
- **The readout** gains a CC piece on the second intel row (*CC hold: Freezing Trap Effect on X, 8.0s left (yours): a melee player held...; DR incapacitate x1 -> half; pet: off X*), the Live view a *Control* line and the pet's recall among what is kept, the unknown list "an ally's damage about to break a control (no read)". **Three more conditions**: *The control on my target is worth keeping for* (`target.cc_value`), *Diminishing returns: what my next control on the target gets* (`target.dr_next`: full, half, quarter, immune, unknown), *The control on my target is mine (or its caster is unread)* (`target.cc_ours`); *Seconds left on the control on my target* now reads the plan's row. The bench has the three too.
- Weights in `score.lua` `CC` (the window, the multipliers, the confidences, the hold's points), data in `data.lua` (`DR_ERA`, `DR_FOREVER_TYPES`, `BREAKERS`, `OUR_DOTS`), each with its source.
- Tests: new `aio_intel_ccplan_test` (10): the switch; the hold with its words and the window's readers; the caster unread and another hunter's trap; the pet's recall; a sting of ours (no hold); nothing to gain, then the chain; under a global cooldown and a stun; DRList's rule by aura events and the window's end; Forever's table and UNKNOWN multiplier; the three values. `aio_intel_window_test` checks the three new conditions on the bench.
- Not yet seen in game. Unverified there: that Forever's `UNIT_AURA` arrives for enemy players' debuffs (the count depends on it; the row read counts the one control it shows either way); whether a control's `caster` field is filled on Forever's aura list.

**The Reactions page is the engine and the PvP intelligence, nothing older.** The user, 2026-10-11: "remove all other reactions from the menu that don't have to do with these phases ... we want to drop/delete old stuff and not get it confused." Gone from the page and deleted with their modules and tests, not hidden:
- ***PvP*** (the *Use the PvP trinket* dropdown). The reaction *PvP: break the control* stays and runs at its Balanced line (40); the *Only to stay alive* (60) and *Break any control* (1) lines are gone, and a saved choice changes nothing.
- ***PvP marks*** (`modules/pvpmarks.lua`): the red curtain on the lowest player in reach, the green on players seen healing, your crowd control on them as rings, their trinket's ring.
- ***PvP extras*** (`modules/pvpx.lua`): the diminishing-returns rings and the tracker behind them, the flag carriers' beacon, the stealth rings. The hunter's trap rules (*trap first* in the class, *PvP hunter: Scatter into the trap*) no longer ask about diminishing returns: every control is taken as full until the PvP intelligence's control plan (Stage 6) answers.
- ***In the world*** (`modules/plays.lua`, `modules/react/marks.lua`): the ring filling toward a reaction of yours, the rotation's pick curtain and target ring, the kick lined up, who a reaction acted on, the control ring at your feet, the vanish and burst curtains.
- The World marks page's *Curtains* list loses the six that were theirs (ten remain); the render job at 125 is gone and the one at 111 draws the rest.
- What stays: *Reactions in the rotation*, *Decisions*, *Advanced PvP Intelligence* and the readouts. The Reactions window's code is untouched: the built-in reactions and your own are the engine, not the menu, and the brief's rule stands ("integrate into the existing Reactions framework; do not create a second engine").
- **The *Use reactions in the rotation* switch is gone** (the user: "this shouldn't be... reactions should automatically activate in PvP when PvP is detected"). The engine is the path again (1.32.0): `R.active()` and the custom layer's `master_on()` always say yes, a value a player saved before changes nothing, and the Hardcore bail-out holds the attacks through the reactions as it did with the switch on. The PvP reactions and the intelligence layer wake when PvP is detected (the intelligence's signs: a player targeted or on you, an enemy player within 40 yd, a player's control on you, a battleground, an arena, a duel; under it, the picture's `env.pvp`), and the page's first live line now says what is detected: *Reactions: automatic | PvP detected: 1 player(s) on you | ...* or *no PvP sign: no enemy player within 40 yd*. The reactions outside PvP (interrupts, defensives, the pet, the stings on every mob) run as before: nothing of this switches them off. Tests: `aio_boot_reactions_test` and `aio_react_test` now check a saved "off" changes nothing.
- **The *Open Reactions UI* button is gone too** (the user, a moment later: "should be removed from being accessed by the player but leave it in the code for future"). `modules/reactwin.lua` stays loaded and rendered, `P.reactwin.open(tab)` still opens it from code, and nothing a player can reach does; the built-in reactions and any of your own already saved keep running from their saved state. `aio_boot_reactions_test` now checks the button is absent and opens the window from code for the rest of its run.
- Tests: `aio_pvpmarks_test`, `aio_pvpx_test`, `aio_plays_test`, `aio_react_marks_test` deleted; `aio_boot_beacons_off_test`, `aio_esp_split_forever_test` and `aio_pvp_test` trimmed of the removed switches.
- Not yet seen in game: the page's new shape.

**PvP intelligence, Stage 5: the switches, the bench and the Live view.** The brief's Phase 13, the Reactions framework integration: the layer on the Reactions page and in the Reactions window, every module behind its own switch, and the Try-it bench carrying a made-up picture so every intel condition can be tried without a fight. One engine, as before.
- **A new section on the Reactions page, *Advanced PvP Intelligence*:** *PvP intelligence* (the emergency switch: off, nothing of the layer runs), *Say each new tactical state and move on screen*, then one switch per module -- *Threat evaluation*, *Cooldown management*, *Hunter PvP tactics*, *Positioning awareness*, *Kill window detection*, *Teamfight awareness* -- and, under advanced, the four not built yet (*Crowd control planning*, *Opponent prediction*, *Cooldown baiting*, *Opponent pattern learning*), each saying which stage brings it. All on. A module off reads calm: no threat (INFORMATIONAL, 0), no state, no move, no ledger answer; the two rules that ask the ledger stand down; the kill and team switches gate their states. A note under them says what the layer presses (the aspect, through the Aspects window's own switch) and that everything else is advice.
- **The Try-it bench** (the Reactions window, step 6) gains a *PVP INTELLIGENCE* group: the threat level and score, the tactical state, the move advice, a dangerous cast coming, the target's gap closer and defensive, the abilities seen from it and how long until they are back, the seconds left on the control on it, a defensive of yours covering you, the dead zone, a safe escape, the pet on a held player. `custom.lua`'s made-up picture fills a `W.intel` from them, so *PvP threat level*, *PvP tactical state*, *Target was seen using*, `enemy_cd_ready_in("Sprint")`, `me.protected` and the rest answer on the bench the way they answer in a fight; a new situation, *PvP: a warrior bursting on me*, has them set. *From the fight now* copies the live picture into the bench.
- **The Live view** gains a *PvP intelligence* block while the picture is on: four tiles (the tactical state with its confidence, the threat with its score, the next action, the move with its confidence) and the lines under them (why, the threat's top reason, the move's reason, up to four abilities seen from the target, what was kept back, what is unknown).
- **Three more conditions**: *A kill window on my target* (`f_kill_window`), *Seconds left on the control on my target* (`t_cc_left`, for "about to expire"), *My pet is on a player held by a control that damage breaks* (`pet_breaks_cc`); in Lua `fight.kill_window`, `target.cc_left`, `pet.breaks_cc`. With these, every condition the brief's Phase 13 names has a row but the three that wait for their stage: prediction confidence and opponent pattern (Stage 7), and a crowd-control planner's "about to expire" beyond the control's own clock (Stage 6).
- **The built-in view** lists *Intel: the aspect for the moment* under the hunter's reactions with its description, and its Open world / Dungeon switches like any other.
- Internal: `main.lua` (the section); `intel/init.lua` `I.module_on(name)` and the gating; `intel/cooldowns.lua` `enabled()` and the hooks' stand-down; `intel/states.lua` the kill and team gates; `custom.lua` (`bench_world`'s `W.intel`, `situation_now`'s copy, the three readers); `custom_data.lua` (the rows, the preset, `DEFAULT_INFO` and `DEFAULT_CLASS` for the aspect rule, the API text); `reactwin.lua` (the bench group, the Live block).
- Tests: new `aio_intel_window_test` (5): every module switch and the master switch; the kill and team gates; the preset passing fifteen intel conditions on the bench and failing when the fields flip; *From the fight now* copying the live picture and the copy passing the same conditions; the three new conditions live.
- Not yet seen in game. To check there: the bench group's dropdowns at the window's text sizes; the Live block's height against the view's scroll.

**PvP intelligence, Stage 4: what kind of moment this is, where to stand, and the words.** The brief's Phase 3 (the tactical states), Phase 9 (positioning), the hunter half of Phase 11 and Phase 15 (reasoning), on the picture, the threat and the ledger. Three modules under `modules/react/intel/` and the first reaction file of the layer; one engine, and nothing in the layer moves the character.
- **The tactical state** (`intel/states.lua`): the brief's eighteen, each a row with what makes it, what it recommends, what to avoid, what to keep, its rank and how sure it is. DISENGAGE (ESCAPE, or CRITICAL with no defensive ready), ANTI_BURST (a burst on you: the ledger's answer -- preserve, the cheapest, or none), DEFENSIVE (threat HIGH or more, or low health with a player on you), INTERRUPT_OPPORTUNITY (a dangerous cast at you with Scatter Shot, Intimidation or Feign Death ready), CONTROL_DISTANCE (a melee player in melee or closing: Wing Clip first, step out, Monkey, the trap once the clip does not shake it; never Aimed Shot in melee), RESET_FIGHT (a player frozen in your trap: walk to 25 yd), CROWD_CONTROL_SETUP (a player held by your control: no damage on it), PROTECT_ALLY (the healer or a hurt ally targeted), PEEL_ENEMY (a melee on anyone), KILL_WINDOW (a player under 25% with no immunity, at half confidence: Stage 9 weighs its defensives), COUNTER_ATTACK (its burst ended), OBJECTIVE_CONTROL (carrying the flag outranks everything but an emergency; an enemy carrier near outranks a peel), OPENING (the first six seconds at range), SUSTAINED_PRESSURE, RANGED_PRESSURE, RESOURCE_RECOVERY and PREPARATION (out of combat), BAIT_OPPONENT (Stage 8). An emergency takes over at once; otherwise the state in force keeps 0.8 s while it still holds, and the highest-ranked candidate replaces it after that, or at once when it no longer holds. What the ledger keeps is kept here too.
- **The move** (`intel/position.lua`), for a hunter: hold, increase, reduce, strafe, break or regain line of sight, stay near the allies, avoid the reinforcements, do not pursue -- with the direction in words, the yards, the reason and how sure. A melee player in melee and unslowed: hold, slow it first (running gains nothing: kite.lua's rule). Slowed or held: step out past the dead zone. A warrior at range: keep out of the 8-25 yd its Intercept reaches, by the client's own table through the ledger (Charge cannot be used in combat, the Classic tooltip says, so it is no reach on a player already fighting) -- unless the ledger says Intercept is down, then hold and shoot. Past the bow: close. Out of its sight: regain it, or keep it so while the threat is HIGH and it is a caster. Two or more others about: away from them. Allies far with a MODERATE threat: towards them. A target getting away under half health with others about: do not pursue. Inside Auto Shot's aim window the move waits for the shot. On Forever a clear sight ray is 0.6 sure (trees do not block it); with no ray read, 0.8.
- **The aspect for the moment** (`react/rules/intel.lua`, the layer's one reaction so far): Aspect of the Monkey with a melee player on you, Hawk back once nobody is -- through the Aspects window's own gate, so with *Auto swap aspects* off nothing moves.
- **The words** (`intel/explain.lua`): one summary per tick (the state and why, the highest threat, the recommended action, the move, the target's observed cooldowns, what was kept back or avoided, what is unknown) for the readout's third row -- "Intel: state CONTROL_DISTANCE (0.90): Enemy in melee, not slowed | do: Wing Clip, step out past the dead zone, Aspect of the Monkey | avoid: Aimed Shot in melee | keep: Scatter Shot | move: hold: Enemy in melee and not slowed: running gains nothing, slow it first (0.90)" -- and one alert on screen per change of state or of move advice, through the narration module, at most one every three seconds; `intel_alerts` (on) switches them off. A guessed thing carries its confidence; a duel reads "duel?"; a kill window says Stage 9 will weigh the defensives.
- **Your own reactions can read it**: *PvP tactical state* (`f_tactic`), *PvP move advice* (`f_advice`), *My target is inside my minimum ranged distance* (`me_dead_zone`), *A safe escape is available* (`me_safe_escape`: one ready, nothing unslowed in melee with you); in Lua `fight.tactic`, `fight.advice`, `me.dead_zone`, `me.safe_escape`.
- Internal: `intel/score.lua` gains `TACTIC` and `POSITION`; `intel/init.lua` runs the three after the ledger and adds the third readout row; `react/init.lua` loads `rules/intel` for the hunter; `main.lua` one more readout row; `custom_data.lua` and `custom.lua` the conditions and choices; the test bundle gains the Aspects window, the narration module and the fight's age.
- Tests: new `aio_intel_tactics_test` (13): no PvP; PREPARATION; OPENING then SUSTAINED_PRESSURE at once; CONTROL_DISTANCE unslowed and slowed, the step out, the aim window; the aspect through the window's switch; the Intercept band and Intercept seen down; ANTI_BURST at once, DEFENSIVE, DISENGAGE; RESET_FIGHT and CROWD_CONTROL_SETUP; PROTECT_ALLY, PEEL_ENEMY, the flag; KILL_WINDOW and a bubble, COUNTER_ATTACK; the dwell; RESOURCE_RECOVERY, the summary and the alerts; the window's conditions.
- Not yet seen in game. Guesses to check there: that the Aspects window's switch takes the layer's Monkey the way it takes the reaction's Hawk; that the narration banners read well at a fight's pace.

**PvP intelligence, Stage 3: the cooldown ledger, and whether another answer is needed.** The brief's Phase 5: "Professional PvP is fundamentally about resource exchanges." `modules/react/intel/cooldowns.lua`, on the picture and the threat read, and nothing here decides.
- **The clients' own tables, generated.** New `tools/jcheck/pvp_extract.js` reads, for some 300 abilities a PvP decision asks about per client (every class, the racials, the warlock's and hunter's pets; the names are the only thing typed by hand, every one already used by the plugin), what the Era 1.15.9 and Forever 1.60.1.70338 tables say: the cooldown (`SpellCooldowns`, the spell's own or its category's, whichever is longer), the shared category (Forever's Freezing and Frost Trap, category 2183 at 30 s; Era's at 15 s, category 411; Forever's Aimed and Multi-Shot, category 2 at 6 s), the mechanic (`SpellCategories`, else the effect's), the dispel type, the range, the duration, the school, the level, every rank's id, and on Forever `DiminishType` (Era's table has no such column: Scatter Shot 16, War Stomp 4). Written to `modules/pvp_data.lua`, a plain table, one half per client; Era's half leaves Season of Discovery's rune versions out (ids 400000 and up). The names a client lacks are printed, not invented (Era: Summon Hawk, Strider Kick, Lacerate, Sniper Shot, Bane of Agony; Forever: Wyvern Sting, Silencing Shot, Elemental Mastery, Dark Pact, Curse of Agony).
- **Theirs: the ledger.** Every ability seen from a player (the picture's recent ring: a cast event by unit token, the buff a cooldown leaves, on Era the combat log's cast line) becomes an entry in that player's ledger with when it was seen, through what, how sure (a cast event or a log line 1.0, a cast that only started 0.5, an aura 0.7) and, when the tables carry its cooldown, when it is back; a shared category holds its sisters down; a started cast that was interrupted went on no cooldown; once the cooldown has run out the estimate fades over 30 s (it may have gone again unseen). A spell never seen is **unknown, never ready**; one the tables do not carry is "cooldown unknown".
- **Ours, and the economy questions**, as functions a rule or a later stage asks: `sufficient(kind)` (is a protection of ours up enough -- 80% of the kind -- for long enough -- 1.5 s -- that another defensive against it would be spent for nothing); `cheapest(kind)` (our ready defensives and controls, cheapest cooldown first, by the same tables: against a warrior's Recklessness the Freezing Trap's 15 s before Deterrence's 300); `answer(kind)`, the brief's own decision: **preserve** when covered, else the **cheapest**, else **none** ("escape, control or line of sight instead"); and what to **keep**: the last ready control for a melee player closing (within 6 s of reaching you, none in melee yet), the last ready defensive for a burst the ledger says is back within 10 s on a player on you.
- **Two existing reactions ask it** (a `validate`, nothing else changed): *PvP: answer the burst* holds a defensive on yourself while the protection up already covers the burst's kind (a control on the burster still goes); *Defensive cooldown* holds the same against what is on you. Never under critical health; never outside a PvP picture. The journal says "already covered: Deterrence covers 85% of physical for 7.9s; keeping Deterrence".
- **The readout** (the second intel row): "cds: target: Sprint back 290s (cast 1.0), Blind cooldown unknown | covered: Deterrence 7.9s | keep Freezing Trap (Enemy closing (3.0s): the last control ready) | Recklessness: preserve, Deterrence covers 85% of physical for 7.9s". Without the data file for the client: "no pvp_data for forever: cooldowns unknown".
- **Your own reactions can read it**: *Target was seen using* (`t_cd_seen`), *Seconds until the target's ability is back* (`t_cd_ready_in`; 999 when never seen or unknown), *A defensive of mine already covers me* (`me_protected`); in Lua `enemy_cd_seen("Sprint")`, `enemy_cd_ready_in("Sprint")`, `me.protected`.
- Internal: new `intel/cooldowns.lua`; `intel/score.lua` gains `CD` (the confidences, the 30 s fade, the cover lines, the reserve windows); `intel/init.lua` loads `pvp_data` (absent: every cooldown unknown) and runs the ledger after the threat; `rules/pvp.lua` and `rules/core.lua` the two validates; `custom_data.lua` and `custom.lua` the conditions and functions.
- Tests: new `aio_intel_cooldowns_test` (12): the tables for the client; a cast event's clock; the aura proxy and the interrupted cast; the shared trap category; an unknown name; the fade; the burst answer, Deterrence up, the rule held and `me.protected`; the core defensive held and not under critical health; the trap reserved for a closing warrior and sorting last; the defensive reserved for a burst back soon; the window's conditions live; no data.
- Not yet seen in game. The open probe stands: whether Forever delivers `UNIT_SPELLCAST_*` for enemy unit tokens; until then the aura proxy is the ledger's only Forever input.

**PvP intelligence, Stage 2: how much danger is coming, from whom, and how sure that is.** The brief's Phase 4 (threat prediction), on the picture Phase 2 built, in the delivery order the brief's own roadmap gives (state, threats, cooldowns, then the hunter). detect.lua's danger reads the trouble we are in off our own numbers; a player answers you, so most of the danger is in what it is about to do. `modules/react/intel/threat.lua` reads those signs and scores them on detect.lua's 0..100 scale, into `W.intel.threat`, and nothing here decides.
- **The indicators**, each with the points it is worth, the seconds until it lands, how reliable the read is, and words: a burst cooldown up on a player on you (`pvp.lua`'s ENEMY auras); a dangerous cast at you (detect.lua's weight for the name, nearer is worth more) or at an ally (half, more at the healer or a hurt one); a melee player about to reach you (JCore's `time_to_reach`); standing inside the reach of a control its class throws (Kidney Shot 5 yd, Intercept 8–25, Polymorph 30 … the names and reaches `rules/pvp.lua` already uses, now in `intel/data.lua` with where they came from); a player on an ally, the healer or a hurt one heavier; a gap closer or sprint just seen from it (Charge, Intercept, Blink, Sprint, Dash: a cast event or the buff it leaves, for three seconds); several players on you (ten a head past the first, to thirty); rooted or snared with a melee player on you or closing; no escape ready with a melee player on you; dying by the field's measured race (under eight seconds to live); under 30% and being hit; a player vanished beside you.
- **The scaling, written down** (`intel/score.lua`, every weight with its reason): urgency by the seconds until impact (now 1.0, three seconds out 0.7, six 0.4); health (0.8 of the points at full health, 1.4 at none); nothing defensive and nothing to escape with (+15%); the reliability of each read (a class the client did not name 0.6 for anything read from its role; on Forever the damage read from your own health drop 0.7). A burst already covered by a defensive of ours (Deterrence 85% of physical, Evasion, Ice Block and Divine Shield all of it, a shield 35%, Barkskin 30%: `data.PROTECTION`) is worth the uncovered fraction, and the words say "85% covered by Deterrence".
- **The level**: CRITICAL from 75, HIGH from 50, MODERATE from 25, LOW from 8, INFORMATIONAL below, each with an exit line twelve to three points under its entry and a 0.6 s dwell before stepping down; a level steps up at once. **The band**: the score is the point estimate; the top of the band adds every unknown against us (ten points each: on Forever the damage read, a player's class the client did not name, where a vanished player is) and `worst` is the level that would be. Missing information never lowers a score; it widens the band and is named.
- **The readout** (the first intel row): "threat HIGH 58 (Enemy bursting on you (Recklessness) +41; Enemy within Concussion Blow reach (3 of 5 yd) +17) | up to 68 if the unknowns go against you | covered: Deterrence".
- **Your own reactions can read it** (the Reactions window): *PvP threat level* (`f_threat`, CRITICAL … INFORMATIONAL), *PvP threat score (0-100)* (`f_threat_score`), *A dangerous cast is coming at me* (`f_incoming_cast`), *Target used a gap closer or sprint in the last 3 s* (`t_mobility`), *Target has a defensive up* (`t_defensive`: immune, Evasion, Deterrence, a shield); in Lua `fight.threat`, `fight.threat_score`, `fight.incoming_cast`, `target.mobility`, `target.defensive`. On the Try-it bench, which carries no picture yet, they read calm and false.
- Internal: new `modules/react/intel/threat.lua`, `score.lua`, `data.lua`; `intel/init.lua` runs the read after the picture and puts the threat line on the readout; `state.lua` carries each player's `time_to_reach`; `custom_data.lua` and `custom.lua` the five conditions (`D.THREATS`, the `threats` choices, the readers).
- Tests: new `aio_intel_threat_test` (15): nobody about; a rogue in reach; a burst at full health and at 40%; a burst covered by Deterrence, a spell burst not, Ice Block covering all; a cast at you nearing, and a heal that is not; the ally indicators, the healer heavier; a melee player closing and Intercept's 8–25; a gap closer for three seconds, Sprint's buff too; three rogues; rooted and no escape; dying on Era and the wider band on Forever; the vanish; the dwell; the no-answers scaling; the window's conditions live. The test bundle moved to `tools/jtest/mock/intel_bundle.lua`, shared with `aio_intel_state_test`.
- Not yet seen in game. The weights are first values: every one is in `score.lua` to be tuned from the ledger Stage 11 adds.

**PvP intelligence, Phase 2: the picture of a PvP fight, with its sources.** The user's brief (an 18-phase "PvP intelligence and reactions engine": threat, cooldown economy, opponent prediction, baiting, crowd-control planning, positioning, kill windows, team fights, analytics), taken one phase at a time; the audit and the plan are `PVP_INTEL_PLAN.md`. Phase 1 found what the reactions already read (`W`, `W.pvp`) and what no decision had: who each player is with how sure we are, what was seen cast, where we stand, what this client cannot say. Phase 2 builds that one table and nothing that decides.
- **`W.intel`** (`modules/react/intel/state.lua`), built once a tick right after `W.pvp` and before the situations, reused between ticks, with three kinds of entry kept apart: **observed** fields flat (a row's distance, a player's class from `get_class`, the cast on its bar); **inferred** ones as `{ v, conf, why }`, read by a rule only through `intel.sure(x, threshold)`, which answers nil below the threshold, so a guess can never be consumed as a fact; **unknown** ones at confidence 0 saying which call would answer, plus `S.unavailable` (what this client leaves out: on Forever the combat log by source, threat, a player's mana maximum) and `S.unknown` (what no client says: a player's talents and specialisation, cooldowns never seen, terrain and paths, objectives beyond flag carriers). No absence is ever read as safety.
- **What it carries.** You: health and its slope, power (and whether it is counted, on Forever), buffs, what controls you with where the read came from (the aura with its caster, or the client's own loss-of-control word), the cast on your bar and the global cooldown, your abilities by what they are for from the catalogue's roles (defensives, escapes, controls, slows, interrupts: known, ready, cooldown left), position, rotation, speed and a velocity inferred from a position trail, target, focus and mouseover, the flag. The pet: health, target (and whether that target is a player under a control damage breaks). Each enemy player within 40 yd, nearest first, up to ten: distance and position, health, whom it targets (you, the pet, an ally), closing speed and motion from JCore's trail, the cast on its bar, the control on it (Era's loss-of-control read, Forever's debuff read, each saying what it can), its class and form, `pvp.lua`'s immunities and bursts, whether it faces you (its rotation, or on Forever its direction, the nearest four every 0.25 s; a rotation of exactly 0 is not known), and a ring of the last twelve abilities seen from it. Allies: the group's members with role, health and distance, twice a second. The ground: the class's ranges from the catalogue, the target's band (melee, the dead zone, ranged, far) from the rotation's own gap, line of sight to the target through JCore's `geometry.sight` at most twice a second (true, false or **unknown**; never the client's `is_line_of_sight`, which crashes Forever build 70338), the counts around you, flag carriers in a battleground from the flag auras. The mode: a battleground or an arena observed from the instance type; a **duel inferred** from `DUEL_REQUESTED` within two minutes and one player fighting you, until `DUEL_FINISHED`; world PvP from any sign; solo, party or raid; and one answer to "is this PvP" listing every sign, in place of the three the plugin kept apart (`W.env.pvp`, `W.pvp.active`, the PvP hunter's mode).
- **What it listens to**, each handler filtering on its first line: other units' `UNIT_SPELLCAST_START` / `SUCCEEDED` / `INTERRUPTED` / `CHANNEL_START` by unit token (resolved through the object manager and kept 0.2 s, since tokens are recycled; our own, the pet's and the group's are left out; a token nothing resolves is counted, not kept); `UNIT_AURA` "added" records on the same units (a helpful aura on an enemy is the proxy a cooldown is seen through, Stage 3); on Era the combat log's `SPELL_CAST_SUCCESS` from a hostile player, by guid (the event arrives empty on Forever, so it is not even subscribed there); the duel events; `jcore.unit.removed`, `jcore.zone.changed`, `jcore.player.died` and `PLAYER_ENTERING_WORLD` drop every player; a player gone five seconds is out of the nearest list and swept after thirty.
- **The readout** (the Reactions page's *Decisions*, two more rows while the picture is on): "Intel: world_pvp (solo) | 1 player(s) in 40 yd, 1 on you | target ROGUE melee (0.90), 3 yd melee, facing you, LOS yes | you: stun 4.0s (Kidney Shot, a player's) | ready: 0/0 defensives, 1/1 escapes, 0/1 controls" and "Intel: 2 cast(s), 1 aura(s), 0 log line(s) seen | last cast Sprint 1.2s ago | not on Forever: combat log by source, threat, a player's mana maximum". A duel reads "duel?": an inference is never shown as a fact.
- Nothing acts on it yet, and no setting is on a page yet: `intel_enabled` (on) is read like any un-widgeted setting; Phase 13 puts the switches on the Reactions page. The PvP hunter, the PvP reactions and the rotation are untouched. A build that raises leaves the table marked off and the reactions run as before.
- Internal:
  - new `modules/react/intel/init.lua` (the wiring, the events, the switch) and `intel/state.lua` (the model; budgets at the top: `REACH` 40, `TRACK` 10, `RECENT` 12, `FACE_N` 4 / `FACE_EVERY` 0.25, `LOS_EVERY` 0.5, `ALLY_EVERY` 0.5, `MODE_EVERY` 1.0, `GONE_AFTER` 5, `KEEP` 30, `DUEL_WINDOW` 120);
  - `react/init.lua`: loads it with `world`, `pvp`, `memory`, the client flags and `spell_name`; `intel.update(W, now)` after `pvp.read`; `R.intel`; the two readout rows; `R.reset`;
  - `react/pvp.lua`: each control entry carries `source` ("aura" or "client");
  - `main.lua`: the Reactions page's readout has two more rows.
- Tests: new `aio_intel_state_test` (25): off the field; the rogue observed and inferred; a class the client does not name; a priest seen healing; the bands from the catalogue and without one; line of sight at most twice a second with nil kept apart from false; facing, a rotation of 0, a direction vector; casts by token, an ally's and an unresolved one; a player seen only through an event; aura records; Era's combat log and Forever's silence; the ring of twelve; what controls you from an aura and from the client; the abilities by role; the battleground and the inferred duel; allies; the pet on a trapped player; flag carriers; a zone change and the sweep; the switch off and the reused table; our velocity; the readout; the PvP hunter still clipping. New `aio_forever_class_hunter_intel_test`: the whole plugin as a Forever hunter against an enemy rogue, the picture on, the rogue carried, Forever's gaps listed. `aio_hunter_pvp_test` and `aio_pvp_test` unchanged and passing.
- Not yet seen in game. To check there: that `UNIT_SPELLCAST_*` arrive for `target` and `nameplateN` tokens on Forever (the recorder has only seen the `player` token), and that `get_rotation` or `get_direction` answers for other players.

- Fix: a loading screen stopped the reactions for the rest of the session ("the reactions failed this tick; the rotation runs by itself: ...reactworld.lua:313: Invalid game object!" -- Forever, a zone change mid-pull). The picture of the fight kept the player's game object between ticks and compared it with `~=`. A game object compares through the client's own `__eq`, which raises once either side is stale, and the raise came before the kept one could be replaced, so every tick after raised the same way; the log said so once. The same fault as 1.48.2's in the combat-log reader. An identity check now (`rawequal`), and the guid is read again whenever the object changes. Test: `aio_react_test` ("world: a stale player object after a loading screen").

**The RestedXP ESP acts as you walk up.** The user: "let's make RestedExp ESP - Allow Quest Grab, allow the Combat System to work with it and Turn in quests". Until now only the guide walk (1.7.4) picked up, handed in and pulled, and only while Sentinel Navigation walked you.
- **A second switch in the Quests page's RestedXP section, *Act on the guide's marks as you walk up to them*, off by default.** You move, by the guide's marks, its panel and its line; nothing walks you and nothing holds a key.
  - **Stand within 5 yards of the npc (or the object) the step's quest goes back to or comes from** and it talks to it and answers its windows as the walk does: the hand-in first, then the pick-up, the step's quests only, the guide's reward or the one the reward chooser takes. Two switches under it, *Pick up the step's quests* and *Hand in the step's quests*, both on: a half that is off is neither asked for nor answered.
  - **Come within pull range of a mob the step wants killed** (26 yards for a caster or a hunter, melee for the rest) and it is the rotation's: automatic targeting takes it out of combat and the rotation may open on it, the same way as for the walk. Nothing here selects, faces or hits it; with the rotation off the line says to switch it on. *Let the rotation fight what the step wants killed*, on, turns it off. Resting, low health and hardcore's no-pull hold it, as they hold the walk.
  - Nothing else: no quest object is used, nothing is looted (auto-loot does), it never gets you off your mount. Steering never pauses it; the actions gate still waits while you move.
- **The guide panel's first row says what it is doing** ("> walk up to Marshal McBride to hand in (12 yd)") while either switch is on. The Quests page's first line reads *Guide ESP:* in this mode, and the Overview's *Guide walk* line is on for either switch.
- Both switches on: the walk wins, and switching one for the other mid-walk stops the walk's route. Not on an ESP-only client, like the walk.
- Internal: `guidewalk.lua` (`mode()`, `wants_of()`, `talk_quest` and `scan` by the mode's switches, `talk_here` and `pull_gate` shared with the new `act_talk`, `act_fight`, `act_tick`; `wanted_ids` by the switches; `M.active()`; `stats().switch`), `quests.lua` (reads RestedXP for it; the panel's first row), `main.lua` (the switches; `rxp_act` in `ESP_ONLY_OFF`; the Overview line).
- Tests: 7 new in `aio_guidewalk_test` (41: nothing walks or leases, the 5-yard talk, the two switches, the pull range and the gates, the walk wins, steering and combat); `aio_guidewalk_hooks_test` declares the switches and runs frames with it on; `rxp_act` in the boot suites' acting switches (`aio_boot_checks`).
- Not yet seen in game.

**A druid of 1 to 19 fights.** The user's dump and log (Forever, a level 1 Night Elf druid): standing still in every fight, "react idle: ... no rotation rule passed | Faerie Fire (Feral): NOT IN THE SPELLBOOK ... Rip ... Ferocious Bite", with Wrath and Healing Touch in the book. Every rule of the levelling profile was a cat's, and Cat Form is trained at 20 (Bear Form at 10), so nothing below 20 resolved: no Wrath, Moonfire, Rejuvenation, Healing Touch or bear at all.
- **Before Bear Form, a caster** (*Levelling (Caster)*, mana, no form): Mark of the Wild out of combat; Rejuvenation on you under 65% (or 85% while health drains), not over a running one; Healing Touch on you at the defensive line, standing still; Moonfire; Wrath, standing still.
- **From Bear Form to Cat Form, the bear** (*Levelling (Bear)*, rage): the Bear tank profile's rules -- Bear Form, Demoralizing Roar, Growl on a loose mob, Maul.
- With 20 talent points or more, as before; under 20 the cat's levelling profile from Cat Form on.
- **Elune's Light**, Forever's Night Elf racial (1259799: 10% crit for 15 s, 3 min, off the global cooldown), goes in with the other offensive racials inside a burst window. Nothing pressed it.
- Internal: `classes/druid.lua` (`leveling_caster`, `leveling_bear`, the bear's rules shared with `feral_bear`, `self_heal_wanted`; `suggest` asks the book for Cat Form and Bear Form under 20 points), `burst.lua` (`OFFENSIVE_RACIALS`).
- Tests: `aio_class_review_test` (1 new: the three stages, the heals' lines, the profile order); new `aio_forever_class_druid_level1_test` (the dump's book: Wrath, no form) and `aio_forever_class_druid_level10_test` (Bear Form once, Maul), on two new `mock/forever_class` books.
- Not yet seen in game.

**The crash in Shadowglen: the target's *LoS* pill asked the client every frame.** The user, with Forever's crash box (`ASSERT(m_data)`, `M2HitTest.cpp`) over a fight with two Grell: "Can we take a look". Four crashes on 2026-10-11, each a line-of-sight ray from the player to a mob, three of them to the selected one -- and the ESP's *Target: line of sight and range* row (on by default) called the client's `is_line_of_sight` at the target on every frame drawn, with no cache. JCore 1.8.0's half-second fade and one-ray-per-tick gate never saw it.
- The row asks JCore's `geometry.sight` (JCore 1.8.0): on Forever a model-free ray, kept a fifth of a second, so the frame rate no longer sets the ray rate. An unknown answer shows no *LoS* pill, only the range.
- Internal: `esp/elements.lua` (`reach_state`).
- Tests: `aio_esp_marks_test`'s bundle has `geometry.sight`, and its client's `is_line_of_sight` raises if asked.
- Not yet seen in game.

**Booty Bay: rings under every enemy player.** The user's screenshot (Forever, a level 27 hunter on the Booty Bay dock, a PvP realm, a dozen Horde players standing about): "let's fix this". Two default-on marks were drawn under every enemy player in sight, none of them fighting.
- **Pull safety's aggro rings are for mobs only.** Each Horde player stood in a 20 to 23 yard ring at Classic's aggro radius for its level, full and red because you stood inside them all, and a warning is never dropped by the world layer's budget, so they covered the screen. A player notices nobody from a distance; nor does a player's pet or minion (*Hamphog, Fish Chewer's Minion*). None of them gets a ring, a "heading your way" curtain or a rare's pulse now. A pet or minion whose owner does not answer keeps its ring: a ring too many is safer on hardcore than one missing.
- **A PvP trinket's ring only once it has been seen used.** A thin gold "ready" ring stood under each of the nearest six enemy players whose trinket had never been used, which is everyone's. The grey ring filling back up after a trinket, and the gold one once it is back, are as before. The setting reads *Their PvP trinket, once seen used: grey filling while down, gold once back*.
- The red cages in the screenshot were the Forever ESP's *Box style: Curtain*, a setting (corners by default since 1.7.6); unchanged.
- Internal: `pull.lua` (`players_own`: the sweep's `is_player` first, else the unit's; `is_pet` / `is_minion` with `get_owner`'s `is_player`), `pvpmarks.lua` (`l.used`).
- Tests: `aio_pull_test` (2 new: a player, its pet and minion get nothing, a mob's pet and an unanswered owner keep theirs; the sweep's word first, no curtain or pulse), `aio_pvpmarks_test` (the trinket test starts with nothing until used; 1 new: twelve players in a town, nothing drawn; the switches test uses a trinket seen used).
- Not yet seen in game.

**A spell's tooltip is read once a session.** `react/damage.lua` forgot every tooltip it had read on each `SPELLS_CHANGED`, which the client fires often, so a cast re-read its spell's description. Forever's Rend Flesh (1309069) asserts inside the client's `GetSpellDescription` ("Spell_C_GetMinMaxPoints applied variance twice"), and each read wrote a report to WoW's `Errors/` and stalled the game about a second: three in 75 s on 2026-10-11. The cache is kept by spell id, so a new rank (a new id) still reads its own; an empty answer (spell data not loaded yet) is asked again, as `petcare.lua` does.

### Worked on as 1.8.0 (2026-10-11)
**The reactions are apart from the rotation, on JCore's reaction framework.** The user: "I wanna take the Framework for Reactions and move it to JCORE, then Reactions themselves I wanna seperate it compeletely from Rotations and Reactions will become Specifics you set if you need the rotations to adjust for some reason but apart!!"
- **The framework is JCore's** (JCore 1.8.0, `ctx.react`): the rules, the scoring, one winner per lane, the safety checks, the cast, the memory of what was just done and the journal of why. `modules/react/engine.lua`, `memory.lua` and `latch.lua` are gone; `react/init.lua` tells the engine about the AIO's world instead (`engine.configure`: the spellbook by name, the catalogue's word on a target, the rotation's gates -- a key, a channel, `press_blocked` -- and the AIO's own action kinds: the pet's skill, a bag item by kind or by name, the pet sent or called back, an aspect, a target switch). Every built-in rule and every reaction of your own is unchanged.
- **Apart from the rotation.** The reactions run in a job of their own just before the rotation's (priorities 59 and 60), on the one snapshot the two share (`rotation.snapshot()`: whichever asks first builds it), and publish a verdict (`react.verdict()`) the rotation reads and gives way to -- a reaction took the global cooldown, or something says stop attacking. The rotation no longer calls `react.tick` or `react.after_rotation`; a second job after it (61) takes its pick for the readout and sends the deferred reaction when the walk had nothing to press. If the reactions' job raises there is no verdict for that tick and the rotation runs by itself; the log says so once.
- **The switch is a switch.** *Use reactions in the rotation* off: no reaction acts, nothing owns a spell (the pet module's own Mend Pet path takes over), and the rotation runs by itself with its own fixed sequence -- defensives, racials, the Hardcore page's bail-out, breaking contact, dispels, interrupts. The picture of the fight is still built, so the rotation's scoring (*the rotation changes with the fight*), the targeting's kill order and the readouts keep working; the readouts open with *Reactions: OFF*. Until now the switch only filtered the rules ("the engine is the path, not an option", 1.32.0), and a rotation without them had no interrupts at all.
- **Everything about the reactions is on the Reactions page.** The Rotation page's advanced *Reactions* section and its readout moved there: a *Decisions* section (*Show the decision on screen*, *Log every decision and every refusal*); in *In the world*, the reactions' marks (the kick lined up, who one acted on, PvP marks) and the two PvP curtains; and the readout at the bottom. A setting moved to another page loses what you saved, so these start from their defaults.
- Needs JCore 1.8.0 (`MINIMUM_CORE`).
- Internal: `react/init.lua` (`engine = ctx.react`; the hooks; `R.active()` reads `react_active`; `R.observing()`, this tick's picture; `R.verdict()`; the two jobs, and `R._before_rotation` / `R._after_rotation` for a bundle without a scheduler; the journal, the memory and the latch are the engine's). `rotation.lua` (`M.snapshot()`, memoised per tick on a counting job at priority -990, or on the clock without a scheduler; `M.walked_this_tick()`, `M.last_choice()`; the gate, `adapt` and `weigh` read `react.observing()` rather than `react.active()`). `main.lua` (the Reactions page's new sections and the readout; `P.CURTAINS`; versions).
- Tests: new `jcore_react_test` (12: the latch, the memory's lifecycle and back-off, the engine's lanes, validation, kinds, modes, wakes, owns and yielding, the journal, owners). `aio_react_test`, `aio_pvp_test`, `aio_hunter_pvp_test` and `aio_pvpmarks_test` take the engine and the latch from JCore's service; the bundles that drive the real rotation run the two jobs round its tick, as the scheduler does; the master-switch test asks for the new answer (off means off, the picture still built), and the engine-fails test for the new shape (no verdict, the rotation's own kick). The boot tests set `react_overlay` on the Reactions page.
- Seen in game 2026-10-11 (Forever, a Warlock): the reactions ran apart from the rotation and learned a wolf's flight; a loading screen then stopped them (1.8.1).

## 1.7.6 (2026-10-09)
**Curtains are off by default, each with its own switch.** The user: "the Aura curtains are over power the entire game! We need to Work them yes but have them off by Default", then "any and all should have an option to turn on and off". From 1.86.0 to 1.88.0 more and more world marks became curtains, and with their switches on by default they stood all over the screen.
- **Every curtain has a switch of its own, next to the rest of its mark, and every one is off by default:**
  - the aurora around you: ESP, *Aurora around you*;
  - an elite, rare or boss heading your way: Hardcore, *Pull safety*;
  - the mob to kill next: ESP, *Fight timers*;
  - who most needs a heal, and a mob loose on someone not the tank: ESP, *Group and healing*;
  - round the tank: ESP, *Group extras*;
  - the rotation acting on something not your target: Reactions, *In the world*;
  - the enemy player lowest on health, and enemy healers: Reactions, *PvP marks*;
  - a wall round a telegraph as it lands: ESP, *Telegraphs*;
  - boxes round mobs: the ESP's *Box style*, now *Corner brackets* by default (*Curtain* is still a choice).
- **New switches, for curtains that shared one with something else:**
  - *Execute range: a red curtain round your target too* (World marks, *Combat rings*). *Execute range* keeps the red ring and the pulse.
  - *A red curtain where an enemy player vanished beside you* and *A red curtain round an enemy player bursting on you* (Rotation, *Reactions*, advanced). *Show it in the world* keeps the vanish ring, the kick and the control rings.
- **The World marks page's new *Curtains* section** lists every curtain and where its switch is, with *Switch every curtain on* and *Switch every curtain off*.
- **Switched off once.** The old switches shipped on, and the menu saved that as everyone's value, so a new default alone would change nothing. Each one saved on is switched off once, a second after load, and a saved *Curtain* box style goes back to the corners. After that every switch is yours again. The log says how many were switched off.
- With a curtain off, the rest of its mark still shows: pull safety's aggro rings and the rare's pulse, the execute ring, the vanish ring.
- Internal:
  - `main.lua`: the defaults; the new `cr_execute_curtain`, `react_curtain_vanish` and `react_curtain_burst`; `P.CURTAINS` (page, switch, value, where); the *Curtains* section with `curtains_all_on` and `curtains_all_off`; the one-time `curtains_off_1:` move in the migrations store.
  - `config.lua`: `BOX_DEFAULT` is `BOX_CORNERS` again, so `esp/page_forever.lua`'s 1.88.0 `box_curtain_1` move no longer runs.
  - Each module's fallback for its switch is off: `aurora.lua`, `pull.lua`, `timers.lua`, `party.lua`, `groupextras.lua`, `plays.lua`, `pvpmarks.lua`, `telegraphs.lua`.
  - `combatrings.lua` and `react/marks.lua` read the new switches.
- Tests:
  - The curtain tests of `aio_aurora_test`, `aio_pull_test`, `aio_timers_test`, `aio_party_beacons_test`, `aio_groupextras_test`, `aio_plays_test`, `aio_pvpmarks_test`, `aio_react_marks_test`, `aio_combatrings_test` and `aio_telegraph_wall_test` switch their curtain on, unless a test asks for the shipped defaults.
  - 4 new: the aurora, pull safety, execute, and vanish/burst are off by default, with the rest of each mark still drawn.
  - `aio_esp_split_forever_test`: boots Forever with every old curtain switch saved on and the box saved as the curtain. 1 new test: each is switched off once, a switch set back on by hand is kept, and the two buttons switch them all. 1 changed: the box is the corners.
  - `aio_esp_forever_test` and `aio_esp_marks_test`: corners by default, a curtain when picked.
- Not yet seen in game.

**Enemies carry no curtain by default: the beacons are curtains too.** The user, 2026-10-10: "enemies should not have Curtain up by default should be off". JCore draws a beacon as a narrow curtain ten yards and more tall, and the ESP still stood one, on by default, over every far rare, boss and quest mob, so questing among hostile quest mobs put curtains back on the screen.
- **Off by default, each still its own switch:**
  - the Forever ESP's *Beacons over far rares, bosses, quests and loot* (ESP, *Look*, advanced);
  - the Classic ESP's *Pillars of light on far rares, bosses, quest targets and loot* (ESP, *Elements*);
  - *In a battleground, a tall beacon on each flag carrier* (Reactions, *PvP extras*).
- **In the World marks *Curtains* list**, so *Switch every curtain on* and *off* take them too.
- **Switched off once, by a second pass.** The first switch-off has already run for anyone who played 1.7.6, so a second one (`curtains_off_2:`) switches off only these, once. A curtain you switched back on by hand stays on.
- The Quests page's beacons (where to go, quest areas, herbs and ore) are not on enemies and are unchanged.
- Internal: `main.lua` (`P.CURTAINS` entries with a fifth field, 2, for the second pass; the switch-off is `curtains_off_once(name, pass)`, run for both passes; `pvpx_bg` default), `esp/page_forever.lua` and `esp/forever.lua` (`esp_beacons`), `config.lua` and `esp/elements.lua` (`show_beacon`), `pvpx.lua` (`pvpx_bg`).
- Tests: new `aio_boot_beacons_off_test` (Forever, first pass done, beacons saved on, the aurora back on by hand: only the beacons switched off, both in the list, the switch the player's after). `aio_esp_split_forever_test` saves both beacons on and checks pass one and the buttons take them. `aio_esp_forever_test`, `aio_esp_marks_test` and `aio_pvpx_test` switch the beacons on where they test drawing, and check they are off by default.
- Not yet seen in game.

**Hunters see what a tameable beast teaches, on Forever's ESP.** The user: "I'd like an ESP on beasts as a Hunter class that shows me the image and name of the ability and rank it is that Im looking at give me an option to turn it off too in the esp...use this as refrence (its for Forever) https://www.wow-petopia.com/classic/abilities.php#dismember". Forever's ESP showed nothing of it: the Classic ESP's TAME line (1.72.0) never reached Forever's card. Even on Classic, every skill was a guess from the family, with "?" until seen.
- **New rows under a beast you can tame** (hunters only): one pill per skill, with the skill's own icon, then its name and rank: "Bite 3", "Dismember 2?".
  - **Violet outline, white text: sure.** Petopia lists that kind of beast for that rank, or you saw one use it.
  - **Dimmed, with a faded icon and "?": a guess.** A skill of its family that nobody can vouch for, at the rank its level carries. Forever's own skills have no known teacher on Petopia yet, so they always show this way: Dismember, Savage Rend, Tendon Rip, Web, Pinch, Swipe, Dust Cloud, Mine!, Lava Breath, Trickster's Dance and Demoralizing Screech.
  - **"new" in green:** a higher rank than your current pet has.
  - **Above your level:** every row is dimmed, and the first says "tame at 34".
  - **A Classic beast Petopia does not list** for a skill whose teachers it knows does not teach that skill: no guess is shown.
  - **Forever's own beasts** are not covered by Petopia, so every skill of their family is a guess.
  - **A beast the creature cache has not described yet** is still shown when Petopia lists it.
- **New section on the ESP page: *Hunters*** (shown to hunters only).
  - *Abilities a tameable beast teaches* (`show_pet_skills`, on) turns the rows off.
  - *Also its family's abilities nobody has confirmed* (`pet_skill_guesses`, on) hides the "?" rows.
- **Where the data comes from:** `tools/jcheck/petopia_extract.js` reads Petopia's ability pages (/forever/ for Forever, /classic/ for Era) into `modules/petopia_data.lua`. It records where each rank is learned and what each npc teaches: 294 npcs and 342 listings on Forever, 297 npcs on Era. Petopia lists Classic npcs only (every id is under 20000).
- **Each row shows the game's own icon for that skill, the one on your pet's bar.** The user, 2026-10-10: "The Games own Skill Icon like Bite should be Bites Icons".
  - The first version used Petopia's icon names. For Bite that is the druid's Ferocious Bite, not the pet's bloody jaws. Forever's Demoralizing Screech showed the bat icon, not its own. The other 21 matched.
  - Every icon now comes from the client's own spell table (`SpellMisc.SpellIconFileDataID`), cut out by file id.
  - The icons ship with the plugin, with no download. The art pack gains 27 cells (`pet.<file id>`), one per skill a hunter's beast can teach on either client, and its PNG grows from 186 KB to 267 KB.
  - Skills Petopia does not have get their own icon as well, such as a Forever bat's Sonic Blast.
  - The Era client has no icon file for Trickster's Dance, so that one is cut from Forever's client.
- **The Classic ESP's TAME line changes too,** because it reads the same `tame.lua`. A sure skill loses its "?". A Classic beast no longer guesses skills Petopia knows it does not teach, so an unlisted one shows its family alone ("Cat"). The label under *Hunters: TAME on beasts you can tame* (`main.lua`) says so now: sure when Petopia lists that kind or you have seen it use the skill, "?" when only its family says so.
- Internal:
  - `tame.lua`: `M.beast(npc, level, guid, now)` for the Forever ESP, sharing `answer_for` with `info()`. Each skill carries `how` ("petopia", "seen" or "guess"), `sure`, `icon` and `spell`. `unvouched()` decides a guess (`PETOPIA_NPC_MAX` 100000). `P.petopia` stands in for the file (false: none).
  - `esp/forever.lua`: `card_beast`, called from `card_unit` after the threat row and before the cast. Adds `S.pet_skills`, `S.pet_guesses` and `frame_now`.
  - `esp/page_forever.lua`: the *Hunters* section.
  - `tools/jcheck/beasts_extract.js`: each skill's `icon` (SpellMisc's file id) in `modules/beasts_data.lua`. Rerun on the same builds, nothing else changed; `tame.lua` takes `icon` from there.
  - `tools/jcheck/art_pack.js`: cuts a `pet.<file id>` cell for each hunter family's own skills and Cower, from `beasts_data.lua` (`--beasts`). It takes `--alt-product` (default `wow_classic_beta`) for an icon the main client lacks. Rerunning it unchanged reproduced the old pack byte for byte, so the old cells are unchanged.
  - `tools/jcheck/petopia_extract.js` writes no icons any more.
- Tests:
  - `aio_tame_test`: 11 new: Petopia's file, the game's own icons (Bite 132278, the pet's), the art cells, a listed crocolisk, a Forever skill seen in use, an unlisted Classic cat, one of Forever's own beasts, a cache miss, the cache saying no, a stand-in file, and `beast()`. The first 4 run without Petopia, as before.
  - `aio_esp_forever_test`: 6 new: the rows, icons and colours; both switches; who is never asked; above your level; the spell-icon fallback and detail levels; the real `tame.lua` with Petopia's file. The bundle passes `opts.tame` through.
- Not yet seen in game.

**Hunters: an AOE melee weave (2026-10-10). Marked ALPHA/TEST.** The user asked first for a weave on a key: "for hunters in wow forever lets add on rotation with a keybind a Meele Weaving option when it runs in and out for range and meeel". That version (a key, T, that ran the hunter in for a swing and back out between Auto Shots, with `modules/meleeweave.lua`) never left this machine. The same day: "Remove the Meele Weave completely off the code and UI and here's how the new AOE+Meele Weave will look like...... When in meele range u can still cast summon hawk, immolation trap and other Meele skilss to burst down dmg same as Rapid fire (this is both meele and rnage).... We manually Move out and when we move out we use Multi-shot! At this time We also renew as many Serpent stings on Multiple target in combat with US!!! it can Swap through target automatically Aslong as its in combat with us and Renew while we mvoe back in!! again at all times keep 2 hawks up For maximized DPS!"
- **The keyed weave is gone:** its key and line on the Rotation page, its option (*goes in for*), its class window line, `modules/meleeweave.lua` and its tests. Nothing moves the hunter in to melee by itself any more.
- **New hunter option: *AOE melee weave (ALPHA/TEST)*, off.** It is in the class window and under Hunter options. While it is on, its profile runs in place of your talents' (a fight with a player still runs the PvP hunter). **You walk in and out yourself**; the rotation reads which side of the dead zone you stand on. The step out and the run-and-shoot stand aside while it runs.
- **Both sides:**
  - two hawks at all times, in melee too (Summon Hawk has no minimum range); a bar that is refilling still keeps two, where Levelling keeps one;
  - Rapid Fire once the fight is worth it: two or more mobs, or one that lives 10 s (on Forever it speeds melee as well as shots);
  - Intimidation and Bestial Wrath as in Beast Mastery.
- **In melee, the burst:** Immolation Trap at your feet (Explosive Trap with two or more round you; Forever lays traps in a fight), Raptor Strike, Mongoose Bite, Strider Kick, Counterattack, Lacerate on a mob that lives 12 s, and the plain swing.
- **Out of melee:**
  - Multi-Shot on its cooldown as soon as you stand still (its half-second cast does not go on the move), and only with two or more mobs where it lands; then it comes before everything else. The user: "if its 2+ mobs it should be priority to multishot", then "remember Neither PvP or AoE meele wave should Multishot if its not 2+ enemy mobs";
  - Serpent Sting renewed on every mob fighting you or your pet, on the way out and on the way back in, with no cap (the *Serpent Sting on* option still caps the other profiles);
  - **the target moves from mob to mob:** once your target has its sting, the new reaction *AOE weave: sting the next mob* makes the next mob of the fight that needs one your target: no sting, or 2 s or less left, the least left first, then the nearest. Only mobs fighting you or your pet, within 35 yd, outside the dead zone, not under control that damage breaks, living 8 s or more. Not in melee, and not on a bar under 15%;
  - Auto Shot is pressed again the moment you are back out, because a strike or the swing switches it off (the Auto Shot guard's `restart()`).
- The mana rules hold: on an empty bar nothing costs mana, and nothing that costs mana goes at a mob about to die (the plain swing still does).
- A line under the option in the class window says which side you are on, how many mobs carry a sting and how many hawks are out.
- Internal:
  - `classes/hunter.lua`: the `aoe_weave` profile; `aoe_in_melee` and `aoe_back` (the restart); `aoe_rapid_fire`, `aoe_hawk`, `aoe_explosive`, `aoe_immolation`, `aoe_strike`, `aoe_lacerate`, `aoe_swing`, `aoe_multi` (two or more where it lands, near the top of the list), `aoe_sting`, `aoe_status`; `suggest` asks the option after PvP mode. The class table exports `aoe_status` and `aoe_running`. The keyed weave's `weaving`, `weave_leaving`, `weave_back`, `weave_swing` and the `Attack` rule it added to Levelling, Marksmanship and Survival are gone; Steady Shot asks `at_range` again.
  - `react/rules/hunter.lua`: the *AOE weave: sting the next mob* rule (`set_target`). `react/custom_data.lua` describes it for the Reactions window.
  - `kite.lua`: stands aside with "AOE melee weave: you move".
  - `classwin_data.lua` and `classwin.lua`: `rot_hunter_aoe_weave` and the `hunter_aoe` note.
  - `main.lua`: no weave key, no `P.meleeweave`.
- Tests:
  - `aio_meleeweave_test` is gone.
  - `aio_hunter_test`, 8 new: the switch and which profile runs; the burst in melee; Multi-Shot and the stings out of melee; Multi-Shot only with two or more where it lands, and then first; two hawks and Rapid Fire on both sides; Auto Shot back on after each trip; the class window's line; the step out standing aside.
  - `aio_hunter_pvp_test`, 4 new: the sting's move of the target, through the reaction engine.
  - new `aio_forever_class_hunter_aoe_test`: the whole plugin as a Forever hunter with the option on. It fights with no error, and the profile running is the weave.
- Not yet seen in game. Guesses to check there: that Immolation Trap laid in melee springs under the mob; that the target switches do not fight a click of yours mid-fight (the rule waits 1.5 s between switches and 3 s per mob).

**Beast Mastery is the Forever guides' rotation (2026-10-10).** The user: "let's work on a beast master build (do the research) make it ALpha too when enabled the other beast master rotation isn't there anyways". The old Beast Mastery profile is the Survival list with two spells Forever does not have (Kill Command, Steady Shot), and under 20 talent points it never runs at all: Levelling does. It was built first as an ALPHA behind its own option (*Beast Mastery build (ALPHA/TEST)*); the same day the user said "Take the Alpha Hunter and make it the new Rotation for beast master.... then Remvoe the option because its there".
- **The research** (read 2026-10-10): Icy Veins' Forever BM guide (5 Oct) and class overview, wowtbc.gg's BM page (its Level 30 list and builds), Mobalytics' BM guide (9 Oct) and levelling guide. They agree on:
  - the pet goes in and hits first, then the shots start;
  - Hunter's Mark before the fight;
  - Serpent Sting once the pet has hit;
  - two hawks out at all times (Summon Hawk: 6 s cooldown, 18 s each, 80 mana; it shares Arcane Shot's cooldown);
  - Aimed Shot on its cooldown, Multi-Shot instead against several mobs (Forever gives them one shared cooldown);
  - Intimidation once the pet is on the mob, for its threat;
  - Aspect of the Hawk in a fight, for Deadly Aspects.
  - On a mob that pulls off the pet, Icy Veins says Disengage, Mobalytics says melee it. The build melees, as the user chose on 2026-10-09.
- **It is the Beast Mastery profile, with no option.** It runs for every hunter whose talents lead with Beast Mastery, from the first point and with none spent yet. Under 20 points, Levelling keeps the hunters led by Marksmanship or Survival; from 20, they keep their own profiles. A value the ALPHA's option saved is not read. Kill Command and Steady Shot stay in the list for Era (its runes); Forever has neither.
- **What it presses:**
  - Hunter's Mark, Mend Pet, Intimidation and Bestial Wrath as before;
  - after the pet's first hit, Auto Shot, Serpent Sting (spread as before), Summon Hawk (as before), Aimed Shot, then Multi-Shot;
  - Arcane Shot only before Summon Hawk is trained, as in Levelling since 1.7.5;
  - on a mob that reaches you: Raptor Strike, Mongoose Bite and the plain swing, while the pet takes the mob back.
- **Where it differs from Levelling:**
  - **The pet hits first, Auto Shot too.** Levelling fires Auto Shot at once. Here the wait ends at the pet's first hit: the mob turning onto the pet, losing health with the pet beside it, or a second with the pet beside it. Forever has no combat log to say so outright. There is no wait in a group, with no pet out, with the pet off or held on a focus, or with the mob already on you. The pet module gets 2 s to send the pet. A pet still not there 5 s after it was sent is not waited for.
  - **No Concussive Shot on a charging mob, and no Wing Clip, while the pet is out.** No guide uses them. A mob running away is still dazed. With no pet out, Levelling's slow and clip come back.
  - **Aimed Shot uses Forever's 2 s cast** (from the catalogue). Levelling still counts Era's 3 s. It goes on its cooldown when standing and when it lands before the mob does. On a pack, Multi-Shot takes the shared cooldown. On one mob, Multi-Shot only goes when the aim would not land in time. While the bar refills, one Aimed Shot a fight.
  - The mana rules of 1.7.4 still hold: the refill latch and the option *Mana for extra shots*.
- Internal:
  - `classes/hunter.lua`: the `beast_mastery` profile is the build; `pet_hit_first`, `pet_has_hit`, `pet_on_ours` and `pet_in_reach` (the wait), `first()`, `aimed_cast`, `bm_aimed`, `bm_multi`, `running_off`, `bm_slow`, `bm_clip` and `bm_swing`. `suggest` returns `beast_mastery` whenever Beast Mastery leads.
- Tests:
  - `aio_hunter_test`, 6 new: which profile runs, and that the ALPHA's option is gone; the pet-first wait and how its end is read; the bounds on the wait; Aimed Shot and Multi-Shot; the melee on a mob that reaches you; the hawks and Arcane Shot.
  - new `aio_forever_class_hunter_bm_test`: the whole plugin as a Forever hunter with nothing set. It fights with no error, and the profile running is Beast Mastery.
- Not yet seen in game. Guesses to check there:
  - that a second in reach is enough for the pet's first swing;
  - the 5 s cap on the wait;
  - that Forever's client says which mob the pet attacks. When it does not, the wait uses the mob the pet was sent at. The catalogue still asks the client before Intimidation.

**A PvP hunter (2026-10-10). Marked ALPHA/TEST.** The user: "Look up all PVP hunter for forever guides and Rotations and lets make an unstoppable PVP hunter where it can detect its in pvp mode and react instantly... know what to do what the player is doing how to Cast CC and kill". Until now a hunter fought a player with its PvE list. The reactions answered the player's control, burst, bubble and Vanish (1.81.0), but nothing kept a melee player off or used the hunter's traps on one. Fighting a player also changed nothing about what was shot.
- **The research** (2026-10-10): no Forever hunter PvP guide or PvP rotation exists yet.
  - Mobalytics' hunter PvP URLs all return 404. Icy Veins' and wowtbc.gg's Forever hunter pages are PvE only. Rankedboost has a theory build only, and says it has no play data.
  - So the rules are the Classic guides': Icy Veins' Classic hunter PvP guide and Wowhead's Classic hunter dueling guide.
  - What Forever changes (Icy Veins' Forever class overview, wowtbc.gg's talent calculator, Method): traps can be laid in combat; Freezing Trap shares its cooldown with Frost Trap, and only one trap is down at a time; Scatter Shot turns your attack off; Multi-Shot shares Aimed Shot's 6 s cooldown; Hunter's Mark shows a stealthed target.
- **New hunter option: *PvP hunter (ALPHA/TEST)*, off.** It is in the class window and under Hunter options. It is the PvP hunter's only option: the user, the same day, "Remove all the PVP hunter Options off the UI and just into one option still Alpha". The four that first tuned it (the trap first, the walk from a trapped player, the turn on an attacker, the switch to a player about to die) are fixed at what they defaulted to, and a value one of them saved is not read.
  - While it is on, PvP mode starts when your target is an enemy player, an enemy player within 40 yd is on you or your pet, or you are in a battleground with one that close. It holds 4 s past the last sign.
  - In PvP mode the new PvP profile runs whatever the talents, with the new reactions.
  - Fights are still yours to start.
- **What it reads off the other player** (`react/pvp.lua`, `M.foe`): its class, a druid's form, and from those melee, caster or ranged. A player seen casting a heal in the last 20 s is a healer. It also reads whether there is mana to drain and whether it can stealth.
- **The PvP profile, in order:**
  1. Hunter's Mark;
  2. Wing Clip and Strider Kick in melee;
  3. Concussive Shot on a melee player coming at you or anyone running off;
  4. Rapid Fire and Bestial Wrath;
  5. Aimed Shot where it lands;
  6. Auto Shot;
  7. Viper Sting on casters and healers (36+);
  8. Scorpid Sting on a player who fights with attacks, melee or a hunter's bow (22+). The user: "in pvp we should also use Scorpid Sting cause it reduces targest chance to hit with attacks for 20 seconds". One sting per target, so it takes Serpent Sting's place on them; it does no damage, so it goes before the trap too;
  9. Serpent Sting on the rest;
  10. two hawks;
  11. Multi-Shot, only with two or more enemies where it lands ("Neither PvP or AoE meele wave should Multishot if its not 2+ enemy mobs");
  12. Arcane Shot before the hawks;
  13. Mend Pet;
  14. the melee strikes only while stuck.

  The README has each condition.
- **The PvP reactions** (`react/rules/hunter_pvp.lua`):
  - *peel the melee*: Wing Clip first. Once the clip has not shaken the player after 1.5 s (or it ignores slows, you are under half health, or two are on you): Freezing Trap at your feet, Scatter Shot, Intimidation, or Frost Trap against two. No trap on a player something of ours ticks on, or one the pet is biting.
  - *Scatter into the trap*.
  - *Feign Death the cast*, in its last 0.6 s.
  - *turn on the player attacking you*.
  - *shoot another while this one is trapped*.
  - *finish the low one*.
- **Nothing breaks your own control:**
  - no shot, sting, hawk or burst into your trap or Scatter Shot;
  - the pet is kept off a target held by control that damage breaks, in PvE too (`pet.lua`);
  - no burst window opens on such a target (`burst.lua`).
- **The trap opener:** from a frozen player the step out walks on to 25 yd (Intercept and Charge reach 25), then Rapid Fire and Aimed Shot.
- **The trap first:** while Freezing Trap is ready, a melee player coming at you gets no sting and no hawk. Their ticks would break the trap.
- Changes outside the PvP hunter:
  - **The step out**, in PvP mode, walks from a player held by any control, not only a slowed one (`kite.lua`). PvE is unchanged.
  - **The hunter's "stop the cast"** Scatter Shots an enemy healer's heal in PvP.
  - **The core defensive** leaves Feign Death on a player's cast to the timed rule.
- Internal:
  - new `modules/pvphunter.lua`: PvP mode, `held` (our control on a player), `reset_to` (the kite's walk), `status`;
  - `classes/hunter.lua`: the `pvp` profile and its predicates, `spread_ok` (shared with `sting_wanted`), `pvp_status`; `suggest` asks PvP mode first;
  - `react/init.lua`: `CLASS_EXTRA_RULES` loads `hunter_pvp`;
  - `classwin_data.lua` and `classwin.lua`: the option and its line (`hunter_pvp`).
- Tests:
  - `aio_hunter_test`, 8 new: which profile runs; nothing into the trap and the opener; the trap first; the stings by class; the melee kept off; where Aimed Shot goes; Multi-Shot only on two or more; Scorpid Sting on attackers.
  - new `aio_hunter_pvp_test` (17): through the reaction engine, from the off switch and PvP mode's hold to every reaction above and the class window's line.
  - new `aio_forever_class_hunter_pvp_test` and `aio_forever_class_hunter_pvp_mob_test`: the whole plugin as a Forever hunter with the option on. Against an enemy rogue the profile running is PvP; against a mob it stays Levelling. No error in either.
- Not yet seen in game. Guesses to check there:
  - that a trap laid under a player standing on it springs once it arms;
  - that Feign Death makes a player's cast at you fail on Forever (it can miss);
  - that the hawks break a trap (no guide says; assumed);
  - on Era, that stop-attack ends Auto Shot;
  - the 1.5 s before escalating past the clip, the 0.6 s Feign Death moment, 25 yd.
  - Not done: Aspect of the Monkey when stuck in melee (aspects stay yours, in the Aspects window), Scare Beast on a druid's form or an enemy pet, a Flare where a stealther was last seen before it engaged, the pet sent at an enemy healer.

**The guide walk no longer sets off for another continent, and the ESP draws the route it walks (2026-10-10).** The user: "Check Rested EXP and Forever actually working ensure its giving ESP Pathing to wheres its suppose to go and that sentinel works". Today's trace on Forever had `guide walk: walking to  (15210 yd, Sentinel)` from Stormwind.
- **What happened, from the recorder:**
  - RestedXP's waypoint was map 1439 (Darkshore) at 0.3721, 0.4422, with no title.
  - The map call turned it into x 6402, y 504.4 on continent 1, Kalimdor. You were on the Eastern Kingdoms (instance 0), about 15,200 yd from that spot.
  - Only `wrong_continent` was checked, and the waypoint did not set it. So the guide walk sent Sentinel at a point that is nowhere you can walk. The guide's line, the gold beacon and the route beacons pointed there too.
  - Before that the trace shows walks to your kills only ("your kill", 4 to 12 yd). Each one moved you within Sentinel's 6 s and looted. No talk, pull or waypoint walk had run in game yet.
- **A waypoint on another continent is not placed.**
  - The continent the map call answers is checked against yours.
  - RestedXP's own distance is checked against ours: more than its own size and 200 yd apart, and the waypoint is not used.
  - A map the client cannot place (it answers 0, 0) is no place.
  - So nothing is walked, drawn or beaconed there.
  - The guide walk says "the guide's next stop is in Darkshore, on Kalimdor (you are in the Eastern Kingdoms): get there yourself (boat, flight or hearth); it walks on once you are there".
  - The guide panel's row reads "-> Darkshore, on Kalimdor  away".
  - The log and the trace say it once per waypoint.
- **A waypoint with no title has a name.** Goto steps often have none, so the walk said "walking to  (…)". It now uses the step's goto words, else "step 12's waypoint". A patrol stop is "stop 2 of step 12". The panel and the line use the zone's name ("-> Westfall").
- **RestedXP's "no waypoint" is no waypoint.** It is a table with map 0, and 0 is true in Lua, so the panel showed an empty "->  0y" row.
- **New: *Draw the route it walks*** (Quests page, *Follow the guide*, on).
  - While the guide walk moves you, a solid line in the guide's colour runs to what it is walking to: the npc, the mob, your kill or the waypoint.
  - It follows Sentinel's own path, round the walls Sentinel goes round, from the leg you are on, cut at *Line length*.
  - The label gives the distance along the route.
  - It takes the guide line's place. Without a path of Sentinel's (a straight walk, or a route not planned yet), it is the ground line straight at the goal.
  - Sentinel's path is used only when it ends within 10 yd of the walk's goal, so another plugin's route is never drawn as the walk's.
- **The trace shows a walk arriving**, not only starting: "guide walk: got to Marshal McBride (Sentinel, 14s)". The Quests page's Sentinel line gives its version.
- **Quest spawn paths on Era and Forever start from their own map ids.** The zone seeds were retail map ids (Elwynn Forest 37, Westfall 52). Neither client has them: their UiMap tables use 1411–1458, read from both installed clients (Forever 1.60.1.70291, Era 1.15.9.70003). Forever answered 0, 0 for every one, so a quest's spawns had no path until its zone was learned on the spot (2,467 recorded calls).
- Internal:
  - `quests.lua`:
    - `CLASSIC_MAPS` (map id → name, continent, AreaTable id) and `here_continent()` (`ctx.world.instance_id`).
    - `waypoint_to_world` returns `world, away`; `describe_away` builds `rxp.waypoint_away`.
    - `draw_walk_route` and `route_start` draw the route; `render_hud` draws them in place of `draw_waypoint_lines`.
    - `SEED` picks the classic seeds on Vanilla and Forever.
    - New exports: `M.waypoint_to_world`, `M.draw_walk_route`, `M.map_for_area`.
  - `guidewalk.lua`:
    - `M.route()` returns `{ goal, label, mode, path }`. The path is `sentinel_path(goal)`, read from `JCore.nav.current_path`, since `ctx.nav` does not hand the path out.
    - The `w.away` wait, the title fallbacks, the arrival note, the Sentinel version, and `stats().away`.
  - `main.lua`: `rxp_follow_route`.
- Tests:
  - new `aio_guide_waypoint_test` (13):
    - Darkshore read in Stormwind, with the recorder's numbers, and the same waypoint read in Darkshore;
    - `wrong_continent`; a 0, 0 answer; RestedXP's distance; the zero waypoint; a step's stops;
    - the route along Sentinel's path, a short one ending in a ring, the straight fallback, the guide's dashed line when idle or switched off, a route that raises;
    - the seeds per client.
  - `aio_guidewalk_test`, 5 new: the wait for another continent; a walk under way dropping such a waypoint; the title fallbacks; `route()` against Sentinel's path, another plugin's, none, and a straight walk; the arrival line. 1 changed: the page's Sentinel line carries the version.
- Not yet seen in game. To check there:
  - the solid line along Sentinel's path while the walk runs;
  - the "next stop is in …" line when RestedXP points at another continent;
  - that `JCore.nav.current_path` answers Sentinel's path on Forever (only `get_current_path` exists in its API notes, v0.0.5).

**The ESP shows which mobs a skin can give Pristine from (2026-10-10).** The user: "Let's add Mobs that when skined also give pristine cause i dont see any so far". Forever's Pristine Leather, Hide and Scale are a rare bonus on top of a skin's leather. Classic's tables (the rows below) have never heard of them, so no corpse ever listed one.
- **A green "Pristine Leather · rare" pill** with the item's own icon:
  - under a corpse your Skinning reaches, after the Classic rows. A Forever creature with no Classic table (Gray Fox) gets it alone;
  - under the living mob too, so you know which to kill. Nothing without Skinning. Above your skill it is dimmed, icon and all, and says what it asks for: "(Requires Skill 115)".
  - Every detail but the icon alone shows it.
- **New switch:** *Pristine Leather / Hide / Scale: mobs that can give it* (`show_pristine`, on), in the ESP page's *World* section, under the skinning one. It switches off both the living and the corpse pills; *Skinnable corpses: what skinning gives* no longer hides the Pristine one.
- **Which mobs: 43, all for the Leather.**
  - **41 from the QuestieDB in the Forever client** (1.0.5, each item's `npcDrops`), level 10 to 24: Goretusks and the Coyote Packleader (Westfall), Black Dragon Whelps and Great Goretusks (Redridge), Rabid Dire Wolves (Duskwood), Wetlands and Loch crocolisks, Elder Black Bears and Daggerfang (Loch Modan), Silverpine's bears and Moonrage worgen, Darkshore's bears, Moonstalkers, Thresher and Foreststriders, 19 Barrens beasts (plainstriders, zhevras, a kodo, thunder lizards, Sunscales, Savannah cats, Hecklefangs, the Oasis Snapjaw, the Deviate Coiler and Stinglash), and Ashenvale's Wild Buck.
  - **2 from your own skins:** the TrackMe addon's log, 259 skins in Duskwood, Redridge, Darkshore, the Barrens and the Wailing Caverns. 3 gave Pristine Leather, 2 or 3 at a time: a Rabid Dire Wolf (1 of 62), a Starving Dire Wolf (1 of 43) and a Gray Fox (1 of 4). The last two are new.
  - **No chances:** neither source has one per creature, so the pill says "rare". Yours came to 3 skins in 259.
  - **None for the Hide or the Scale yet.** Nobody has reported a creature for either. Your 11 Pristine Hide came from the auction house.
  - Wowhead's Forever database lists 22 creatures for Pristine Leather (the guide sites quote it), but it answers scripts and headless browsers with a 403, so it was not read. foreverdb.net and the other Forever databases say where it comes from "isn't known yet".
- Internal:
  - `tools/jcheck/skinning_extract.js`: `PRISTINE`, `SEEN` (finds by hand, so a later run keeps them once TrackMe's log rolls over), `questdb()` (through `questdb_extract.js`, as `rares_extract.js` does), `trackme()`; new options `--addons`, `--qdb`, `--trackme <file>|none`. It prints each new TrackMe find to add to `SEEN`. TrackMe's creature names become npc ids through QuestieDB, else `scripts_data/jcore/jcore.names.json` (Gray Fox is 277645, Forever's own).
  - `tools/jcheck/lib/savedvars.js` (new): reads an addon's SavedVariables file.
  - `modules/skinning_data.lua`: `pristine[npc] = { item ids }`, `pristine_source`, `count.pristine`; Pristine Leather in `items` (48 now).
  - `esp/forever.lua`: `S.pristine`, `pristine_of`, `pristine_rows`, `card_pristine` (called from `card_unit` after `card_beast`); `card_skin_loot` adds the Pristine rows after the Classic ones.
  - `esp/page_forever.lua`: the switch. The art pack gains the `item.249427` cell.
- Tests:
  - `aio_skinning_data_test`: 1 new (the 43, their items, Pristine Leather's name, quality, icon and cell); 1 changed (48 items).
  - `aio_esp_forever_test`, 3 new: the corpse pill after the Classic rows, in green with its icon, alone on Forever's own kind, none on a kind never seen; the living mob's pill, green, and dimmed with the skill it asks for; none without Skinning, for a kind never seen, at the icon alone, or with the switch off, and the two switches apart.
- Not yet seen in game.

**A skinnable corpse lists what skinning it gives, with each item's chance (2026-10-10).** The user: "I want ESP now to show similar thing for What skinable corpse can give me by % if its multiple items".
- **New rows under a corpse marked SKIN** (your Skinning reaches it), on Forever's ESP. There is one pill per item that kind of corpse can give, most likely first:
  - the item's own icon, as in your bags;
  - its name, in its quality's colour;
  - how many, when it can be more than one;
  - its chance: "Light Leather x1-2 · 41%", "Medium Hide · 3.4%".
  - Most corpses roll once among their items, so the chances add up to 100%. A dragon's or a boss's rolls some items on their own and adds up past it; The Beast gives Rugged Leather x4-6 80%, Rugged Hide x1-2 18%, and Pristine Hide of the Beast 1.9% in purple.
  - Every detail but the icon alone shows them. A corpse your Skinning cannot take is still not marked at all.
- **New switch:** *Skinnable corpses: what skinning gives, with chances* (`show_skin_loot`, on), in the ESP page's *World* section.
- **Where the data comes from:** the client has no loot tables. `tools/jcheck/skinning_extract.js` reads them from CMaNGOS's Classic world database (github.com/cmangos/classic-db, `skinning_loot_template`), the same Classic data foreverdb.net's skinning page is built on. It writes `modules/skinning_data.lua`: 924 creatures, 774 tables, 47 items. The item names are CMaNGOS's; each icon is the client's own (`Item.db2` `IconFileDataID`).
- **Not covered:** Forever's own creatures are not in Classic's tables, so their corpses show the pelt alone. Whether Forever changed a Classic creature's skinning loot is unknown; the chances are Classic's.
- **The icons ship with the plugin:** the art pack gains 47 cells (`item.<item id>`). Its PNG grows from 267 KB to 406 KB. Without a cell, the item's icon comes from the web.
- Internal:
  - `esp/forever.lua`: `SKINNING` (the file, loaded beside `RARES`); `card_skin_loot`, called from `card_corpse`, which now takes the corpse's facts for its npc id. Adds `S.skin_loot`, `chance_text`, `quality_col` and `SKIN_ROWS` (8, the longest table).
  - `esp/page_forever.lua`: the switch.
  - `tools/jcheck/art_pack.js`: the `item.` cells, from `skinning_data.lua` (`--skinning`).
  - `tools/jcheck/dbd/Item.dbd`: new, from WoWDBDefs.
- Tests:
  - `aio_skinning_data_test` (new, 5): the counts; a Winter Wolf, the Large Loch Crocolisk and The Beast; a shared table; sorting and sums; every item's name, icon and art cell.
  - `aio_esp_forever_test`: 4 new: the rows, their order, counts, chances and icons; The Beast's epic in purple and a shared table; the switch, one of Forever's own kinds, the icon alone, and a corpse you cannot skin; no art pack.
- Not yet seen in game.

**Two experience bars on Forever's ESP: what your finished quests and your whole quest log will give (2026-10-10).** The user: "on ESP for forever Write up a moveable EXP Bar that show's Exp/hour counts how much EXP going to get and fills the bar once completed quests are Turned in and one that does the same but for all quests in my Questlog". Built first as JCore windows; then "Make it ESP not like a UI", "also more readable".
- **Two new bars on Forever, drawn by the ESP, each with its own switch, both on:**
  - *TURN-INS*: your experience in purple, and in gold what the quests you have finished add when you hand them in.
  - *QUEST LOG*: the same, then in blue what the rest of your log adds.
  - No window, no title bar: each is one dark plate, the ESP's own pill backdrop, on the ESP's HUD layer. They hide with the ESP's switch and its toggle key, and in *RestedXP guide only*, like every mark.
- **What each shows,** in text with a dark rim at *Text size* (16 px by default):
  - top: `TURN-INS  +1,350 XP  -> Level 19 (2%)`, and the XP per hour at the right;
  - the bar: shaded stretches, tenths ticked, the rested pool's end in blue, and `18,500 / 19,400   95.4%` on it;
  - bottom: what is in the sum (`1 finished quest to hand in`; the log's `1 finished +1,350 XP | 1 to do +~1,350 XP`), and `Level in 1h 05m` at the right.
  - A sum past the level fills the bar, with a strip under it for how far into the next level.
  - Handing a quest in fills the bar for real, and its gold goes.
  - Put the cursor on a bar for its quests under it, each with its pay.
  - A bar is never narrower than its words need, so nothing overlaps at any text size.
- **Moving them:** switch on *Move the XP bars*. A small handle sits above each bar, *Drag to move: TURN-INS bar*; drag it and the bar follows. Switch it off and the bars stay where you left them. The ESP cannot take the mouse from the game, so the handle is a JCore window: without it the game turns the camera on the drag.
- **New section on the Forever ESP page, *Experience bars*:** *XP bar: what your finished quests give when handed in* (`xpbar_ready`), *XP bar: what your whole quest log gives* (`xpbar_log`), *Move the XP bars* (`xpbar_move`, off), *Text size* (`xpbar_text_size`, 16 px), *Bar width* (`xpbar_width`, 460 px), *XP per hour over the last* (`xpbar_rate_minutes`, 30 min) and *Start XP per hour again* (`xpbar_reset`).
- **What a quest pays:** no client call says, so it is worked out.
  - Classic's quests use QuestieDB's own quest xp table, the one Questie reads, from the Forever client. `tools/jcheck/questxp_extract.js` writes `modules/questxp_data.lua` (3,490 quests). It is exact on Forever: the recorder's two `QUEST_TURNED_IN` examples (quest 244 for 290, quest 65 for 1,350) are the table's.
  - Forever's own quests (ids past 90000) are not in it. They show with `~` at what a standard quest of their level pays (850 at 10, 1,550 at 20, 6,600 at 60). Once one is handed in, it pays what it paid, on every character. After three, every guess takes the ratio they actually paid.
  - Questie's level penalty applies: full pay up to the quest's level + 5, then down to 10%, rounded as the server rounds.
  - When the game pays table quests 4% or more off the table (an xp buff, a server rate), every table quest follows.
- **Experience per hour:** from `core.character.get_xp` / `get_xp_max`, read twice a second on the bars' own timer (so it keeps counting with the ESP hidden), across level-ups too. A read the client cannot answer (0 of 0, a loading screen) and a drop with no level-up are skipped, and a level read that lags the experience counts its level-up once. The rate covers the last 30 minutes (your choice) and shows from the first minute.
- Internal:
  - `modules/xpbar.lua`: new. `reward`, `summary`, `rate`, `reset`, `layout`, `need_width`, `render(visible)`, `stats`. It draws with `P.draw` (`rect_2d`, `text_2d`, `measure`; `plate_2d` where JCore has it) and reads the cursor with `ctx.input.cursor_position` for the quest list. It sums `P.quests.index`, leaving out a guide's offered quests, failed ones and, for 10 s, one just handed in (the index lags it), and keeps what it learns in `jambix.aio.xpbar.json`. Traces `xp bar:` lines: the experience reader once, and each turn-in against its prediction.
  - `modules/questxp_data.lua`, `tools/jcheck/questxp_extract.js`: new.
  - `main.lua`: built when `P.forever`, after the guide walk; its own render job (208), passing the ESP's switch, toggle key and *RestedXP guide only* as `visible`.
  - `esp/page_forever.lua`: the section.
- Tests: `aio_xpbar_test` (new, 15): the table's pay and the penalty; a guess, then learned; guesses corrected; a game paying 1.5x; experience per hour across a level-up and the window; a 0 / 0 read; a lagging level read and a bad drop; the sums past the level; both bars with no window, their words, the gold and their switches; the quest list under the cursor; bigger text widening the bar; the move handles; the strip past the level; max level; kept for the next character. `aio_boot_xpbar_test` (new, 6): the whole plugin as Forever, both bars painted through JCore's draw queue with no window, hidden with the ESP's switch and toggle key while the rate counts, the move handles as JCore windows, each switch, a turn-in learned.
- Not yet seen in game.

**Hunters: aspects swap for you only with *Auto swap aspects* on (2026-10-10).** The user: "In the Hunter UI the option to Auto Swap Aspect should be a thing if its not enabled it should nto swap any aspecs at all". Since 1.50.0 one swap was always made for you: out of Cheetah or Pack into the aspect you last fought in, just before a hit would daze you. Nothing turned it off.
- **New switch:** *Auto swap aspects* (`rot_hunter_auto_aspect`), **off by default**. It is in the Hunter window, under the aspect switches, and on the Rotation page with the other hunter settings.
- **Off:** no aspect is swapped for you. Cheetah stays up through the hit. Neither the reaction *Out of Cheetah before the hit* nor the Aspects keeper's guard (the same swap with the rotation off) acts.
- **On:** as before.
- Either way the aspect you switched on is still put back after a death, a dismount or a reload. That keeps your choice; it swaps nothing.
- Internal:
  - `modules/aspects.lua`: `M.auto_swap_on()`; `M.can_switch` refuses and `M.switch_to` sends nothing with it off; the keeper's guard asks it; the window body draws the switch and writes it to the Rotation page; `stats().auto_swap`.
  - `react/rules/hunter.lua`: *Out of Cheetah before the hit* proposes nothing with it off.
  - `classes/hunter.lua`: the setting and its lines in `settings`.
- Tests:
  - `aio_aspects_test`: the keeper's guard tests switch it on. 2 new: off, a mob in melee swaps nothing and a switched-on Hawk still comes back after a death; the window's switch turns it on and off. The window test counts four switches.
  - `aio_react_test`: the Cheetah tests switch it on. 1 new: off, the reaction never offers and the keeper never swaps.
- Not yet seen in game.

## 1.7.5 (2026-10-09)
**While the rotation is paused, the class window stops playing for you.** A player: "was wondering on paladin if there is a setting to stop auto applying seal even when rota is paused?" There was no such setting. Anything picked in the class window counted as your own choice, so the window kept it up whenever the plugin was on, paused or not:
- **Seals:** a paladin's seal (30 s) went back up twice a minute in town, and straight after every Judgement made by hand.
- **Fight buffs:** a shaman's shield, and a hand-switched Battle Shout or Inner Fire, were recast in the middle of fights you were playing yourself.
- **Stances and forms:** a picked stance or form was forced back every 1.2 s. A warrior who took Battle Stance to Charge was put back in Defensive. A druid who left Bear Form to heal, or took Travel Form, was put back in Bear.

What changed:
- **New setting for every class: *While the rotation is paused, keep up*.** It sits in the class window's own section and in the Rotation page's Class window section. Its three choices:
  - *Out-of-combat buffs* (the default): armors, auras, blessings, shields, Fortitude, Arcane Intellect, Mark of the Wild and the like, out of combat only. Never a seal, a stance or a form, and nothing during a fight.
  - *Everything picked here*: as before 1.7.5, except that a stance or form you take yourself is now left alone (see below).
  - *Nothing*: the window waits for the rotation.
- **Unchanged:**
  - What you never picked (the window's defaults) still waits for the rotation.
  - *Auto* still never casts anything while paused.
  - The hunter's aspects are not affected: they already follow what you do.
- **A stance or form you take yourself is left alone** while the rotation is paused (with *Everything picked here*). The window's line says "left as you set it until the rotation runs". The pick is held again after a death or a mount, once the rotation has run, or when you pick again.
- **The window's idea of "running" now matches the rotation's:** *Enable rotation* on and its key active. Before, the key alone counted. So with the rotation switched off but its key active:
  - the window kept its untouched defaults up (Battle Shout, Inner Fire...);
  - nobody held a picked stance or form;
  - the status line read "Rotation on".

**The paladin seals only when there is something to seal for.** With the rotation running and nobody about, every profile put Seal of Righteousness up every 30 s. An offline idle run counted 4 seals in 2 minutes, each one costing mana and five seconds of mana regeneration.
- A seal now goes up in a fight, or out of one with an enemy targeted within 30 yd, so the opening Judgement still has one.
- The Holy profile already sealed in combat only.

**The druid keeps Travel Form.** With the rotation running, the form keeper shifted a druid out of Travel or Aquatic Form straight back into Cat or Bear. It also undid the Travel Form the reactions cast to escape.
- Out of combat, and in a fight while you are moving (running away), the rotation now leaves those forms alone and casts nothing, as on a mount.
- Standing still in a fight, it takes the profile's form again.

- Internal:
  - `classwin.lua`: `running()` (Enable rotation and the key); `acting(key, def, player)` reads `classwin_paused` (1 out-of-combat buffs, 2 everything, 3 nothing); `keep_form` lets go of the pick once you take another form.
  - `classwin_data.lua`: the seal group is `fight = true`; `OPTIONS.common` gains the "While the rotation is paused" section.
  - `main.lua`: `classwin_paused` in the Rotation page's Class window section.
  - `classes/paladin.lua`: `seal_wanted` (`SEAL_AHEAD`, 30 yd) for the seal upkeep rules.
  - `rotation.lua`: `travelling(class_module, s)` (`M._travelling`), checked before the form upkeep. `classes/druid.lua` gains `travel_forms`.
  - `mock/forever_class.lua`: the druid gains Travel Form, and the mock gains `sim.enter_form(name)`.
- Tests:
  - `aio_classwin_test`: 6 new (the default while paused; shields and shouts in a fight; *Everything* and *Nothing*; *Enable rotation* off with its key active; a form taken by hand; the setting in every window), and 1 changed (a picked stance is held while paused only with *Everything*). Its harness now switches *Enable rotation* on.
  - `aio_paladin_test`: 1 new (seals in a fight, before a pull, never with nobody about).
  - New `aio_forever_class_druid_travel_test`, which boots the whole plugin as Forever. Without the fix it fails, with Cat Form at 0.0 s.
- Not yet seen in game.

**Fishing's anti-AFK is Jambix Market's.** The user: "change finishs anti afk from jumping to the one marketplace uses". The jump every 150 s never kept Forever's Away off (1.67.1).
- **Between casts, every 2 minutes:** a short turn each way, through JCore's movement lease. The facing from before is then looked at again, so the bobber lands where it did. If the game marks you Away anyway, a short sidestep each way takes over, and after that a jump.
- **Judged the way Market judges it,** by the "You are now Away" system message. A kind fails when Away comes within 5 minutes of it. It also fails when it went out while you were Away and the Away is still on 30 s later; Market does not have this rule. Away answered at most once a minute. What failed and what held is kept across sessions (`jambix.aio.presence.json`). Once every kind has failed, keep-alives stop and the Fishing page says so.
- **The Fishing page:** the switch is now *Stay active so you are not marked Away (anti-AFK)*. Switching it off and on forgets what was learned. A fourth live line shows the kind in use and whether it is working.
- Nothing goes out while you type, during a cast, or while something else holds movement.
- Internal: `modules/fishing.lua` drops `PLAYER_FLAGS_CHANGED` and the 1.67.1 echo rules, and listens to `CHAT_MSG_SYSTEM`. New `fishing.presence()` and `fishing.reset_presence()`. `stats().away_anyway` is set once every kind has failed. `main.lua`: `fishing_page:live_lines(4)`.
- Not yet seen in game while fishing. Market's file records the turn as holding (2026-10-08): 15 minutes of turns with no Away. That is not proof, since your own input in those minutes would also have held Away off.
- Tests: `aio_feedback_161_test`: three 1.7.5 cases replace the 1.61.2 and 1.67.1 ones. They cover:
  - the turn, its timing and the facing;
  - the failure chain and giving up;
  - Away before any keep-alive, Away that stays on, a kind that holds, and switching off and on.

**Every Forever rare is tagged RARE on the ESP, and elites and bosses say ELITE and BOSS.** The user: "I wanna pull up a list of all Forever Rare Mobs (includes classic) and tag them in ESP with RARE". The Forever ESP took a mob's rank from the client's creature cache only. The cache holds what earlier sessions met, and a new build wipes it, so a rare met for the first time was drawn as a normal mob. With the art pack it said "rare" only with the small silver dragon.
- **The list:** `modules/rares_data.lua`, 421 rares (291 rare, 130 rare elite) by npc id:
  - 398 from Classic, from the QuestieDB in the Forever client. foreverdb.net's 354 Forever rares are all among them.
  - 15 of Forever's own: Matriarch Bristlefur, Ghostfang, Snarlsnout, Nightscreech, Blightsculler, Coldrasp, Shal'ma, Nightveiled Rotheap, and the Zephras Isle set (Fernfeather, Galemender Delanea, Den'dralass, Mystmane, Tel'daeor the Stormspeaker, and the rare elites Slydris and Snapbeak the Quick).
  - 8 of Season of Discovery's that are in Forever's world: Mokwa, Raluk, Jorul, Mowgh, Kackle, Koartul, Carrodin, Zopilote.
- **Where a rank comes from now:** the creature cache, then the game itself (`get_classification` answers on Forever since the 2026-10-06 core), then the list. A rank the game does give always wins: the list says rare elite for VanCleef, Forever says elite.
- **The tag:** a rare says **RARE**, a rare elite **RARE ELITE**, in the Rares colour after its name. It shows at every detail, the icon-only one included, with or without the art pack. The silver dragon stays. The *Elite, rare, boss* switch turns both off. Without the art pack the word is no longer repeated in the facts.
- **Elites and bosses say so too.** The user, in Wailing Caverns: "I see Elites and I dont see Elite Tags on them". Since 1.69.0 the art pack's gold dragon or skull stood alone for an elite or a boss, with no word. Every rank now has its word after the name, in its category's colour: **ELITE** (Elites orange), **BOSS** (Bosses purple), **RARE ELITE**, **RARE**. In a dungeon every mob is an elite, so every mob there says ELITE.
- **Forever's dungeon bosses are BOSS, not ELITE.** Forever never reports rank 3; its bosses are elites the client flags `is_boss` (VanCleef, Mr. Smite). The Forever ESP now treats an elite with `is_boss` as a boss: the BOSS word and skull, the Bosses row's switch and range, the beacon, and the "Boss" alert in a dungeon. A rare elite with `is_boss` (Marisa du'Paige, Brainwashed Noble) stays a RARE ELITE.- A listed rare is in the Rares category, so the Rares row's switch and range, the beacon over a far rare and the rare elite's alert all apply to it.
- Only the ESP reads the list. Targeting, the field and the reactions still take JCore's rank.
- Internal:
  - New `tools/jcheck/rares_extract.js` writes `rares_data.lua`. It reads the QuestieDB in the Forever client through `questdb_extract.js`, and keeps the hand lists `FOREVER` and `SOD`, each entry with where it was seen.
  - `esp/forever.lua`: `RARES`; `facts_of` sets `f.rank_src` (`cache`, `game`, `list`, plus `+boss` when `is_boss` made an elite a boss); `card_unit` draws `rank_word` in `rank_col` on the name row, and the no-art fallback no longer puts the rank in the facts.
  - The `fesp` trace reads `rank=4/list`, `rank=3/cache+boss`.
- Tests: `aio_esp_forever_test`, 3 new and 1 changed:
  - a rare the cache never met, a listed rare elite, a cached elite the list calls a rare elite, a rare only the game names, and the Rares switch;
  - the tag after a known name, at icon detail, once with no art, and off with the rank switch;
  - ELITE after the name in the Elites colour, an elite with `is_boss` as BOSS, a rare elite with `is_boss` still RARE ELITE, the words once with no art, and off with the rank switch;
  - changed: the 1.69.0 "no ELITE word beside the dragon" is now ELITE once, on the name row.
- Not yet seen in game.

**The hunter stops using Arcane Shot once Summon Hawk is trained.** The user, after a comparison with the Forever guides, asked for Mobalytics' approach. On Forever the two share one 6-second cooldown.
- **Before:** Arcane Shot went out in the gap while both hawks were up, from 45% mana when the mob was closing or the hunter was moving.
- **Now:** every Arcane Shot press is a hawk's cooldown. Mobalytics' levelling guide: "Summon Hawk shares a cooldown with Arcane Shot. This is the primary reason we aren't using it in the rotation at all." Icy Veins keeps one Arcane Shot in that gap, but only when capped on mana.
- **Unchanged without the talent:** a hunter without Summon Hawk (before it, or Marksmanship or Survival) uses Arcane Shot as before.
- Internal: `classes/hunter.lua` `arcane_wanted` returns false once Summon Hawk is known, in every profile. `catalog/hunter.lua`: the Summon Hawk synergy says what each guide does.
- Tests: `aio_hunter_test`: 1 new. It covers the filler before the hawks, none once trained, none with both hawks out or on the move, and none in the three talent profiles.
- Not yet seen in game.

## 1.7.4 (2026-10-09)
*Renumbered: 1.7.4 follows local 1.89.0. From this release the AIO's version follows project-sylvanas.net's numbering for it (plugin 1129, where the last upload reads 1.7.3). The entries below keep their local numbers.*

**Follow the RestedXP guide with Sentinel Navigation.** The user: "add sentinel to the Rested EXP as an option so it now follows quests from rested exp automaticlaly and does it for it too".
- **One switch** at the bottom of the Quests page's RestedXP section: *Follow the guide with Sentinel Navigation*, off by default. On, it walks RestedXP's current step with Sentinel Navigation and does it (`modules/guidewalk.lua`):
  - **Hand-ins and pick-ups:** walks to the npc who takes the quest back or hands it out, talks to it, and answers its windows for the step's quests only, the hand-in first. The reward is the guide's choice, else the one Forever's quest givers would take. A quest at an object (a wanted poster) is used.
  - **Kill steps:** walks to the nearest mob the step's quests want and pulls it (26 yards for casters and hunters, melee for the rest). The rotation opens on it and fights; with the rotation off an attack is started. Sticky steps' mobs within 30 yards too. Quest objects are walked to and used. With nothing in sight, the step's stops are walked in turn.
  - **Go-to steps:** walks to the waypoint.
  - **Loot:** your kills within 30 yards are walked to and looted (by auto-loot when that is on).
  - **Anything else** (hearthstone, flight, trainer, item): walks to the waypoint and waits, saying what the step wants.
  - Four switches turn the talking, the pulling, the objects and the looting off one by one; *Look for them within* (60 yd, advanced).
- **Watched walks.** Sentinel not moving you in 6 s, no progress in 10 s (planned again twice), or a route it gives up: a target within 40 yards is walked straight at, a farther one pauses the walk 20 s and says why. Three walks in a row Sentinel never moved pause it a minute.
- **It waits and lets go** while you are dead, in combat, resting or under 60% health before a pull, when hardcore says no pull, with a loot or quest window open, and for 3 s after you press a movement key or Space: steering is how you take over.
- **Never on an ESP-only client** (TBC, Wrath, Mists, Retail): `rxp_follow` is in main.lua's `ESP_ONLY_OFF`, since JCore's nav takes its own movement lease.
- **On the pages:** three live lines on the Quests page (what it is doing, Sentinel's state, the counts) and a *Guide walk* line on the Overview.
- Internal:
  - `rotation.may_engage_unit`: true for `guidewalk.pulling(target)`, the mob it stands in range of. `targeting.better_target`: out of combat, `guidewalk.pull_target()`.
  - `quests.lua`: RestedXP is read while the walk is on with *Enable RestedXP ESP* off too; `is_guide_target` still follows that switch, `guide_goal(name)` does not. New `quest_people(id)` (givers and enders, npcs and objects) and `quest_name(id)`.
  - The reward choice (`fit`, `pick_reward`, `role_of` and `who`) moved unchanged from `forever_npc.lua` to the new `modules/rewards.lua`.
- Not yet: flying, flight paths, the hearthstone, trainers, vendors and the corpse run. Those steps wait for you.
- Tests: new `aio_guidewalk_test` (29) and `aio_guidewalk_hooks_test` (3, the whole plugin as Era). `rxp_follow` joins the boot suites' acting switches (`mock/aio_boot_checks.lua`).

**The hunter leaves spirit time to refill the bar.** The user: "hunter rotaiton burns through alot of mana doest let the spirit recharge up". The live log (a level 19 hunter on Forever, 606 mana) went from a full bar to 30 in three minutes of seven-second fights. Each fight had a mana-costing press every two seconds: Multi-Shot on one mob at a full bar, two hawks, the sting, then Concussive Shot, Wing Clip and Raptor Strike on a mob a second from dead. So the five-second rule never ran out. Every fight was affordable on its own; the run of them was not.
- **The refill.** Once the bar is under half, only the essentials go out until spirit has it back to 80%: the opener, the mark, a sting on a mob that lives 13 s, one hawk on the same, Multi-Shot on a pack and the slows. It is a gap, not a line, so a run of pulls cannot pin the bar at the line.
- **Fillers only with a nearly full bar.** Multi-Shot on one mob, and Arcane Shot as a standing filler, now need 80%. Before, they went out down to 45% whenever the fight could afford them.
- **Nothing spent on a mob about to die.** A mob with under 2.5 s to live gets no shot, sting, hawk, slow, Wing Clip, Raptor Strike or Mongoose Bite, whether or not it is on you. The reaction engine's own check (`adapt.lua`, `FINISHING`) does not apply to a mob that is on you. A runner is still slowed if it has more than a second left.
- **Mana for extra shots** (hunter options and the hunter's class window): *Spend freely* (as before), *Balanced* (default: refill from 50% to 80%, fillers from 80%), *Save for regen* (70% to 95%).
- The Beast Mastery, Marksmanship and Survival profiles no longer cast Multi-Shot on a pack, Steady Shot, Kill Command or Explosive Trap when the bar is empty or will not last the fight (tier 0). This matches what the levelling profile already did.
- Internal: `classes/hunter.lua` gains `refill`, `dying`, `afford` and `on_pack`, plus the option `rot_hunter_mana_use`.
- Tests: `aio_hunter_test` (4 new: the refill and the setting's three positions, the hawks while refilling, a mob about to die, the talent profiles on an empty bar) and `aio_classwin_test` (1 new: the dropdown and its tip).

## 1.89.0 (2026-10-09)
**World marks: one layer for all of them, its own page, and eight new kinds.** The user: "Let's explore all posibilities with this and improvements and all the thingsn eeded to be done", choosing (asked which): Calibration window, Performance budget, Ring layout + World marks page, Line-of-sight fade; Swing timer + GCD, Time-to-die + execute, Missiles, Facing + patrol paths; Route + service beacons, Node memory + fishing, Group extras; PvP extras, Windows and HUD.
- **The world layer** (`modules/worldlayer.lua`, `P.worldmarks`): every ring, curtain, beacon and pulse of the AIO's world marks (pull safety, fight timers, kill next, your group, beacons, PvP marks, your reactions and the rotation's pick, the reactions' marks, the aurora, and everything new below) is kept as it is asked for and drawn at priority 190, after every job that keeps one. On the way it is **laned** (a ring under a unit with a lane gets that lane's radius, so the kick, time to die, the trinket, crowd control, diminishing returns, your timers and your reactions never overlap; under anything not a player the player-only lanes take no room), **budgeted** (*Most world shapes a frame*, 200: decoration goes first, then information, a warning never), **shaded** (brightness, a colour-blind correction, detail) and **faded** (a mark under a unit behind a wall at a third, through JCore's rationed line-of-sight checks). A mark whose drawing raises is counted and skipped and the rest of the frame still draws. Anything else (`line_3d`, `text_3d`, `theme`...) passes straight through to JCore's draw.
- **The World marks page**: *Look* (on/off, brightness 25-150%, detail Full/Reduced/Minimal, colour-blind colours), *Performance* (the budget, the wall fade, line-of-sight checks a frame), *Combat rings*, *Missiles, facing and patrols*, *Node memory*, *Calibration*, and a live count (drawn, dropped, spent, faded, by mark) with where each mark's own switches are. The older marks keep their switches where they were.
- **Calibration** (*Show the test pattern (12 s)*): each shader shape drawn round you, lettered, straight through JCore's draw: a shader ring a quarter full with the axes round it, the plain ring asked for a quarter, a curtain with its sheet, a beacon, a pulse every 2 s, a card plate beside a spell icon and a bar asked for half (the last two on JCore 1.15). One screenshot settles what was built from the API's descriptions alone.
- **Combat rings** (`modules/combatrings.lua`): your swing (a ring at your feet filling to the next auto attack or shot; from the Swing Timer addon, the loader's auto-attack helper, your swing and shot casts and on Era the combat log; dimmer past its time, a guess) and your global cooldown (a thin ring inside it, emptying); under your target a ring as full as its health with JCore's time to die at its feet; with your execute in range (Execute, Hammer of Wrath, Kill Shot, Shadow Word: Death under 20%, Drain Soul under 25%, whichever is in your spellbook) the ring red, a red curtain and a pulse as it crosses the line.
- **Missiles, facing and patrols** (`modules/tracks.lua`): a missile at you or your group, or from a hostile within 40 yd, as a line to where it lands and a ring there filling as it flies (red on you), under the one it is aimed at; none where the telegraphs already paint the landing. A faint wedge the way each hostile mob not yet fighting faces, as long as the range it notices you from (the nearest eight; `get_direction`, else `get_rotation`). The route a walking mob took (the last 20 s, kept here: the enemies' own trail is a second long) with an arrow the way it goes (the nearest four).
- **Node memory and the bobber** (`modules/nodememory.lua`): a herb, vein or chest that goes while you are near, alive and in the open world gets a ring where it stood, filling back up over *Expected respawn* (300 s), with its name and the time left; it is forgotten with a pulse when one of its kind is seen there again. Kept by the realm's clock across reloads (`nodememory` store, 30 a zone). A ring on your bobber, lit with a pulse when a fish bites, by hand or with the fishing loop.
- **Group extras** (ESP page, `modules/groupextras.lua`): for a healing class, a grey ring under anyone out of your heal range; in a fight a curtain round the tank, green holding, amber with someone within a fifth of pulling a mob, red with one on someone else (Forever: by who each mob is hitting); a blue ring under each other healer filling with their mana, red under a fifth. Stack and spread are not drawn: nothing JCore can read says them.
- **PvP extras** (Reactions page, `modules/pvpx.lua`): diminishing returns as small rings under each enemy player, a category each, filling over the 18 s after the control ends (amber half, red a quarter, grey immune; Classic Era's categories from DRList-1.0, each id checked against the Era client; `P.pvpx.dr(unit, spell)` for other modules); in a battleground a tall beacon on each flag carrier, red theirs, blue yours; while you are stealthed, a ring under each enemy player within 30 yd at the distance it would notice you, red once you are inside (9 yd, a setting, a yard per level, a third behind it; facing read off `get_direction` first, then `get_rotation`).
- **Route and services** (Quests page, `modules/routes.lua`): the stops of RestedXP's step after its gold beacon's (up to 2) as fainter, shorter pillars with a dashed line along the ground between them; a pillar on the nearest merchant when your bags are down to 4 free slots, or the nearest repairer when your worst piece of gear is at 25%, labelled "Sell" or "Repair" and how far; a tall pillar on your corpse while you are dead. No trainer: nothing readable says which spells your class could learn. Durability is read from the client directly (JCore's `worst_durability()` read a field no client sends, fixed in JCore 1.15.0).
- **The HUD's panels in the new look**: the Reactions overlay's body and the low-health banner are JCore 1.15's soft plates, the spell window's cast bar its rounded bar; the next spell not ready yet gets a sweep round it filling as the wait runs down (`ring_2d`). Flat as before with *Shader drawing* off or on an older JCore. The Market window and every JCore window already draw with the shader look (JCore 1.10).
- Internal: `worldlayer.lua` (`LANES`, `NPC_LANES`, `edge`, `lane_radius`, `daltonize`, `flush`, `stats`), `calibration.lua`, `combatrings.lua`, `tracks.lua`, `nodememory.lua`, `groupextras.lua`, `pvpx.lua`, `routes.lua`; `pull`, `timers`, `party`, `beacons`, `pvpmarks`, `plays`, `aurora` and `react/marks` draw through the layer with a priority, a module name and their unit and lane; `fishing.lua` `M.bobber()`, `M.has_bite`; `esp/forever.lua` and `esp/classify.lua` `M.town_npcs(range)` (read-only); `timeline.lua` the sweep and the bar; `react/init.lua` and `hardcore.lua` the plates. `main.lua`: the World marks page, the new sections, `P.worldmarks`, `P.calibration`, `P.combatrings`, `P.tracks`, `P.groupextras`, `P.pvpx`, `P.routes`, `P.nodememory`; jobs at 114 (node memory), 189 (calibration) and 190 (the layer's flush). Options `world_*`, `combatrings_on`, `cr_*`, `tracks_*`, `nodemem_*`, `groupx_*`, `pvpx_*`, `routes_*`.
- Tests: `aio_worldlayer_test` (new, 13: lanes for players and mobs, the budget, the look, the wall fade, the pulse's yards, a raising mark, the timers through the layer, calibration), `aio_combatrings_test` (new, 16), `aio_tracks_test` (new, 17), `aio_nodememory_test` (new, 14), `aio_nodememory_boot_test` and `aio_nodememory_boot_forever_test` (new: the whole plugin booted, a herb remembered end to end), `aio_groupextras_test` (new, 13), `aio_pvpx_test` (new, 14), `aio_routes_test` (new, 15), `aio_timeline_test` (1 new: the sweep).

## 1.88.1 (2026-10-09)
**Spells at their best rank, and the Forever hunter described by the Forever client.** The user: "Check API for Elites and Bosses for Forever its not working properly also check dumps for updates Ranks on spells for hunters and Talents".
- **The best rank, not the highest id.** The spellbook took a spell's highest id as its best rank, "a later rank always has the higher id". The clients' own tables disagree on 32 Era lines and 38 Forever lines. Some examples:
  - Battle Shout's rank 1 is 6673, above ranks 2 and 3 (5242, 6192), so a warrior of 12 to 31 shouted rank 1.
  - Seal of the Crusader's and Consecration's rank 1 (21082, 26573) are above every later rank, so a paladin pressed rank 1 at every level. Hammer of Wrath runs backwards.
  - Devotion Aura, Mark of the Wild, Inner Fire, Sap, Swipe and Holy Fire each have one rank out of place.
  - The hunter's Distracting Shot: rank 1 (20736) is above ranks 2 to 6.
  - Era's Create Healthstone family (by prefix): a warlock of 34 to 45 made Lesser ones.
  - On Forever also: Trueshot Aura's new ranks at 25 and 32 (1299346, 1299348) are above the 40 to 60 ones; Counterattack's 1242634; Slam, Seal of Fury, Ice Lance, Conflagrate, Cat Form and more.
  
  Now the level decides on those lines, from the client's tables: new `modules/rank_order.lua`, written by the new `tools/jcheck/ranks_extract.js`, per client (Era and Forever; every other client keeps the old order). Lines in id order resolve exactly as before.
- **The hunter's catalogue on Forever.** It was Era's (with TBC rows). It now describes Forever's own tree and spells, read from the Forever client's tables:
  - **Talents.**
    - 14 talents only Forever has: Deadly Aspects, Focused Fire, Summon Hawk, Lethal Attacks, Lone Wolf, Rapid Recuperation, Sniper Shot, Improved Tracking, Survival Tactics, Predator's Edge, Expose Prey, Survivalist's Discipline, Strider Kick, Lacerating Strikes.
    - Max ranks Forever changed: Improved Aspect of the Monkey 3, Improved Wing Clip 3, Improved Stings 3, Resourcefulness 2, Careful Aim 5.
    - Forever's tiers, and Forever's effects where they differ.
    - The 13 Era and 15 TBC talents Forever has not are served on Era only.
  - **Abilities.**
    - New: Sniper Shot, Lacerate and Trickster's Dance.
    - Aimed Shot is trained at 20 on Forever, a 2 s cast, not a talent.
    - Multi-Shot has one rank and a 6 s cooldown shared with Aimed Shot.
    - All four traps have a 30 s cooldown.
    - Viper Sting has a 15 s cooldown.
    - Changed figures: Arcane Shot, Raptor Strike, Mongoose Bite, Counterattack, Hunter's Mark, Aspect of the Beast (now the melee aspect, four ranks) and Trueshot Aura (from 25).
    - Summon Hawk and Strider Kick are no longer described on Era, which has neither.
  - **What it changes in play.** The priority walk and the reactions time abilities from the catalogue's `cast` and `cooldown`, so on Forever they now use the client's numbers. Era's rows are exactly what they were.
  - **To check in game.** Trueshot Aura's top rank reads 50 in the client's table, below rank 4's 75.
- **The dump, checked** (a level 19 Forever hunter, 2026-10-09). Nothing needed regenerating:
  - `talent_trees.lua` holds all 52 of its talent nodes.
  - `beasts_data.lua` has its pet's Bite 17253, Growl 14916 and Demoralizing Screech 24423 (Forever's name for Screech).
  - The spellbook's 40 learned names are the dump's.
- **Elites and bosses on Forever** (found here, fixed in JCore 1.15.0):
  - `get_classification` answers on Forever since the 2026-10-06 core. The recorder has 5,375 elite reads, and the creature cache agrees on all 451 creatures both know.
  - Forever never says 3 (boss). Its dungeon bosses are elites flagged as bosses. In the Deadmines, VanCleef, Sneed, Cookie, Mr. Smite, Greenskin, Gilnid, Rhahk'Zor and Thistlenettle are 1 with `is_boss` true.
  - So the ESP's BOSS mark, targeting's "leave the boss alone", the fight shape's BOSS, pull safety's red curtain and the boss-mechanic check never saw a boss there.
  - JCore 1.15.0's `units.classification` answers 3 for a unit the client flags as a boss; nothing in the AIO changes for it.
  - The hunter's *Hunter's Mark on: Elites and bosses / Bosses only* already read `is_boss` and the elite rank, and worked as it was.
- Internal:
  - `spellbook.lua`: `better(a, b)` (also `M.better`), used by `refresh` and `id_prefix`; `RANK_LEVEL` from `rank_order.lua` by the client's version word.
  - `catalog/init.lua`: rows carry `client = "forever" | "era"` and a `forever = { ... }` table, resolved at load (`P.forever`) and removed.
  - `catalog/hunter.lua` uses both.
- Tests: new `aio_spell_ranks_test` (6): Era's out-of-order lines, the prefix family, Forever's Trueshot Aura and Counterattack, the dump's level 19 book unchanged, other clients unchanged, the generated file.

## 1.88.0 (2026-10-08)
**Every ESP in the new look, and only the herbs and veins you can gather.** The user: "First Take the Ring around me and remove it I dont htink its necessary...Then Take all ESPs and convert it to this!", choosing (asked which ring, and which parts of the ESP): the Aurora's glow ring and your cast ring; ground rings, boxes to curtains, far things as beacons, cards and bars; and "Only Show Gatherables that I can Gather with my skills  If i Cannot then Write (Requires Skill # )". Both ESPs, Forever's and the Classic one.
- **The Aurora's rings are gone.** The glow ring under it and the ring at your feet filling with your cast. With the glow gone the *Style* choice went too (`aurora_style`, `aurora_cast_ring` are no longer read); the curtain, its sheet and its colours stay.
- **Ground rings:** the ring under anything on you or yours, the ring under a node and the ring on a quest area (Forever), and the ring at the end of a quest path (`quests.lua`), are JCore's smooth shader rings (`ring_3d`, a thin band, its colours and its "fainter when many" kept). On a JCore without `ring_3d`, the old outlines.
- **Boxes to curtains:** a fourth box style, *Curtain*, the default: a short curtain round the unit in its mark colour (2 yd, 16 points, a faint sheet, fewer points far off, dropped first on a heavy frame). Boxes still follow *Boxes* (off by default) and the full-detail range. On Forever a saved *Corner brackets* moves to *Curtain* once (the menu had saved the old default as everyone's value); pick corners again and it stays.
- **Far things as beacons:** a rare, a boss, a quest target (or a guide target, Classic) or a corpse with loot on it, further off than *Pillars of light from* / *Beacons from* (40 yd), gets a pillar of light in its mark colour (JCore's `beacon_3d`, 10 yd tall). Forever: *Beacons over far rares, bosses, quests and loot* (`esp_beacons`), at most six a frame, most relevant first; Classic: the element *Pillars of light on far rares, bosses, quest targets and loot* (`show_beacon`). Never on nodes (the Quests page's beacons do those), and not with only quest marks showing.
- **Cards and bars:** with *Soft cards and bars* / *Pills as soft cards, bars shading on a rounded rail* (`esp_shader_look`, on) a pill's backdrop is a soft-edged plate and every bar (health, mana, a cast under its pill, the game-texture bars too) a gradient on a rounded rail (JCore 1.15's `plate_2d` and `bar_2d`). Plates beside an icon have no shadow (it would reach the icon: textures paint under shapes). Until JCore 1.15 is in, and with the switch off, the flat pills and bars as before; *Game-texture bars* applies only then.
- **Herbs and veins by your skill** (*Only herbs and ore I can gather* on Forever's ESP page, *Only herbs and veins your skill can gather* under Automation's Gathering on Classic; `gather_skill_only`, on): a herb or vein of a profession you do not have is not marked (nor offered to the gatherer); one your skill is short of is marked dimmed, saying e.g. "Mithril Deposit (Requires Skill 175)", and the gatherer passes it by; one you can gather, as before. The skill is JCore's `player.skill` (read once a frame); a node's need is Classic's (`config.lua` `GATHER_SKILL`: Peacebloom 1 to Black Lotus 300, Copper Vein 1 to Rich Thorium Vein 275 and the obsidian chunks at 305); a name not in the list needs only the profession. Off, or on a JCore without `player.skill`, everything is shown. The Quests page's node beacons skip a node your skill is short of.
- Internal: `config.lua` `BOX_CURTAIN`, `BOX_DEFAULT`, `GATHER_SKILL`, `GATHER_PROFESSION`, `gather_requirement`, `gather_verdict`, the `show_beacon` element; `AURORA_STYLES` removed. `esp/forever.lua` `ground_ring`, the curtain box, the beacons, `gather_of`, `node_marks()` entries carry `name` and `requires`, the automation's nodes carry `requires`, `stats()` `beacons` and `gather_hidden`; `esp/card.lua` `begin_frame({ soft })`, plates and bars; `esp/page_forever.lua` the new switches and the one-time curtain move (`box_curtain_1:` in the migrations store); `esp/elements.lua` `DRAWERS.show_beacon`, the rings, the curtain box, plates and bars (its new helpers in one `LOOK` table: the file's main function is near Lua's 200 locals); `esp/collect.lua` the gathering verdict (`stats().gather_hidden`, nodes carry `requires`); `quests.lua` the path's end ring; `beacons.lua` skips `requires`; `world.lua` the gatherer skips `requires`; `aurora.lua` the rings removed.
- Tests: `aio_esp_forever_test`, `aio_esp_card_test`, `aio_esp_split_forever_test`, `aio_esp_marks_test`, `aio_quest_tags_test`, `aio_party_beacons_test`, `aio_threat_mark_test` and `aio_aurora_test` updated and extended (rings, the curtain box and its default, beacons near and far and by kind, soft cards on and off and on an older JCore, the gathering verdicts, the quest path's ring, beacons skipping a node your skill is short of, no Aurora rings).

## 1.87.1 (2026-10-08)
**Nothing selected: the pet comes back to you.** The user: "If no mobs selected all pets will come back to you as passive /calling the bird so its not randomly attacking by mistake".
- With no live hostile mob as your target (nothing, a dead one, a friend), the pet is sent at nothing. The rotation does not send it, nor does the 1.75.2 defence (a mob hitting the pet or you), nor a reaction: the add pickup, the pet moved onto a mob to Growl it, and any pet skill aimed at a mob (Growl, Bite, Spell Lock, Seduction) wait. The Reactions window says *nothing selected: the pet stays with you*. Its skills on itself or you (Dash, Furious Howl, Consume Shadows) still go.
- After a second with nothing selected, a pet still on a mob, or still running at one it was sent at, or fighting more than 10 yd from you, is called back (Follow). It is already Passive, so it stays. The second is there so the pet does not turn round between kills while the auto-target picks the next mob. A pet still on its mob three seconds later is called again. The log says *pet: called back (nothing selected: it was on Carrion Bird)*. The readout's Pet line says *home: nothing selected*.
- Select a mob and the pet goes at once, as before (in a fight, one in the fight; out of one, the pull's rules).
- In every pet mode and with the rotation off too, as the Passive stance is. Two exceptions: pet mode Focus with its unit alive keeps the pet on that unit, and an ESP-only client is left alone.
- Internal: `pet.lua` `M.home()`; `M.send` and `M.cast` (at a hostile unit) refuse while it holds; `M.recall` takes a fourth `quiet` (a repeated call logs as debug); `react/engine.lua` validates `pet_send` and enemy-aimed `pet_spell` against it.
- Tests: `aio_hunter_test`: the pet harness has a live mob selected by default; the 1.75.2 defence test runs with a mob selected that is not in the fight; 2 new tests (nothing selected; sent earlier, fighting away, rotation off, Focus, ESP-only). `aio_react_test`: 1 new test (the add pickup waits).

## 1.87.0 (2026-10-08)
**More in the world: pull safety, fight timers, your group, beacons, PvP marks, your reactions and the rotation's pick.** The user, on the curtains and rings: "Im sure this can eb used for alot more htings!! and it can be improved alot better", then picked every use and every improvement offered. Everything draws through JCore 1.13 (filled sheets, beacons, pulses, distance detail) and is skipped on an older JCore.
- **Pull safety** (Hardcore page, *Pull safety*; `modules/pull.lua`): under each hostile mob not yet fighting, a ring at the radius it notices you from: 20 yd at your level, a yard less for each level you are above it and a yard more for each it is above you, 5 to 45 yd (Classic's rule; the base is a setting, *Aggro range at your own level*, since Forever's may differ). The ring shows once you are within *Show a ring from this far outside it* (12 yd) of its edge, fills as you close in and turns from amber to red: full and red, you are inside it. Neutral mobs are never ringed (they do not come for you); the nearest 8 at most. An elite, rare or boss walking toward you gets a filled curtain, gold, silver or red; a rare gets a pulse the first time it is seen.
- **Fight timers** (ESP page, *Fight timers*; `modules/timers.lua`): every damage or healing over time spell of yours on your target as a ring round its feet, one inside the other (soonest innermost, at most four), each emptying as it runs out and keeping its colour; red with 3 s left; a pulse when one runs out on a target still standing. Auras are read off the target five times a second and kept when your guid cast them. A spell's full length is what was left the first time it was seen (the client's `duration` field is unproven), and a refresh fills its ring again.
- **Kill next:** the reactions' plan's focus, when it is not your target, as a red filled curtain, with a pulse when the plan changes its mind. The plan picks in a fight of two or more when you are not the tank or the healer.
- **Group and healing** (ESP page; `modules/party.lua`): a ring under each hurt party member filling red with their missing health (you are left out unless *Count yourself too*); a green curtain on the one lowest under *Heal at* (50%); a pulse under anyone who drops below a third, once until they are back over 60%; an orange curtain and a pulse on a mob in the fight on a member who is not the tank. With no tank known (Era players rarely set one; *Assist the tank*'s pick counts) only a mob on a healer counts as loose, and when you are the tank, a mob on anyone else. Nothing out of a group.
- **Beacons** (Quests page, *Beacons*; `modules/beacons.lua`): pillars of light, drawn while their tops show over a hill: RestedXP's next waypoint in gold; the nearest three quest areas from Forever's quest map, yellow to do and green to turn in (the map's areas come through the game Lua bridge, often down; then there are none); herbs green, veins orange and chests gold, the nearest five the ESP marks within 90 yd. Nothing within 8 yd.
- **PvP marks** (Reactions page, *PvP marks*; `modules/pvpmarks.lua`): the enemy player within 40 yd (a setting) lowest on health gets a red filled curtain, with a pulse when the pick changes; a pick holds until another is 5% lower, so two players trading the lowest spot do not flicker; the dead and the immune to everything are never picked. A green curtain on each enemy player seen healing in the last 20 s: casting a heal (Classic's heals by name, `detect.lua`'s "heal" kind as a second opinion, never Create Healthstone, Health Funnel or Mend Pet) or the caster of a Renew, Rejuvenation or Regrowth on one of them. Your crowd control on an enemy player (or your pet's, a Seduction) as a purple ring emptying, from `pvp.lua`'s CONTROL and SPELL_MECH (a snare is not crowd control). Their PvP trinket from `pvp.lua`'s state: a grey ring filling back up while it is down, a thin gold one when it is back (its cooldown is guessed: a wait over 120 s means a 300 s Insignia). Auras and the state are read five times a second for the nearest six players. Nothing is drawn without an enemy player within 40 yd.
- **Your reactions about to fire** (Reactions page, *In the world*; `modules/plays.lua`): a reaction of yours with a condition that must hold "for N s" gets a ring under the unit its first action is for, filling toward the moment it fires (amber to green); full green once it is offered to the engine, full grey when none of its actions can go; a pulse under that unit when it fires, in its alert's colour (white without one). The unit is worked out again from the action's target word (custom.lua keeps no record of the engine's pick), so for "caster" or "lowest" it can differ when several units qualify.
- **The rotation's pick:** when the rotation's global cooldown is pressed on a unit that is neither your target nor you (a heal on a party member, a dot spread to another mob), a small blue curtain round it for a second and a half and a pulse as it is pressed. Optionally (off) a thin ring under your target while the rotation runs.
- **The aurora's sheet:** a see-through glowing sheet between its lines, stronger in a fight (*A glowing sheet between its lines*, on).
- `esp/forever.lua` `node_marks()`: this frame's node marks for the beacons (the automation's `nodes()` holds only what is within its reach).
- Internal: `pull.lua` `aggro_radius`, `render`, `stats`; `timers.lua`, `party.lua`, `beacons.lua` `render`, `stats`; `main.lua` the four sections, `P.pull`, `P.timers`, `P.party`, `P.beacons`, one render job at priority 111 (pull, timers, party) and one at 113 (beacons, after the ESP's lists). `pvpmarks.lua`, `plays.lua` `render`, `stats`; the PvP marks run in the priority-111 job, your reactions and the rotation's pick in the reaction marks' job (125). Options `pull_*`, `timers_on`, `timers_warn`, `killnext_on`, `party_*`, `beacons_on`, `beacon_*`, `aurora_fill`, `pvpmarks_on`, `pvp_kill_target`, `pvp_kill_range`, `pvp_healers`, `pvp_cc_timers`, `pvp_trinkets`, `plays_on`, `plays_reactions`, `plays_rotation`, `plays_target_ring`.
- Tests: `aio_pull_test` (new, 5), `aio_timers_test` (new, 5), `aio_party_beacons_test` (new, 8), `aio_pvpmarks_test` (new, 10: it loads the real pvp.lua, detect.lua and latch.lua), `aio_plays_test` (new, 8), 1 new in `aio_aurora_test` (the sheet).

## 1.86.0 (2026-10-08)
**The aurora around you.** The user, on Lemons' Aurora Systems plugin: "if i dont enable lemons aurora how owuld it look??" and then "I'd like to go beyond that and improve it even More!". Its curtain, built into the AIO on JCore 1.11's `curtain_3d`, and made to read the fight (`modules/aurora.lua`).
- **Calm and fight:** out of combat it stands low (55% of its height) and drifts; in a fight it rises to full height and quickens. The change is eased over about half a second, and the wave keeps a clock of its own, advanced by its rate each frame, so speeding up never makes it jump.
- **Health:** under half it warms toward amber; under a quarter it burns red and breathes, its height pulsing faster the lower you are.
- **Enemies on you:** each one, up to three, adds a fold to the wave (counted from JCore's enemies four times a second).
- **Your cast:** a ring at your feet filling as your cast runs (a channel empties), inside the curtain. Its length is what was left when it was first seen.
- **The glow:** a soft shader ring (`ring_3d`, wide band) on the ground just outside the curtain.
- **Settings** (*Aurora around you*, on the ESP page for both ESPs): on/off (on), *Style* (curtain and glow / curtain / glow ring only), *Colours* (reacts to the fight: your class colour rising into violet / class colour / Aurora Systems' turquoise to purple / rainbow), your cast as a ring (on), only in a fight (off: with it on, the aurora fades out with the fight), size 1-5 yd (2), height 0.5-3 yd (1.2), speed (1x), detail 16-72 points (36). Under the master switch and the toggle key, not the ESP's own switch.
- Cost: 180 `line_3d` calls and two rings a frame at the defaults, settings read once a frame. Aurora Systems' defaults are 1,020 lines and about 9,400 menu reads a frame. Lemons' plugin is not needed; with both on there are two curtains. Needs JCore 1.11 (nothing is drawn on an older one).
- Docs (README): the ESP sections' tables list the cast ring, the countdown wall and the new section; *The aurora around you (1.86.0)* under *ESP*.
- Internal: `aurora.lua` `render`, `stats`; `config.lua` `AURORA_STYLES`, `AURORA_COLORS`; `main.lua` the section, `P.aurora`, its render job (priority 110). Options `aurora_on`, `aurora_style`, `aurora_colors`, `aurora_cast_ring`, `aurora_combat_only`, `aurora_radius`, `aurora_height`, `aurora_speed`, `aurora_detail`.
- Tests: `aio_aurora_test` (new, 8: calm, the colours and the glow; the fight rising, quickening and folding; health warming, red and breathing; your cast and a channel; styles, colours, size and the switch; only in a fight fading out; the wave's clock never jumping; an older JCore).

## 1.85.0 (2026-10-08)
**Rings and curtains in the world: cast rings, the reactions on the ground, a telegraph wall.** The user, after Lemons' Aurora Systems plugin and JCore's shader calls: "let's implement that!!! ontop of that what can it does for ESP and even Reactions???? how cna reactions benefit and improve from this!! PVP wise too". Everything below draws through JCore 1.11's `ring_3d` and `curtain_3d`, and is skipped on an older JCore.
- **The cast ring (both ESPs):** a ring on the ground just outside a caster's aggro ring, filling as its cast runs (a channel empties). It starts in the cast bar's colour (on Forever purple when you can kick it, amber when you cannot; on the Classic ESP white and red) and turns red as it closes. It covers enemy players too. Switch: *Ring on the ground filling as a cast runs* (`show_cast_ring`, on), on the Forever ESP's *In a fight* section and the Classic ESP's marks; with the ESP off (quest marks only) it is off like the cast bar.
- **Reactions in the world** (`modules/react/marks.lua`), one switch on the Rotation page, *Show it in the world* (`react_world`, on), under the overlay's toggle key:
  - **The kick lined up:** under a caster an interrupt (yours or the pet's, or PvP's *stop the cast*) is considering, a ring filling toward the moment the kick goes: a harmless cast is kicked in its last 2 s (the Interrupt rule's "kick it late"), so the ring is full exactly then. Amber turning green while it waits, full green once chosen, grey on the cast's own progress when the kick is refused (cooldown, range). One ring per caster.
  - **Who a reaction acted on:** a ring opening out and fading under the target of every reaction that fired (you for a defensive or a potion), coloured by its kind: green survival and defensives, blue escapes, purple interrupts and crowd control, amber the pet and threat, red an offensive one.
  - **PvP:** where an enemy player vanished or stealthed beside you, a red curtain on the spot sinking over the 3 s the reactions treat it as news, with a ring emptying under it; the stun, fear or sheep on you as a ring at your feet emptying purple to green as you come free; a red curtain round the enemy player bursting on you.
- **The telegraph countdown wall:** a circle still to land gets a thin ring round its edge filling as the cast runs, red toward impact, and a curtain standing on the edge rising to 1.4 yd at impact, in place of the old sweep circle. Not on a cone or a lingering patch, and never the first thing dropped on a heavy frame when you stand in it or a boss cast it. Switch: *A wall rising round its edge as it lands* (`tele_wall`, on), on both telegraph sections; off, the old sweep.
- Internal: `esp/forever.lua` `CAST_RING_GAP`, `draw_world(..., now_ms)`; `esp/elements.lua` `DRAWERS.show_cast_ring`, `view.ring_cast`, `GROUND_KEYS.show_cast_ring`; `config.lua` the `show_cast_ring` element; `react/marks.lua` `capture`, `render`, `stats`, `reset`; `react/init.lua` `R.marks`, captured after each decision and reset at combat end; `telegraphs.lua` `paint_wall`; `main.lua` the marks' render job (priority 125) and the two switches.
- Tests: `aio_react_marks_test` (new, 5: the waiting kick filling toward the kick point and moving between ticks; chosen, refused, one ring per caster; the acted-on ring opening and fading; the vanish spot, the control emptying, the burster; stale marks, the switch, an older JCore). `aio_telegraph_wall_test` (new, 4: the edge ring and the wall; none once landed, lingering or on a cone; the switch and an older JCore; never dropped when you stand in it). 1 new in `aio_react_test` (the waiting kick marked through the real tick, then the full ring and the pulse when it fires). 2 new in `aio_esp_forever_test` and 2 in `aio_esp_marks_test` (the ring's fraction, colours, size and layer; channels, the switch, nothing without a cast); `aio_esp_marks_test`'s "no read at all" takes the fifth switch.

## 1.84.0 (2026-10-08)
**The hunter: which mobs get the mark, and Serpent Sting on two or three.** The user, on Forever: "can we get a setting to only mark bosses? in dungeon also ... any chance we can have multi dot functionality when 2-3 mobs are up with serpent sting my hunter spends more time putting up mark than actually dpsing".
- **Hunter's Mark on** (hunter options and the hunter's class window): *Every target* (default, as before), *Elites and bosses*, *Bosses only*, *Never*. Every pull opened with a mark: a global cooldown and mana for a bonus a levelling mob dies under. A boss is the client's classification (3) or its boss flag (`is_boss`, which answers on Forever); the choice holds in dungeons and raids too. Era has no boss flag and reads its dungeon bosses as elites, so there *Elites and bosses* is the one for a dungeon (the option's tip says so). Auto Shot and the Aimed Shot opener still start a fight without the mark.
- The mark was never misread on Forever: the client's tables give the debuff the spell's own id (1130 and its ranks) there, as on Era, and that is the id the rule asks about. It was cast on everything.
- **Serpent Sting on more than one mob:** *My target only*, *Up to 2 mobs*, *Up to 3 mobs* (default). The sting rules in every hunter profile carry `spread`, the engine's DoT spread the warlock's Corruption uses: once your target has its sting, each other engaged mob is asked in turn, and a sting goes on the first worth one until that many carry yours. Each mob must live long enough for it on its own time to die, the bar must afford it (the spend tiers), and the wait for the pet applies to it as to the target.
- `rotation.lua`: `s.spreading` is set while a spread rule is asked about a mob other than the target, so a rule can cap its spread. Nothing else reads it yet.
- The class window's option dropdowns take a tooltip, as its toggles do.
- **Forever client 1.60.1.70291 (today's class patch).** The user pasted its notes. Read against the patched client's own tables, what the plugin depends on:
  - **Talents: a Fury or Protection warrior's new talents counted for Arms.** The patch added Gore Drinker (Fury) and a new Iron Will (Protection), nodes `talent_trees.lua` (built at 70205) did not know, and an unknown node counts for the spec's tab, which is Arms. `talents_extract.js` was run again: those two are filed under their own tabs, the old Iron Will's node is Lingering Rage, Boundless Rage's is Furious Precision, Predatory Instincts is Natural Instinct, and Improved Cleave, Precision and Toughness are gone. No rule reads any of those names.
  - `beasts_extract.js` was run again too: nothing the pet module reads changed (Furious Howl's attack power and the bat's Sonic Blast are not in the data it keeps); only the build line moved.
  - Checked and left as they are: Improved Slam still stops Slam touching the swing (its new tooltip; the cooldown is 18 s, less 1.5 or 3), so Slam still waits for it. Primal Bite is Mangle's new name and the bear's rule already used it; the cat's rule list is unchanged (no guide uses it there, and its tooltip awards no combo point). Flametongue Totem has no duration now; Fire Nova keeps counting it up for 2 minutes, since it stays where it was dropped. Tame Beast on a beast above your level: the tame card already read that as "tame at N". Primal Fury's rename to Blood Frenzy, the buff names on Windfury and Flametongue Totem, Rage of the Farseer's lost cast speed, Power Word: Shield over Power Word: Shield, Bloodthrill's higher chance: no rule reads or depends on them. Every name the nine class files use resolves on the patched client (`class_names_check.js`).
- Docs (README): *Which mobs get the mark, and the sting on more than one (1.84.0)* under *The hunter, levelling*; the class window's options; *Talents on Forever* notes the 70291 run.
- Internal: `hunter.lua` `MARK_ON`, `rank_of`, `worth_marking`, `STING_SPREAD`, `STING_CAP`, `stung`; the options `mark_on`, `sting_spread` (`rot_hunter_mark_on`, `rot_hunter_sting_spread`). `classwin_data.lua` the two dropdowns, `dropdown(..., tip)`; `classwin.lua` passes a dropdown's tip.
- Tests: 2 new in `aio_hunter_test` (the four mark choices in every profile, by classification and boss flag; the sting spread to two and three, capped, short-lived mobs left alone, every profile's rule spreads); its settings stub takes a dropdown. 1 new in `aio_classwin_test` (the two dropdowns, their tips, a pick written to the Rotation page); its recorder keeps tooltips. 1 new in `aio_class_review_test` (the warrior's 70291 nodes on their own tabs; it fails on the 70205 file).

## 1.83.0 (2026-10-07)
**The RestedXP guide panel moves and resizes.** The user: "make the rexted exp guide panel moveable, resizeable".
- **The guide panel is a JCore window** (`rxp_guide`). Drag it by its title bar, resize it from its bottom-right corner, double-click the title to fold it away; JCore's overlay UI remembers where it was left, how big, and whether it was folded. It starts where the panel always was, at the right of the screen. The step is the title now ("RestedXP  -  Step 12  (complete)"), and the goals, objectives and waypoint are the body.
- **Rows wrap to the width instead of being cut at a fixed length** (40 characters for a goal, 30 for an objective or the waypoint): a wider window shows more of each. A window made shorter than its rows scrolls.
- Where JCore's overlay UI is missing or switched off, the panel is painted as before, where the window was last left and at its width, with a count or a distance kept whole when a row is cut short.
- The Quests page's RestedXP section says how to move and resize it.
- Internal: `quests.lua` `guide_rows`, `draw_guide_fallback`, `GUIDE_WINDOW`.
- Tests: 4 new in `aio_quest_tags_test` (the window, resizable and movable, with its rows; the overlay UI off, drawn where the window was left; folded or hidden, nothing drawn; no overlay UI, the old spot).

## 1.82.0 (2026-10-07)
**The 2026-10-06 core: your quests on Forever from the game, and the fixes it made used.** The `.api` was updated for the loader's 2026-10-06 core (branch `lua_requests_06_10`); the user: "go ahead lets update it all". On an older core every reader does what it did in 1.81.0 (JCore 1.9.0 tells the cores apart by the functions the new one added).
- **No quest on Forever ever read "ready to hand in".** `questlog.lua` took completion from Questie's call, and both ways of reaching it were wrong there: the Questie addon's cache answers 0 for a quest that is ready (the `.api`), and JCore's quest database, which is asked first, answered `true` / `false` where the code waited for Questie's `1`. On the new core completion is the game's own `core.quests.is_quest_complete`; on an older one a quest also reads complete when every objective is finished, and `true` counts as `1`.
- **Your quests on Forever come from the game** on the new core: the set from `core.quests.get_quest_log_quest_ids` on every rebuild (no Questie sweep, no `is_on_quest` for what it lists), names and levels from the quest log's own rows (Forever's own quests, which no Questie database has, are named), and objectives from `get_quest_objectives`. A quest under a collapsed header stays while `is_on_quest` says you are on it, and is dropped after two reads that say you are not. The log line says which source ran.
- **The Forever quest ESP follows your progress without the game Lua bridge.** `esp/forever_quests.lua` builds its quest lines from the core's readers every 2 s while the bridge is not up (its probe has failed on Forever every session since 2026-10-03), so the KILL / LOOT / USE chips and the quest objects get the live counts. Quest areas, the game's unit names and tooltip matches still need the bridge.
- **Aspects switch off on Forever** on the new core: JCore 1.9.0 lets `cancel_buff` through there, so the aspect window's *off* cancels the aspect instead of saying to click it off the buff bar.
- **Who holds a mob is the threat status or the 100%, not `is_tanking`.** `targeting.lua`'s `loose`, `tanking` and `engaged_with_me` read `is_tanking`, which before the new core compared a hardcoded offset on Era, MoP, Titan and the private servers, while `status` was 0 on every classic build; only the percent was right everywhere. Status 2 or 3, or a scaled 100%, is right on both cores. On Era with an older core, a mob the wrong offset called yours is now seen as loose.
- Docs (README): *The 2026-10-06 core (1.82.0, JCore 1.9.0)* in the Forever section; the quests and the aspects window's Forever notes.
- Internal: `questlog.lua` `game_list`, `log_rows`, `game_objectives`, `game_complete`, `rested_objectives`, `questie_status`, `M.game_listed`, `stats().listed`; `verify` skips what the game listed. `quests.lua` names the source once. `esp/forever_quests.lua` `core_log_text` (`M._core_log_text`). `targeting.lua` `holds`.
- Tests: 3 new in `aio_forever_test` (the game's quests, names, objectives and completion; a collapsed header and an abandon; completion on an older core: `true`, Questie's `1`, every objective finished, failed), 1 in `aio_forever_quests_live_test` (the log from the core with no bridge), 1 in `aio_targeting_forever_test` (status and percent, not `is_tanking`).

## 1.81.0 (2026-10-06)
**PvP on Classic Era: what players do, how to answer it, and when to hold or use the trinket.** The user: "let's work PvP on classic Era (not forever)... Reactions for PvP for players will do and how to react to it what skills to use for that purpose or if to hold or use Trinkets". Every fact about a spell or an item below was read from the Era 1.15.9 client's own tables (SpellCategories, SpellEffect, ItemEffect; `tools/jcheck`).
- **The burst window spent the PvP trinket.** `burst.lua` pressed whatever trinket was worn inside a burst window, the Insignia of the Alliance / Horde included, so the stun that followed found it on its five-minute cooldown. A trinket that breaks control is kept for that now (`pvp.keeps`), and the log says so once.
- **A player's bubble was learned as an immunity for the session.** `learn.lua` learns immunities by name; a paladin immune to the same spell twice twelve seconds apart (Blessing of Protection, then Divine Shield) was "immune to Sinister Strike" until a reload. A player's immunity is held on that one player for 4 s and never learned.
- **No potion under a stun, a fear or a sheep.** The client refuses it, and each refusal backed the potion off for the moment the control ended. The mana item likewise.
- **The other player, read once a tick** (`modules/react/pvp.lua`, `W.pvp`): what controls you (your debuffs by name, else the loss of control: the mechanic, seconds left, whether damage breaks it, its dispel type, whether a player put it on you); per enemy player, from its auras, what it is immune to (everything: Divine Shield, Divine Protection, Ice Block; physical: Blessing of Protection; a mechanic: Berserker Rage, Recklessness, Death Wish, Will of the Forsaken, Fear Ward, Blessing of Freedom, Free Action, a druid's form), what it is bursting with, what a purge would take, and when it last used its own trinket (its Insignia's immunity buff: five minutes, two for Season of Discovery's); which worn trinket breaks what (Era's sixteen Insignias by item id: Warrior, Hunter, Shaman root/snare/stun; Rogue, Warlock charm/fear/polymorph; Mage fear/polymorph/snare; Priest, Paladin fear/polymorph/stun; Druid charm/fear/stun; Season of Discovery's Insignias and PvP Trinket; any other by its on-use spell's name); a player who vanished beside you.
- **PvP: break the control** (92). Every control a player puts on you is weighed (the control, its seconds left, hit through it, your health, players on you, damage would break it anyway, a dangerous cast coming at you, the flag, a silenced caster, a disarmed melee, a root that keeps you off your target or in a melee's reach, a target getting away), and the points are the reasons the readout shows. The cheapest thing that breaks it goes once they clear its line: Blink, Berserker Rage, a druid's form, Blessing of Freedom, the felhunter's Devour Magic (15); Will of the Forsaken, Escape Artist (15); a Living Action Potion (35); the trinket last, at the new **Use the PvP trinket** setting (Reactions page, PvP): *Only to stay alive* (60), *Balanced* (40, default), *Break any control* (1). The trinket is never pressed into what it cannot break (no Insignia breaks Blind, Sap, Gouge, a Freezing Trap, Wyvern Sting or Death Coil; a warrior's breaks no fear), which the journal says once; nor into a mob's control, even with a player in sight (on a PvP realm one usually is), unless you carry the flag.
- **PvP: stop the cast** (87). A player's heal, sheep, fear or big hit with your interrupt down or out of reach: Kidney Shot, Gouge, Blind; Concussion Blow, Intercept, Intimidating Shout; Psychic Scream; Death Coil, Howl of Terror; War Stomp. Aimed at you, it lands on nothing: Grounding Totem, Tremor Totem, Berserker Rage in a fear's last 0.8 s, Fear Ward, a druid's form against a Polymorph. Shares the core Interrupt's event, so one cast is answered once.
- **PvP: answer the burst** (82). A player on you with Recklessness, Death Wish, Adrenaline Rush, Blade Flurry, Cold Blood, Rapid Fire, Arcane Power, Combustion, Power Infusion, Presence of Mind or Elemental Mastery: each class's answers, best first (Disarm; Evasion, Blind; Frost Nova, Polymorph; Psychic Scream, Power Word: Shield; Death Coil, Howl of Terror; Hammer of Justice, Blessing of Protection; Bash, Nature's Grasp, Barkskin; Scatter Shot, Deterrence; Earthbind Totem, Grounding Totem...), passing over what the burster is immune to.
- **PvP: off the immune target** (70): Divine Shield or Ice Block (Blessing of Protection, for a warrior or a rogue) on your target: switched to an enemy something lands on. **PvP: find the stealthy** (64): a player vanished beside you: Flare on the spot, Arcane Explosion, Frost Nova, Holy Nova, Consecration, Thunder Clap; Perception for a Human when stealth is suspected about. **PvP: purge** (58): Purge, Dispel Magic, the felhunter's Devour Magic on a player's buff worth it (Blessing of Protection 30, Power Infusion 30, Arcane Power, Nature's Swiftness, Innervate 25, a shield 20...).
- **The rotation presses nothing into an immunity**: its usable check asks `pvp.blocks` (nothing into Divine Shield or Ice Block, nothing physical into Blessing of Protection by the spell's school, no fear into Berserker Rage, no sheep on a cat, no snare into Blessing of Freedom). The auto-target, the pet and the swing skip a player in Divine Shield or Ice Block, and a warrior's or a rogue's skip one in Blessing of Protection (`R.out_of_fight`, `pvp.immune_to_us`), so the auto-target does not switch straight back onto it.
- Player casts that matter count as dangerous: Mana Burn, Drain Mana, Aimed Shot, Soul Fire, a Hearthstone.
- The readout has a PvP line (players, the control on you, your trinket and what it breaks, your target's immunity, burst and trinket); 36 rows on Era, 37 on Forever.
- Your own reactions: conditions *I am controlled by*, *My PvP trinket is ready*, *Target is immune*, *Target has a burst cooldown up*, *Target's PvP trinket is on its cooldown* (`me.control_kind`, `me.pvp_trinket`, `target.immune`, `target.bursting`, `target.trinket_down`).
- Docs (README): *PvP on Classic Era (1.81.0)*, the scale, the function set, the reaction files.
- Internal: `modules/react/pvp.lua` (new): `CONTROL`, `HELPLESS`, `INSIGNIA`, `BREAKS`, `ENEMY`, `SPELL_MECH`, `PHYSICAL_ONLY`, `read`, `state`, `blocks`, `immune_all`, `immune_to_us`, `trinkets`, `trinket_for`, `keeps`, `reset`. `modules/react/rules/pvp.lua` (new). `engine.lua`: a candidate's `position` (ground casts) and the `set_target` kind. `init.lua`: `R.pvp`, `lib.pvp`, the read before the rules, `out_of_fight`, the readout line. `custom_data.lua` `CONTROLS`, the conditions and the built-ins' lines; `custom.lua` the fields and the "controls" choice.
- Tests: `aio_pvp_test` (new, 28).

## 1.80.0 (2026-10-05)
**The rotations against the Forever guides: what was broken, and what the guides agree on.** Every class's lists were set beside the published Forever guides (Icy Veins, wowtbc.gg, Mobalytics) and checked against the Forever client's own spell tables. The user: "Let's go ahead and do a massive Fix!".
- **Warlock: Agony was never cast on Forever.** Forever calls Curse of Agony "Bane of Agony" (the same spell ids), spells are found by name, and nothing mapped the old one, so the Agony rule in all five profiles was never a candidate there. They ask for the Forever name now, and so does the "only fear an un-dotted add" check. Era is unchanged.
- **Warlock: Curse of the Elements beside the Bane** (Forever only). A Bane is no curse on Forever, so the two share a target: every guide curses elites and bosses. Elements goes on an elite, a rare elite, a boss or anything with 30 s to live, before the DoTs, never over a curse of yours. Never on Era, where Agony is the curse.
- **Warlock: Wrack**, Forever's Affliction capstone, is the Affliction filler before Shadow Bolt once the DoTs are up (wowtbc.gg, Mobalytics).
- **Warlock: the defensive Drain Life drained you.** The escape and defensive paths cast anything not named as an enemy spell on yourself, and Drain Life was not named: the client refused it and the heal never came. It drains the enemy.
- **Warlock:** Forever has no Improved Drain Life. Its Improved Drains and Soul Siphon both make the drain heal harder, so they count for the emergency drain's line.
- **Priest: levelling Renew was recast every 3 s under 65% health while it ticked.** `hp < 0.65 or (bleeding and hp < 0.85) and not Renew` parses as `hp < 0.65 or (... and not Renew)`. Both halves wait for the last Renew now.
- **Healers: the big heal never fired while the fast one could.** Heals keep their list order, and each healer listed its fast heal (below 50%) above its big one (below 40%), so Greater Heal and Heal, Holy Light, Healing Wave and Chain Heal, and Swiftmend and Healing Touch went out only when the fast heal could not. The big heal comes first now: below the *Big heal* line and standing, the big heal; otherwise the fast one. A long cast while you are hit still loses to the fast heal, as before.
- **Shaman: Chain Heal** waits for two or more of the group under the fast line plus 20% (it fired for one).
- **Shaman: an Elemental kept no shield on Forever.** Its only shield was Water Shield, which Forever moved into the Restoration tree. Lightning Shield goes up whenever Water Shield cannot.
- **Shaman: weapon imbues.** Every Enhancement guide starts with one, and none was ever cast. Levelling and Enhancement put the best one trained (Windfury Weapon, else Flametongue, else Rockbiter) on the main hand out of combat when its temporary enchant has run out or has under two minutes left. A main hand that cannot be read casts nothing, and one pressed in the last 25 minutes that still reads as nearly gone waits 5 minutes for the next try (the enchant read was never measured on Forever; this keeps a read that cannot see it from an imbue every few seconds).
- **Shaman: Fire Nova.** On Forever it is a spell that explodes your fire totem; every guide uses it on packs. Levelling, Enhancement and Elemental press it on two or more close by while a fire totem is down (counted from when it was dropped: Searing 30 s, Magma 20 s, Flametongue 2 min).
- **Mage: Missile Barrage.** Every Arcane guide's rotation is "Arcane Blast until it procs, then Arcane Missiles", and no rule read the proc. Arcane Missiles on the proc (400589, Forever's talent and Season of Discovery's rune) is in every mage profile, ahead of the casts.
- **Mage: Pyroblast at three Heating Up stacks** (400625; Fire). Fire never cast Pyroblast, which Forever trains at 20.
- **Mage: Frostfire Bolt before Fireball** once trained (40 on Forever; Icy Veins and wowtbc.gg). The engine still weighs the two by damage.
- **Mage: Ice Lance on a freeze or Fingers of Frost while levelling** (Mobalytics' levelling order). It was in the Frost profile only.
- **Hunter: Summon Hawk.** Forever's Beast Mastery talent: a hawk keeps at the target for 18 s, two at once, on a 6 s cooldown shared with Arcane Shot. Levelling and Beast Mastery keep two out on anything that lives 6 s or more, and Arcane Shot holds off while one more hawk is wanted (every guide: Arcane Shot only while both hawks are up). Hawks are counted from our own presses.
- **Hunter: traps in combat on Forever.** The catalogue held every trap for the end of the fight, as Era needs; Forever lays them in combat (Icy Veins' class overview, Mobalytics' levelling guide). Survival's Explosive Trap on three or more could not fire before; it can now. Era is unchanged.
- **Hunter: Survival in melee.** Mongoose Bite (Expose Prey enables it without a dodge on Forever) and Strider Kick, Forever's Survival talent, come before Raptor Strike once a mob is on you. Catalogue rows for Summon Hawk (no minimum range) and Strider Kick, so the range is the catalogue's on a client with no range data.
- **Warrior: Victory Rush** in every list (Forever trains it at 20; Season of Discovery's rune): free, a tenth of your health, usable only after a kill, which the client's own answer says.
- **Warrior: Rend first for Arms with Bloodthrill** (Forever's Arms talent: swings at a target with your Rend may open Overpower). Without the talent Rend keeps its old place.
- **Warrior: a stance change looked 25 rage cheaper than it was.** The rage kept through a stance change was taken as 25 + 5 a point of Tactical Mastery. Era keeps 5 a point and none without it; Forever keeps 10 from its trained Tactical Mastery plus 5 a point of the talent, Improved Tactical Mastery (Era's old spell 12295). Only stance dancing reads it (off by default).
- **Warrior: Battle Shout refreshed before it runs out.** The class window owns it ("Keep up") and put it back only once it was gone, though its tooltip said "Refreshed before it runs out, in combat too", and the rotation's own early refresh never ran because the window owns the spell. A keep can carry a refresh time now; Battle Shout's is its last 10 s.
- **Druid: Berserk's burst window read the class's mana.** The burst checks asked `s.profile_power`, which nothing set, so a druid's bar was taken as MANA: no window under 35% energy or rage, and an open one closed under 10%. The snapshot carries the profile's own resource now (every class).
- **Druid: a bear tank from 29 to 39 never went into Bear Form.** The profile and the form manager only ever tried Dire Bear Form, trained at 40. Bear Form goes up until Dire Bear Form is trained.
- **Druid: Shifting Power** (Forever, Feral) below 60 energy, so none of its 40 is lost to the cap (Icy Veins, wowtbc.gg). **Wild Growth** (Forever, Restoration) when three of the group are hurt.
- **Rogue and cat: combo points kept through a target change** (JCore 1.8.12). Forever's guides say they no longer drop when you change target, and the counter zeroed them, so a finisher waited on points the player had.
- Docs (README): the warrior's profile choice (Protection the largest tree, the group's tank role) and its priorities (Victory Rush, Bloodthrill's Rend, Death Wish and Recklessness in the burst window, no rage-pooling switch); the rogue opener (no Garrote); the priest's wand line; Voidwalker Sacrifice is done; in-combat shard destruction; the pet's 4 s wait; the warlock's levelling profile name; `forever_power.lua` is JCore's `services/power.lua`. A new section, *The rotations against the Forever guides (1.80.0)*, with what was fixed, what was added, and what was left.
- Left alone: rogue **poisons** (the loader can use an item on you, a unit or the ground, not on an equipment slot); the Season of Discovery runes in the lists (Era runs them; on Forever an unlearned spell is never a candidate); mana reading 0 of 0 on Forever; Survival walking into melee, Call of the Elements, the Seal of the Crusader opener, Sniper Shot, Decimation, Bane of Havoc and Eclipse (not built yet).
- Internal: `warlock.lua` `AGONY`, `CURSES`, `worth_cursing`, `wrack_wanted`; `build` puts the curse after the Nightfall bolt; `imp_drain_life` reads three talents. `priest.lua`, `paladin.lua`, `shaman.lua`, `druid.lua`: heal order. `shaman.lua` `imbue_left` (main hand, slot 16, `item_enchant_expiration`), `best_imbue`, `imbue_rule`, `FIRE_TOTEMS`, `fire_nova_wanted`, `party_hurt`. `mage.lua` `MISSILE_BARRAGE`, `HEATING_UP`, `barrage_rule`, `frozen`. `hunter.lua` `hawks_out`, `hawk_wanted`; `arcane_wanted` holds for the hawks. `catalog/hunter.lua` Summon Hawk, Strider Kick. `warrior.lua` `victory_rush_wanted`, `bloodthrill_rend`. `druid.lua` `shifting_power_wanted`, `party_hurt`. `rotation.lua`: `ENEMY_ESCAPES` has Drain Life; the snapshot's `profile_power`; `catalog_blocks` lets a trap through in combat on Forever. `forms.lua` `switch_cost` per client. `classwin.lua` `keep_one` honours a spell's `refresh`; `classwin_data.lua` Battle Shout `refresh = 10`.
- Tests: 11 new in `aio_class_review_test` (Agony's name per client in every profile; the Forever curse; Wrack; levelling Renew; the healers' order and Chain Heal; the Elemental's shield and Fire Nova; the imbues; Missile Barrage, Heating Up, Frostfire Bolt and the levelling Ice Lance; Victory Rush and Bloodthrill's Rend; Bear Form, Shifting Power and Wild Growth; Drain Life on the enemy). 1 new in `aio_rotation_test` (a druid's burst window reads its form's bar). `aio_class_review_test`'s Arcane Blast stack test asks for the second Missiles rule (the first is the proc). `tools/jtest/mock/forever_class.lua` gives the warlock Forever's "Bane of Agony", and `aio_forever_class_warlock_test` requires it to be cast.

## 1.79.0 (2026-10-05)
**Reactions: why each one waits, what each did, a bench to try them on, and much more to react to and do.** The user: "add all sorts of Things To the Reactions!! Improve it 100times!!!".
- **Why not?** Every reaction now says in one line what it is doing, or the first thing in its way, in the order the engine meets them. The line is on its card, in the editor (*Right now*, step 1) and in *Live*. Examples:
  - "Switched off." / "Reactions are switched off (the Reactions page)."
  - "Not here: it acts only in Dungeons; you are in Open world."
  - "Used 1 of its 1 this fight." / "Waits for a fight (only in combat)."
  - "Condition 1 does not hold: My health % below 30% (it reads 60%)." / "Condition 1 holds, but must hold 0.4s more: ..."
  - "Ready (Ice Block), but My: Panic: Feign Death came first (100 to 88)." / "Ready, but Feign Death: on its cooldown." / "Ready (X): waits for a moment the rotation has nothing to press."
  - "Just went out: Ice Block on you." / "Going out now: Ice Block."
- **History.** Each reaction keeps its latest 15 fires: what went out, on whom, your health, where, and what each condition read at the time. Step 1 shows them with the count this session and this fight. *Live* has every reaction's fires in one feed, newest first.
- **Try it** (the editor's step 6): a test bench. Pick a situation (in a fight and fine, low health with two on me, my target is casting, dungeon: the tank is dead, dungeon: the healer is dead, my pet is dying, a raid boss under 20%, a player in melee, out of combat), or take **the fight as it is now**. Then change anything: your health, mana, mobs on you and in melee, casters, elites, your target (health, distance, casting, on you, the tank or the healer, elite, boss, player, running, its name, its debuffs), your pet, your group, where you are, your buffs, the items you carry, a key held. It says whether the reaction would act there and what it would send. Each condition shows what it read, and each action whether it could go and why not. Nothing is cast: the picture is made up. Spells are checked against your real spellbook.
- **New conditions** (GUI rows, and Lua names for each):
  - *Seconds left on my buff*, *Stacks of my buff*, *Seconds left on MY debuff on the target*, *Stacks of a debuff on the target*: a name and a number (`buff_left("Ice Barrier") < 3`, `debuff_stacks("Sunder Armor") < 5`).
  - *Cooldown left on the spell* (`cooldown("Frost Nova") < 1`).
  - *Seconds in combat*.
  - *Target's name is* (boss-specific reactions).
  - *Target is running away*, *Target is attacking the tank*, *... the healer*, *... someone in my group*.
  - *Lowest group member's health %*, *Group members under 50% health*.
  - *Enemies within 8 yards of me*, *within 30 yards*, *Enemy players within 40 yards*.
  - *I carry the item*.
  - **This key is held**: a reaction you fire with a key of your choice, when its other conditions hold.
- **Hold for**: any condition can be made to count only once it has held for a while (0.5 to 10 s): "moving for 2 s", "under 40% for 1 s". The row says how long it has held so far. A break of more than half a second starts the count over.
- **New actions:**
  - **Alert on screen**: your text at the top of the screen in a colour you pick, with the raid warning sound (optional), for a few seconds. *Show it now* tries it.
  - **Switch my target** to an enemy attacking you, an enemy casting, the tank's target, the enemy hitting the healer, the one with the least health, or the nearest in the fight.
  - **Stop my cast**.
  - **Use an item by name**: a trinket you wear or anything in your bags with a use, picked from what you carry or typed in (*Off the global cooldown* for a trinket or a potion).
  - Alerts, target switches and Stop my cast are **instant**. They go at once and never end the list: "show the alert, switch target, then the first spell that can go". While the conditions keep holding they repeat no sooner than every 6 s for an alert, 1.5 s for a target switch, or the reaction's own wait. They go again at once after the conditions stopped holding.
  - In Lua: `alert(text, colour, sound)`, `set_target(who)`, `stop_cast()`, and `use("Any Item Name")`.
- **Limits and word:** *At most per fight* (0 = no limit), *Alert on screen when it goes* (its name and what it sent), *A sound when it goes*.
- **My reactions:** a search, a filter (all, on, off, acting here, from the packs, imported, written in Lua), *All on* / *All off* for what is listed, **Share** on each card (the reaction as text on the clipboard, for Discord), and **Paste** (a shared one opens in the editor to look over and save). Each card says why it waits, and counts its fires this fight.
- **Five new templates:** *Alert: the healer is down*, *Trinket when a boss fight is on* (once a fight), *Pick up the mob hitting the healer*, *Press a key: my panic button*, *Keep my buff up (refresh before it drops)*.
- **Shared files** (Import and share) carry all of it: timers, the number with a name, keys, alerts, target switches, items by name, the limit and the alert/sound when it goes.
- Fixed on the way: a reaction that went out on the very first tick of a fight lost that fire from its count for the fight.
- Internal: `custom.lua`: `why`, `history`, `bench` / `bench_world` / `situation_now`, `after_decide` (the fight's clock, per-fight counts, each reaction's `outcome`), `cond_text`, `aura_row` / `aura_left` / `aura_stacks`, `key_held`, `instant_spec` / `do_instant` (`rt.instants`), `record_fire`, `push_alert` / `render_alerts` (main.lua's new render job, priority 207), `over_limit`; GUI types `text_number` (`num`) and `key`; rows' `for_s`; reactions' `per_fight`, `notify_alert`, `notify_sound`; new targets `tank_target`, `healer_attacker`, `lowest`, `nearest`. `engine.lua`: action kind `named_item`. `init.lua`: calls `custom.after_decide` after every decision. `hardcore.lua`: the bag scan keeps every carried item by name (`carried`, `named`, `named_ready`, `use_named`). `custom_data.lua`: the new conditions, `ACTION_KIND_BY_KEY` (instant kinds), `SWITCH_TARGETS`, `ALERT_COLORS`, `BENCH_PRESETS`, templates, API reference. `share.lua`: the new fields in and out. `reactwin.lua`: step 6, the item picker, the key picker, the *Hold for* slider, the new action rows, the card's why line, the search/filter/share/paste tools, *Right now* and *Latest fires*, Live's feed.
- Tests: 8 new in `aio_react_test`: the new conditions; *Hold for*; instant actions (alongside a spell, and repeating only after their gap, from the GUI and from Lua); items by name; once a fight, with the alert, again next fight; why not; the bench; sharing the new fields. 1 new in `aio_boot_reactions_test`: every new row, every step, every bench situation and Live, through the real toolkit. `aio_reactwin_snapshot_test` records `v179_cards`, `v179_step1`, `v179_step2`, `v179_step3` and `v179_step6`.

## 1.78.2 (2026-10-05)
**Forever: what the `.api` and today's recordings showed.** The user: "look at the API and fix all Forevers issues that we have". Every `.api` note on Forever was checked against the calls JCore and this plugin make, and the six recorder sessions of 2026-10-05 (a hunter, JCore 1.8.6 to 1.8.10) against what the client answered. What was wrong:
- **The loot window asked for one slot too many.** On Forever its slots were taken from 0 to the count inclusive, in case the client counted from 1. It does not: the loot study read every item at 0 to count - 1 and nothing at the count, and `loot_item` raised "specified invalid slot" for that extra slot (14 of 54 calls). Now 0 to count - 1 (JCore 1.8.11), and the trace line says so (*took slots 0-1*).
- **Pet skills used Era's spell tables on Forever.** Furious Howl is a 30 s cooldown on Forever, not 10, so the pet's clock called it ready 20 s early. `beasts_data.lua` now holds both clients (Era 1.15.9 and Forever 1.60.1; Era's half is unchanged), and the pet and tame modules read the running client's. Forever's own 19 skills (Dismember, Savage Rend, Sonic Blast, Tendon Rip, Web, ...) are known there.
- **The Spirit Healer was marked QUEST.** The graveyard's Spirit Healer carries the quest giver bit (npc flags 16387: gossip, quest giver, spirit healer), and the Forever ESP marks a giver it has never talked to with a dim QUEST. The trace had it on the Spirit Healer for whole sessions. A spirit healer or a spirit guide is no quest giver now, for the mark and for the "nearest giver" a quest window with no target goes to.
- **Warlock**, the items 1.77.3 found and left (`class_names_check.js warlock` now finds all 30 names on both clients):
  - A Nightfall proc was never cast. Shadow Trance was read by name, which looks in your own spellbook and never finds it, and its rule was in no list. It is read by its id (17941) now, and the instant Shadow Bolt comes before the damage over time in both levelling lists, moving or not.
  - A soulstone already on you was used again. Soulstone Resurrection is read by its ids (20707, 20762-20765), so the stone in your bags stays there while one is on you.
  - Fel Intelligence (the Felhunter's from TBC on, on neither client) is gone from the group buffs.
- Looked at and left alone:
  - Growl: almost every press was followed by the pet's cast going out and then "Spell is not ready yet" (71 of 74). The success comes first, so the taunt's clock is right and nothing is pressed early. The red text looks like the loader's pet cast going out twice, which nothing here can change.
  - `use_object` answering "That is already being used" (3 of 3) is the gathering case 1.55.3 already counts.
  - What the `.api` says Forever lacks (cancel_buff, the classic quest log, the completed-quest list, the Skill window, pet happiness, the vendor and auction house reads): nothing here relies on it there. JCore's `world.client()` answers around each, as before.
  - The game-Lua bridge (`execute` never reads back) and the game archives (`.build.info` unreadable) stay off on Forever: the loader's limits, not ours.
- Internal: `pet.lua` and `tame.lua` take `beasts_data.forever` when `P.forever`, else `vanilla`. `forever_quests.lua` `is_giver_flags` refuses the spirit healer and spirit guide bits (0x4000, 0x8000). `warlock.lua` `SHADOW_TRANCE`, `SOULSTONE_RESURRECTION`; `build` puts the Nightfall rule first. Tools: `beasts_extract.js` writes both clients unless `--client` names one (one alone would drop the other's half).
- Tests: `aio_forever_loot_window_test` (its fake client raises for a slot past the window, as Forever does; slots 0 and 1 are taken, and only once each pass); 1 new in `aio_hunter_test` (each client's tables, and the clock that follows them); 1 new in `aio_esp_forever_test` (the Spirit Healer); 2 new in `aio_class_review_test` (the warlock).

## 1.78.1 (2026-10-05)
**The Reactions window is readable: bigger text, brighter text, and a text size of its own.** The user (a 3440 x 1440 screen): "let's improve the look even further! bearly readable!".
- **A text size for the window.** *A-* / *A+* in the sidebar, under *+ New reaction*, set it from 90% to 200%. It starts at **125%**. It is kept between sessions and moves only this window. JCore's *UI scale* still moves every window, and the two multiply.
- **Everything grows together.** The sidebar, the title bars, the cards, the category strips, the import rows, the row widths, the spacing and the buttons are all sized with the text. Nothing overlaps at any size, and nothing overlapped at a raised JCore *UI scale* either. Before, the painted parts kept their pixel sizes while the text in them grew.
- **The window grows and shrinks with the text size**, once per change, still within the screen. A window saved before this was laid out at 100%, so it grows to 125% the first time it opens (yours: 964 x 806 becomes about 1205 x 1008).
- **Brighter and bigger secondary text.** The descriptions, sub-lines, notes and hints used the theme's faintest greys at 10 to 11 px. They are now one step brighter, and nothing in the window uses the 10 px size any more.
- **A solid background**, so the game no longer shows through behind the text.
- Nothing about what the reactions do changed.
- Internal: `reactwin.lua` lays out in units (pixels at a scale of 1) and draws through `units(ui)`. That wrapper multiplies custom painters, row widths, spacers, indents, button and box sizes, region heights, `avail` and `metrics` by the window's scale. The window passes `scale` (the text size) and a solid `bg` to JCore. `DIM`, `FAINT` and `BG` are the window's colours. The text size is kept in the `reactions_window` store, with the size the window was last fitted to. `M.zoom()` / `M.set_zoom(v)` are there for the tests. Needs JCore 1.8.10 for the scale; on 1.8.9 it draws at 100%.
- Tests: new in `aio_boot_reactions_test` ("text size: ..."): the window drawn at its own scale, growing with it, and every view at 90%, 160% and 200%. `aio_reactwin_snapshot_test` (opt-in) records three views at 100% and 160% besides the default 125%.

## 1.78.0 (2026-10-05)
**Reactions for dungeons and the open world: the built-in ones set up for each place, and starter packs of your own.** The user: "let's build Default Reaction for Dungeon and World open", then, asked which: both.
- **Built-in reactions get two switches each: Open world and Dungeon.** They replace the single on/off switch. Everything else about where one acts (raids, battlegrounds, arenas, open world PvP, which dungeon) is still under *Where* on its row.
- **The view's top shows both places** with how many are on in each. The place you are in is marked *you are here*. A raid or a battleground says that each row's Where decides there. The sidebar and the Reactions page now count what acts where you stand ("29 of 30 act here"). Each category's strip counts both columns ("World 4/4  Dungeon 3/4").
- **How they come.** Most built-in reactions already tell a group from solo by themselves (crowd control and area fears wait for the key in a group, the pet picks up adds only solo, threat drops only in a group), so they stay on everywhere. Three come **off in dungeons and raids**, because each pulls mobs off the tank:
  - *Pet: taunt*: the pet's Growl or Torment. Off, the pet's autocast follows its mode, and Assist keeps Growl off in an instance. Switch it on to solo a dungeon.
  - *Pet: Thunderstomp*: threat on everything around the gorilla.
  - *Intimidation: give the pet its mob back*: a mob that leaves you is the tank's to take back.
  - Each row says why it is off there, and is marked *changed* once you set it otherwise.
- **Reset**: *Reset open world*, *Reset dungeons* (each puts that one column back for every reaction, the rest of Where kept), and *Reset everything*. Each asks first. An open Where has *Back to how it comes*.
- **Your settings carry over.** One you switched off (1.76.0) shows both columns off, and a column switches it on in that place alone. Only what differs from how a reaction comes is saved, so a reset just drops it.
- **Starter packs**, above your cards in *My reactions*: a **Dungeon pack** and an **Open world pack** for every class. Each reaction in them watches something the built-in ones do not: a death in the group, a healer gone, threat on one mob, an enraged mob, several mobs on you, a player in melee.
  - Every class: *Healer down: drink early* (dungeons and raids), *Outnumbered: drink early* (open world).
  - Hunter: *Wipe coming: Feign Death*, *Frenzy: Tranquilizing Shot*; *Panic: Feign Death onto the pet*, *Player in melee: Wing Clip* (open world PvP).
  - Warrior, rogue, mage, priest, paladin, shaman, warlock and druid have their own (Last Stand, Demoralizing Shout, Feint, Evasion, Vanish, Ice Barrier, Ice Block, Frost Nova, Fade, Psychic Scream, Divine Shield, Lay on Hands, Hammer of Justice, Grounding and Stoneclaw Totems, Death Coil, Howl of Terror, Regrowth, Frenzied Regeneration, Entangling Roots).
  - "The tank is dead" and "no healer is standing" also need someone in the group dead. A group with no roles set has no tank to read, and that must not count as losing one.
- **Adding them.** *Add* puts one in My reactions, switched on, with its Where set to its place. *Add the pack (n)* adds every one you can use now. One whose spell you have not learned shows *Needs a spell* and what it needs, and waits. An added one shows *Added: open*, is never added twice while you keep it, and its card and editor say which pack it came from. After that it is yours like any other. A name you already use gets a number.
- GUI rows only, so the packs work on a loader that cannot run Lua.
- Internal: `custom_data.lua` `DEFAULT_PLACES` (each with its `why`) and `PLACE_COLUMNS`. `custom.lua`: `SHIPPED` places in `engine.filter`, `placed`, `same_env`, `keep_places`, `set_default_place`, `reset_defaults`; `set_default_env(name, nil)` now means as it comes. `defaults()` rows gain `world`, `dungeon`, `here`, `mine`, `shipped_why`, `shipped_env`, and `env` is now where it acts. New `modules/react/packs.lua` (`list`, `draft`, `add`, `add_all`), loaded as `custom.packs`. A pack reaction keeps `source = { pack, item }`. `reactwin.lua`: the places strip, the resets, the two-switch rows, `draw_packs`.
- Tests: 5 new in `aio_react_test` (the shipped places and the engine's filter by place, the columns, the resets, the packs and what they need, *Wipe coming* in a dungeon and not in a group with no roles set). 1 new in `aio_boot_reactions_test` (the views through the real toolkit). `aio_reactwin_snapshot_test` records `tab1_places` and `tab2_packs`.

## 1.77.4 (2026-10-05)
**Paladin: Forever's new buttons, Twist of Light, Repentance, and a seal for Holy.** The user: "go ahead finish it", the open items from 1.77.1. Every fact below is from the installed clients' own tables (Forever 1.60.1, Era 1.15.9): `tools/jcheck/class_names_check.js paladin` now finds all 42 names the file uses.
- **Twist of Light** (Forever, Retribution, passive). Swapping Seal of Command, Righteousness, Fury or Justice for another seal leaves an *Echo* of the old one, and your next swing applies it as well. With Command and Righteousness both trained, the rotation swaps between them once a swing, so each swing carries both. It never swaps while an echo is still waiting (Echo of Command, Righteousness, Fury or Justice, by id and by name), never twice inside one swing, and only in melee, with the swing running and the mana not low.
- **The tank's Judgement** (Forever). Under Seal of Fury, Judgement is a taunt: a mob loose from you gets it. **Swift Judgement** (no global cooldown, 1 min) finishes Judgement's cooldown when a mob is loose and Judgement is not ready.
- **Holy:**
  - **A seal for its Judgement**: Seal of Wisdom, else Light, else Righteousness, under *Contribute damage when nobody is hurt*. The Holy list had no seal, so its Judgement waited for one that never came.
  - **Light's Vigil**: cast on the ally being healed when three of the party are under 80%. **Holy Shock** then goes on that ally for the party heal while two are hurt, as well as at the usual line.
  - **Voice of Truth** (no global cooldown, 3 min): 6 s of immunity to silence and interrupts, when a heal is due and something could stop it, either a mob casting at you or an enemy player within 8 yards.
- **Repentance** (Retribution: humanoids only, 1 min). An interrupt after Hammer of Justice, and the first thing thrown at an add, before the Hammer.
- **What a spell takes** (every class can use it): a class may name spells that work only on some creature types (`creature_types`). The paladin names Repentance (humanoids), Exorcism and Holy Wrath (demons and undead), and Turn Undead (undead). The walk and every reaction refuse such a spell on any other mob, and the interrupt and crowd-control reactions move on to the next spell in their list: a beast casting gets the Hammer, not a Repentance the client refuses. A type the client does not report lets it through, as before.
- **Blessings where Forever differs.** Forever has no Blessing of Sanctuary, so Protection takes Kings there. Retribution takes Kings where it is trained (on Forever everyone has it at level 20) and Might otherwise.
- **Righteous Defense** (TBC) is gone: neither client has it. Hand of Reckoning stays, as a Season of Discovery rune.
- Internal: paladin.lua `CREATURE_TYPES` / `works_on` (`creature_types` on the class), `aura_named`, `ECHOES` / `twist_from`, `loose_mob`, `party_hurt`, `interrupt_threat`, `healer_seal`; rotation.lua `usable_on` checks the active class's `creature_types` (and so does `press_blocked`), `H.swing_period`; react/rules/core.lua `takes()` in the Interrupt and Crowd control rules, and `CC_FALLBACK.PALADIN` is Repentance then Hammer of Justice.
- Tests: 4 new in `aio_paladin_test` (its harness now has talents, the swing, aura rows by name, the party and a loose mob); 1 new in `aio_rotation_test`; 1 new in `aio_react_test`.

## 1.77.3 (2026-10-05)
**Druid, mage, priest, rogue, shaman and warrior, checked against the game's own tables.** The user: "lets take a look at all the classes we havent touched for forever and match spell talents and SpellIds with the .api". The `.api` has no Classic ids to match: `talents_id.lua` is a Retail 11.0 dump, and `buff_db.lua` declares names only. So every spell, talent and aura name in the six files was checked against the spell and talent tables of the installed clients, Era 1.15.9 (Season of Discovery's runes included) and Forever 1.60.1. The `.api`'s talent calls explained the Forever bug below. What was wrong:
- **Talents on Forever (every class).** Forever keeps the three classic trees in one trait tree. The client answers that one tree and specialization 1, so every point counted for the first tab. Past 20 points a Feral druid played Balance, a Frost mage Arcane, a Combat rogue Assassination, a Fury warrior Arms, an Enhancement shaman Elemental. Each node now counts for the tab its column is in, read from the client's own tables. Forever also moved some talents between trees (Insect Swarm to Balance, Natural Shapeshifter to Restoration), and those count where Forever put them. The paladin uses this split too; its list of talent names is now only the fallback.
- **Auras that are not your spells were never seen.** An aura asked for by name is looked up in your own spellbook, so one you cannot cast never matched. They are now read by their ids:
  - Weakened Soul (6788): a priest pressed Power Word: Shield all 15 s it could not go, on you and on the group.
  - Fire Vulnerability (22959): Fire counted stacks of "Improved Scorch", the talent, which always read 0, so Fire mages cast **Scorch and nothing else**. Scorch now also needs Improved Scorch: without it there are no stacks to build.
  - Frostbite's freeze (12494): Ice Lance never saw it. Fingers of Frost (400669) now counts as frozen too.
  - The Arcane Blast stack (400573, not the cast's 400574): Arcane never switched to Missiles.
- **Druid.**
  - Faerie Fire (Feral) asked after the caster's Faerie Fire, so it went out every 6 s. Either one now counts.
  - Tiger's Fury on Season of Discovery and Forever is free and gives 60 energy. It was pressed whenever no buff was up, so the energy was lost at full; now it waits for 40 or less. On Era it is the 30-energy buff, as before.
  - The cat's Swipe and Season of Discovery's Mangle share a name with the bear's. Resolving by name kept the highest id, so a bear's Swipe pressed the cat's and a cat's Mangle the bear's, and the client refused both. The spellbook now files them as **Swipe (Cat)**, **Mangle (Cat)** and **Mangle (Bear)**. Cats use Swipe (Cat) on three or more enemies.
  - **Primal Bite** (Forever's bear strike, Season of Discovery's Mangle (Bear)) is in the bear list.
  - **Berserk** opens a burst window (15 s).
- **Mage.** Remove Curse (a druid spell) and Invisibility (no mage spell on either client) are gone from the lists.
- **Priest.** Forever's **Penance** heals at the flash line and does damage while levelling. **Prayer of Mending** goes on someone hurt in a fight. **Confounding Flash** is an escape.
- **Rogue.** **Venom**, Forever's Assassination finisher, is kept up in a fight like Slice and Dice. Cloak of Shadows is on neither client and is gone.
- **Shaman.**
  - Maelstrom Weapon at 5 stacks (408505) makes Lightning Bolt worth pressing in melee.
  - Elemental presses **Lava Burst** after Flame Shock.
  - **Rage of the Farseer** (Forever) opens a burst window (25 s).
  - Wind Shear, Cure Toxins, Totem of Wrath and Bloodlust are on neither client and are gone.
- **Warrior.**
  - Slam waited for Improved Slam rank 4, which Forever never reaches (2 ranks there): now 4 of Era's 5, or both of Forever's 2.
  - Devastate is a passive on both clients (it makes Sunder hit), and its rule is gone.
  - Arms presses Forever's **Spearing Strike** after Mortal Strike.
- **Spell IDs need nothing else.** Abilities are still found by name in your spellbook, at their highest rank. Only the auras above, and the cat and bear names, are by id.
- Found, not changed here: the warlock reads Shadow Trance (17941) and Soulstone Resurrection (20707, 20762-20765) by name, so Nightfall procs and a soulstone on you are never seen; the warlock's Fel Intelligence and the paladin's Righteous Defense are on neither client. Forever's other new buttons wait for a recording: Shifting Power, Wild Growth, Binding Heal, Chastise, Divine Grace, Dark Sacrifice and Contingency Plan.
- Internal: `talents.lua` `NODE_TAB`, `M.max_rank`, `stats().split`; new generated `modules/talent_trees.lua`; `spellbook.lua` `FORM_NAMES`; `rotation.lua` `aura_ids` (H.buff_up, H.buff_remaining, H.debuff_up, H.debuff_up_any, H.debuff_remaining and H.debuff_stacks take an id list); the six class files; `paladin.lua` `tree_points`; `react/adapt.lua` and `react/tactics.lua` know Swipe (Cat).
- Tools: new `tools/jcheck/talents_extract.js` (writes `talent_trees.lua`) and `tools/jcheck/class_names_check.js` (every name in a class file against both clients; exit 1 on a name neither has, or an aura that needs its id). New DB definitions in `tools/jcheck/dbd/`: Talent, TalentTab, TraitNode, TraitNodeEntry, TraitNodeXTraitNodeEntry, TraitDefinition, SkillLineXTraitTree, SkillRaceClassInfo. Fixed in `beasts_extract.js`: SpellCooldowns and SpellRange had wrong file ids (a minimap image, and a file Forever does not have), which only Forever would have hit.
- Tests: new `aio_class_review_test` (15).

## 1.77.2 (2026-10-05)
**Import someone's reactions from a GitHub link, and share yours.** The user: "a import option on the UI to import someones reaction...they can import from github link aslong as its got a folder called Reaction".
- **Import** is a new view in the Reactions window, listed under *My reactions* in the sidebar. *My reactions* also has an *Import from GitHub* button. Paste a link and press *Fetch* (or Enter). The link can be:
  - a public repository (`github.com/someone/their-reactions`): its folder called **Reaction** (or Reactions, any case) is read;
  - that folder itself (`.../tree/main/Reaction`);
  - one `.json` file (`.../blob/main/Reaction/panic.json`, or a raw link).
- **You see what is in it before anything is saved.** Each reaction is a row you click to pick (all are picked at first; *All* / *None*). A row shows:
  - its name, its class (or *Any class*), its importance, and a *Lua* mark when it has Lua code;
  - what it does in one line;
  - what to know before importing it: a spell not in your spellbook, a Library function you do not have (or one in the Library that comes with it), a name you already use, rows this version does not know (left out), and that another class's goes to that class's list.
  - A file that cannot be read is listed with why ("not JSON (...)").
- **Import** saves the picked ones. Yours go into *My reactions*. Another class's go into that class's list, and are there when you log in with one. A name you already have gets a number ("Panic button (2)"). They arrive **switched off**, to look over first, unless *Switch them on now* is on. *Add their Library to mine* appends the author's `library.lua` to your Library, once, under a line saying where it came from. The card and the editor say where each one came from.
- **Nothing in a file runs when it is imported.** It is read as JSON, never loaded as code. Every field is checked against what the editor can make: unknown conditions, actions, items and importances are left out or set back, numbers are held in range, and lengths are capped. Lua rows are kept and run in the reactions' sandbox, like your own.
- **Share yours.** *Export my <class> reactions* writes one `.json` per reaction into `scripts_data/jambix_aio/share/Reaction`, plus `library_<class>.lua` when you have written a Library. Put that Reaction folder in a public GitHub repository, and anyone can import it with the repository's link. *The file format* opens an example built from your first reaction.
- **The format** (`"format": "jambix-reaction"`, version 1) is the editor's fields: name, importance, priority, wait, combat_only, off_gcd, match, conds, actions and env, with an optional class, description and author. A file may hold several reactions (`"reactions": [ ... ]`). A subfolder named after a class (`Reaction/Mage/`) gives its files that class.
- **What it costs.** One call to GitHub's API per fetch (it allows 60 an hour without signing in), then the files from raw.githubusercontent.com; a link to one file costs no API call. Up to 40 files of 128 KB each are read. GitHub's answers are put into words: no such repository (or it is private), no folder called Reaction, the hourly limit, no connection.
- Internal: new `modules/react/share.lua` (`parse_link`, `find_folder`, `pick_files`, `decode`, `clean`, `fetch`, `import`, `encode`, `export_all`; the fetch state is `share.job`), loaded by `custom.lua` as `custom.share`. It uses JCore's `ctx.net` (queued, cached, one callback a frame) and `ctx.json`. `reactwin.lua`: view 6. A reaction keeps `source = { repo, file }`.
- Tests: new `aio_react_share_test` (9): links, the folder, a file checked, a fetch through canned GitHub answers, the import, the errors, export read back by import, and the window's Import view in every state. `aio_reactwin_snapshot_test` also records the Import view empty, found and imported.

## 1.77.1 (2026-10-05)
**Paladin, for Forever and the rest.** The user: "any other paladin fixes needed? Talents? Spell IDs?". What Forever changed for paladins, from its guides and patch notes, against the paladin file and everything that reads it.
- **Holy Strike** (Forever, learned at 6): an instant melee strike, weapon and Holy damage, on a 10 to 12 s cooldown. The rotation did not know it, so a Forever paladin's one attack button was never pressed. The levelling and Retribution lists now press it before Judgement, and Protection uses it as filler. Melee reach only (the client gives no range on Forever). Holy uses it too, under *Contribute damage when nobody is hurt* and only when you are already in melee, which is also when Holy now starts the swing.
- **Every seal counts.** The "is a seal up" check knew five names. Under Wisdom, Light or Justice kept by the class window, or Forever's **Seal of Fury**, Judgement never went out and Righteousness was put over the seal. Protection puts up Seal of Fury first where it is trained; the class window offers it.
- **Auras for every profile.** Only the levelling list kept one up, so Retribution and Protection on Auto fought with none. Retribution takes Sanctity, then Retribution, then Devotion Aura; Protection takes Devotion. An aura already up (Concentration, say) is left alone, which the levelling list did not do.
- **Exorcism only at demons and undead.** It was pressed at everything and refused with red text, every 2 s on Forever.
- **Talents on Forever.** All of a class's talents sit in one trait tree there, and every point was counted for the tab the client's specialization names: 1 on the recording, which for a paladin is Holy. Past 20 points a Retribution or Protection paladin would have been played as a healer. The paladin now counts its trees from talent names (the Classic trees, and Forever's new talents where the guides agree on the tree). Era still reads its three trees, as before.
- **Your blessing is the profile's.** The group buff list blessed you first, with Kings or Might, so a Protection paladin never got Sanctuary and a Holy one never got Wisdom. It now blesses your party only. Any blessing counts as having one, Greater, Salvation and Light included: the profile no longer casts over a Greater Blessing of Kings (and its Symbol), and the group list no longer replaces your Salvation on a party member.
- **"Buff party members too" means party members** (every class). Every friendly player in range was a candidate, so buffs went on strangers in town.
- **Forbearance.** Nothing knew it. After a Divine Shield, the defensive reaction could press Divine Protection every 6 s and never get to Lay on Hands, and the escape count kept the locked bubble as a way out. A class can now name spells that cannot go while an aura is on you (`locked_by`); the paladin names Divine Shield, Divine Protection, Blessing of Protection and Templar's Bulwark. They read as not ready while Forbearance is up, by its id or its name.
- **Templar's Bulwark** (Forever, Protection), an absorb as large as your health, is the first defensive where it is trained.
- **The group's tank under 20 talent points plays the Protection list** (Righteous Fury, Seal of Fury). Before, any paladin under 20 points played the levelling list.
- **Spell IDs need nothing.** Every paladin spell is found by name in your own spellbook, at its highest rank, so Forever's new IDs and ranks resolve by themselves. If a name is spelled differently on a client, the Rotation page lists it as unresolved.
- Not done, for want of a recording: Forever's other new talents with buttons (Light's Vigil, Voice of Truth, Swift Judgement), Twist of Light seal swapping, and Repentance. On Forever, Judgement reportedly keeps the seal, so nothing changes in how it is pressed.
- Internal: paladin.lua `SEALS`, `AURAS`, `BLESSINGS`, `TREE_OF` / `tree_points`, `exorcism_target`, `HOLY_STRIKE`, `buff_others_only`, `locked_by`; spellbook.lua `locked` (in `ready` and `castable`); rotation.lua `group_buffs` (party by guid from `group.objects()`, `buff_others_only`) exported as `M.group_buffs` for the tests; classwin_data.lua Seal of Fury and the aura tip.
- Tests: new `aio_paladin_test` (9); 1 new in `aio_rotation_test`; `aio_forever_class_paladin_swing_test` now has Holy Strike in its level 9 spellbook and asks for it on cooldown.

## 1.77.0 (2026-10-05)
**The Reactions window, laid out anew: you can move it, size it and scroll it.** The user: "the Reaction UI its too cluttered into one screen it should be moveable and scrollable! basicaly rework it".
- **Move and size it.** Drag the title bar to move it, the bottom-right corner to resize it. It opens at 980 x 700 (less on a smaller screen), is never bigger than the screen, and keeps its place and size between sessions. The old window kept a fixed 660 px width and grew as tall as the screen.
- **A sidebar that stays put** takes over from the big header and the tab strip. It holds your class, the master switch (click it: *ON in the rotation* or *OFF*), where you are, whether the fight picture is live, and the five views with a line each: *Built-in* (how many are on), *My reactions* (how many, how many on), *Editor* (the reaction open, and "(unsaved)"), *Library* (its functions, or "has an error") and *Live*. Under them: *+ New reaction*.
- **Each view scrolls by itself.** The view's title bar and its tools stay at the top: the search, the template picker, the editor's steps, the Library's Save. Only the body under them scrolls. Use the wheel, drag the bar, or press on the track to jump there. Each view keeps its own place in the scroll. A code box under the cursor takes the wheel first, so scrolling over code scrolls the code, not the page.
- **Built-in reactions fold away by category.** Click a category's strip to close it; *Collapse all* / *Expand all* do every category at once. Each strip says how many of its reactions are on ("3 of 4 on"). A search opens every category it finds something in.
- **The editor in five steps**, as tabs: *1 Basics* (name, importance, priority, wait, combat, global cooldown, and the whole reaction at a glance), *2 When (n)*, *3 Do this (n)*, *4 Where* and *5 As code* (the code fills the pane). **Save, Save and close, Revert and Close are always in view** under the body, with the state next to them: *Saved*, *Unsaved changes*, or what to look at ("! 2 to look at: ...", every item in the tooltip). The title bar shows the reaction's name in its importance's colour, what it does in one line, and whether its conditions hold now. A newly opened reaction starts at the top of each step.
- *As Lua* on a card now opens the editor on its code (step 5). It used to open the editor at the top.
- *Library*: the code box takes most of the pane. *What your code can read and call* is a strip that opens the reference (closed at first).
- *Live*: where you are, the fight mode, the danger, and the mobs in the fight and on you as four tiles across the top; then your reactions, what went out, and the journal, as before.
- Nothing about what the reactions do changed: same switches, same store, same engine rules.
- Internal: `modules/reactwin.lua`: the window is `reactions` (it was `reactions_window`, so the old fixed-size geometry is not carried over). It is `resizable`, with `scroll = false`; the sidebar and the view are JCore scroll regions in one row, and the view's body is a region inside the view. `put` sets a widget under the path of the region it is in. Needs JCore 1.8.9 (`ui:avail`); on an older JCore the window stays shut.
- Tests: `aio_boot_reactions_test` unchanged and passing; `aio_reactwin_snapshot_test` (opt-in) now records a 1920x1080 screen: the five views, the editor's five steps, the list folded, and the list scrolled by the wheel and by dragging its bar.

## 1.76.1 (2026-10-05)
**Paladin: the rotation starts the melee swing.** The user (Forever, a level 9 paladin): "it uses blessing using also Seal when out of combat however it does not hitting the mobs".
- The cause: nothing a paladin presses before Crusader Strike starts the swing, the way a warrior's or a rogue's strikes do, and the rotation never pressed Attack itself. So a level 9 paladin put up its blessing and seal and judged every ten seconds, and never hit the mob. At that level the swing is nearly all of the damage. The rotation has no level gate.
- Now the levelling, Retribution and Protection profiles start the swing on the target when it is off and the mob is in melee reach. It is sent as the client's START, which does nothing to a swing already running, so it never switches one off. It is off the global cooldown, so a Judgement is never delayed for it.
- Nothing pulls by itself still holds (1.75.0): a mob nobody has engaged is not swung at until you attack it, it comes for you, or the engage key is held. A mob held by crowd control that damage breaks is left alone.
- The rotation does not walk you to the mob: out of reach, nothing is pressed.
- Internal: `H.melee_start_wanted(s)` in `rotation.lua`; the paladin's `Attack` rule (`direct`, `fast`, upkeep 1).
- Tests: 1 new in `aio_rotation_test`; new `aio_forever_class_paladin_swing_test` (a level 9 paladin on Forever with the swing off at the pull, failing without the fix with *Blessing of Might, Seal of Righteousness, Judgement x3* and no swing); `mock/forever_class.lua` gains `sim.swing_off()` (only a running swing hits) and a level 9 paladin spellbook.

## 1.76.0 (2026-10-05)
**Reactions get a tab of their own, and you can make your own, in the GUI or in Lua.** The user: "Reactions own Tab ... Default Reactions and then Create new Reaction for Class, Also Enviroment ... Open World PvP, BG PVP, Arena PVP, Dungeons (All dungeons ... individually), Raid", then "capability to write it in Code (lua) or by the functions ... the functions and code talk to each other".
- **The Reactions page** (new, under Rotation): *Use reactions in the rotation* (on, as before) and the **Open Reactions UI** button. Off: no reaction acts, except the Hardcore page's bail-out and hearthstone, which keep their own switches there. Four live lines: on or off, how many built-in (and how many switched off), how many of yours, where you are, the last one sent. On an ESP-only client the page says it does nothing there.
- **The Reactions window** (`modules/reactwin.lua`), five tabs:
  - *Default reactions*: every built-in reaction your class can have, by category, each with its own switch, a line on what it does, how often it went out, and *Where* (below). Kept per class.
  - *My reactions*: your class's own as cards (icon, what it watches and does, where, sent count, a live light), with On, Edit, As Lua, Up/Down, Copy and Delete. *Create new reaction* starts blank or from a template (panic button, interrupt, finisher, two on me, mana potion, save the pet, written in Lua).
  - *Editor*: name and importance (life or death 100 down to "only when the rotation is idle" 20, and a priority slider), wait between uses, only in combat, off the global cooldown. **When**: conditions, all or any. **Do this**: actions in order, the first that can go is sent. **Where**. **As code**: the whole reaction as Lua.
  - *Library (Lua)*: your class's shared code. A function made there can be called from any Lua row and picked in the GUI ("My Lua function" under When, "Run my Lua function" under Do this).
  - *Live*: where you are, the fight's mode and danger, what each of your reactions says now, what went out last, the engine's journal.
- **Conditions** (64 in the GUI): you (health, falling, dies within, mana/rage/energy, combo points, combat, moving, casting, controlled, a buff, mobs on you or in melee, healthstone/potion ready), spells (ready, known: picked from your spellbook with a search), the target (health, distance, dies within, casting, which spell, interruptible, cast ends within, on you or the pet, elite, boss, rare, player, level, creature type, has a (your) debuff, crowd-controlled, threat, runs, someone else's), the pet, the group (tank and healer alive, healer controlled, dead), the fight (mode, situation, danger, mobs, casters, elites, boss, PvP), where you are, and your Library's functions.
- **Actions**: cast a spell (on your target, yourself, the pet, an enemy that is casting, an enemy on you, the tank or the healer), use an item (healthstone, healing or mana potion, mana gem, bandage), a pet ability, send the pet, run a Library function, or hold the rotation.
- **Where**: open world, open world PvP, battlegrounds, arenas, dungeons, raids, each on or off, and which one: every Classic dungeon (19), raid (7) and battleground (3) by name. Matched by the instance's name (aliases such as Deadmines / The Deadmines), and by its id where the name is missing. Scarlet Monastery, Dire Maul and Blackrock Spire share one instance per wing set, so each is one entry. An instance not in the list (Forever's own) is learned the first time you enter it and offered from then on.
- **GUI and Lua are one function set.** Every GUI condition stands for a Lua expression (`me.hp < 40`, `target.casting`, `buff("Ice Barrier")`), shown under the row; *To Lua* turns the row into it. Lua reads `me`, `target`, `pet`, `group`, `fight`, `where`, and calls `check(key, op, value)` (any GUI row by its key), `ready`, `known`, `cooldown`, `buff`, `debuff`, `situation`, `place`, and in actions `cast`, `use`, `pet_cast`, `pet_attack`, `hold` (the first that can go wins). A condition may be an expression or statements that return; an action may be statements or an expression naming a spell.
- **The Lua runs sandboxed**: its own globals (no `core`, no files), a watchdog that stops an endless loop after 200k instructions, and an error stays that row's: shown with its line, red, in the editor. If the loader cannot run Lua at all, the window says so and Lua rows never pass.
- **Edit in a file** (VS Code, Notepad++): a saved reaction's Lua row, or the Library, is written to `scripts_data/jambix_aio/reactions/<CLASS>/` and read back every 2 s; save it in your editor and it loads, with a line in the log. The loader cannot open a program itself.
- **Live lights**: each condition shows what it read and whether it holds, from the engine's latest picture (the rotation must be running); each card shows whether its conditions hold now.
- Your reactions are engine rules (`My: <name>`): scored, validated and cast like the built-in ones. Saved per class in the `reactions` store.
- Internal: new `modules/react/custom.lua` (store, where, the function set, the sandbox, compiling reactions into rules, the file links) and `custom_data.lua` (conditions, actions, targets, importance, instances, templates, the built-in reactions' lines); `react/engine.lua` `E.filter` (asked for every rule and in `owns`) and `fired_n` / `fired_at` / `fired_name` on each rule; `react/init.lua` loads `custom` and syncs it each tick; `main.lua` the Reactions page (`react_active`, `react_open_ui`), `P.pages.reactions`, `P.reactwin` and its render job. Needs JCore 1.8.7 (`ui:code`); on an older JCore the window stays shut.
- Tests: 6 new in `aio_react_test`; new `aio_boot_reactions_test` (4: the page, the button, every tab through JCore's real toolkit, a saved reaction firing and the switch stopping it); `aio_boot_checks` walks the Reactions page on ESP-only clients; new opt-in `aio_reactwin_snapshot_test` (`JTEST_SNAPSHOT=1`) writes each tab's draw calls to `tools/jtest/out/reactwin/` for a look at the layout.

## 1.75.2 (2026-10-05)
**The pet is always Passive.** The user: "should always be on Passive".
- Aggressive and Defensive are both switched to Passive (1.75.1 kept it Defensive). This happens in every pet mode, Off included, and also with the rotation paused or switched off. Only an ESP-only client (TBC and later) is left alone.
- On Passive the pet attacks only what it is sent at: by the rotation (your target, the add, the taunt), by you, or by the one thing Defensive did by itself. That one thing: in a fight, a pet with nothing to do is sent at a mob hitting it, else at the nearest one hitting you. It never goes for a mob held by crowd control that damage breaks. Out of a fight nothing is sent: the pull is yours (1.75.0).
- Where the bar says nothing about the stance (Forever), Passive is set once per pet and again after every fight. The log says *pet: set to Passive (it was Aggressive)* (once per pet on Forever).
- Tests: `aio_hunter_test`: the 1.75.1 stance test is now the Passive one, plus 1 new for the defence.

## 1.75.1 (2026-10-04)
**The pet does not start fights by itself.** The user: "make sure pets arent attacking shit on its own".
- **Its stance.** The plugin never set it, so a pet left on Aggressive (a freshly tamed one, or one switched by hand) attacked whatever came near. While the plugin manages the pet (rotation on, pet mode not Off) it is kept Defensive: it fights what attacks you or it, and what the rotation sends it at. The stance is read off the pet's bar; Aggressive is switched, Passive is left as you chose it. Where the bar says nothing (Forever) it is set once per pet. The log says *pet: set to Defensive (it was Aggressive)*.
- **A mob clicked mid-fight.** In a fight the pet used to be sent at whatever you selected, so a mob clicked in passing was pulled. Now, in a fight, the pet follows your target only when it is in the fight already (on you, the pet or your group, or one you have hit), or with the engage key held. Out of combat the 1.75.0 rule decides, as before.
- Tests: 2 new in `aio_hunter_test` (its pet harness reads stance buttons and has a target and enemy rows).

## 1.75.0 (2026-10-04)
**Nothing pulls by itself: the fight starts when you attack.** The user: "i shouldnt be just auto initiating fights either. Should be when I go into Attack mode basically".
- The cause: a hunter's own opener was asked with *Start fights on the selected target* off. With automatic targeting that meant any mob selected within 8 to 35 yd got a Hunter's Mark, the pet and Auto Shot.
- Now, with *Start fights* off (the default), out of combat nothing offensive goes at a mob and the pet is not sent until one of these:
  - you attack it: Attack, a right-click, your own Auto Shot or spell;
  - it comes for you or your pet;
  - the engage key is held (or toggled on).
  The rotation then takes over at once. *Assist the tank* still joins a fight the tank has started; an idle mob still waits for the tank's pull.
- *Start fights* on: a hunter opens only where its opener agrees (in shot range, not a player, not somebody else's fight, only where pulls are yours). Before, the switch opened on any selected mob. Other classes: unchanged.
- The watch line says it: *holding fire: target not engaged (waiting for you to attack it, or the engage key)*. The hunter's window says the pull is yours.
- Automatic targeting still selects out of a fight. Selecting is not attacking.
- Internal: `rotation.may_engage_unit` asks the class's `may_open` only under `rot_open_combat`, and falls through to the other readings when it says no.
- Tests: 1 new in `aio_react_test`; its loot-first test now has the class opener under the switch.

## 1.74.0 (2026-10-04)
**A hunter in a five-man: one mob at a time, no Mark at the dead, no sting on what never takes it.** From a log of a Forever dungeon run with *Assist the tank* on.
- **Assist the tank keeps the kill.** In a fight, your target stays until it dies. A warrior tabbing through the pack for a Sunder on each is no longer followed. Before, the hunter changed target every 1 to 3 s, with a Hunter's Mark, an Auto Shot re-arm and a fresh sting each time, and nothing died sooner.
  - You do go to the tank's target once the tank has kept it 4 s (a real switch), when yours dies, or when the tank's carries a skull or cross and yours does not.
  - A mob of yours under 35% is finished first either way. Out of a fight (the tank picking the pull) nothing changed: 0.3 s.
  - The class window says so (*staying on X until it dies (the tank is on Y, 1.5s)*, *finishing X (30%) before Y*). The log says when you leave a mob for the tank's.
- **The group plan's kill order is steadier.** Once the plan has a mob, another must be twice as urgent and the first held 4 s before it changes. Before: 1.3 times and 1.5 s, under the tank's own x1.6, so it moved with every tab. A skull still wins, and the fight's first pick is as before. Solo: unchanged.
- **No Hunter's Mark at a mob that is dying.** The log had one at every kill, each refused *Your target is dead*. A target with no health is no target, whatever the client's dead flag says (it lags, and the mob's auras are gone first). The Mark also skips a mob that dies within 3 s.
- **A DoT that never shows on a mob is left off it.** Serpent Sting went on one Lesser Stone Golem every 2 to 4 s: the client confirmed each cast and the sting never appeared. An immunity is said in the combat log, and Forever gives none. From casts the client confirmed only:
  - once: taken as ticking for 12 s;
  - twice on one mob, while it shows on others: that mob is left alone;
  - two mobs of one name like that: every mob of that name, from the first look (logged: *Serpent Sting never shows on Lesser Stone Golem (2 of them ...): left off that mob*).
  - A spell that has shown on no mob this session is never left off, only re-cast on its duration (the client may not show it at all). Every class's DoTs go through this (`H.dot_worth_it`).
- **Forever ESP alerts: in a dungeon or raid an elite alone is no alert.** Every Dark Iron Looter rang the alert sound every 15 s. Bosses, rare elites and mobs above your level still alert. Outside an instance: unchanged.
- Internal: `assist.lua` KEEP / FINISH / MARK_RANK, `keep_kill`; `tactics.lua` SWITCH_GROUP / SETTLE_GROUP; `rotation.lua` `H.dot_noshow`, `H.dot_verdict` (the landing watch's rows now carry the spell id, the mob's name and whether the client confirmed the cast); `build_situation` drops a 0-health target; hunter `mark_wanted` ttd < 3; `esp/forever.lua` alert_check reads `P.targeting.context()`.
- Tests: 1 new in `aio_assist_test` (and its first case now out of a fight), 1 in `aio_react_test`, 2 in `aio_rotation_test`, 1 in `aio_hunter_test`, 1 in `aio_boot_react_test`, 1 in `aio_esp_forever_test`.

## 1.73.4 (2026-10-04)
**Warlock: shards over the limit are dumped during the fight too.** The user: "Dump Soul shards if it hits the limits".
- Before, spares were destroyed only out of combat, so a long fight with several Soul Harvest kills left every shard in the bags until it ended.
- Now, in combat, a shard over *Soul shards to keep* is destroyed at once, at most one every 2 s. It costs no global cooldown, so the rotation goes on. Out of combat a spare still becomes a Spellstone or Firestone first.
- *Keep soul shards under a limit* off: nothing is destroyed, as before. On Forever the 1.73.2 check still applies: if a destroy leaves the shard, destroying stops for the session and the log says so.
- Internal: the rotation tick calls a class's `combat_upkeep(s)` in combat (no GCD, never stops the walk); the warlock's dumps the shards.
- Tests: 1 new in `aio_warlock_shards_test`.

## 1.73.3 (2026-10-04)
**Warlock (Forever): Soul Harvest triggers on every kill it can.** The user: "If its talented then try to get it to trigger as much as possible".
- Soul Harvest (Forever's talent): a non-trivial mob that dies with your Drain Soul on it raises your mana regeneration for 10 s, and keeps it going while you cast (the client's spell tables, spell 1242853).
- With it talented, Drain Soul goes on whichever mob you are fighting dies soonest inside one channel: the target in its execute window, or another engaged mob under 45% that will die at least a second sooner.
- Never on a kill that does not count (a grey mob, a critter, a totem), and never on a mob you crowd-controlled (the drain would break it).
- The shard limit does not hold these kills back; spare shards are still trimmed out of combat. Once the drain is running, nothing else takes the kill from it (as for Improved Drain Soul).
- Without Soul Harvest nothing changes: Era's Improved Drain Soul and the 1.73.2 shard limit are as they were.
- Tests: 4 new in `aio_warlock_shards_test`.

## 1.73.2 (2026-10-04)
**Warlock: the shard limit stops Drain Soul.** A player on Forever: "it keeps casting drain soul and my backpack is always full ... i even set the slider to max 5 shards".
- The cause: *Soul shards to keep* only ever said what to do with shards once made (spend them on a Spellstone or Firestone, else destroy them out of combat). Drain Soul itself never looked at it.
- At the limit, Drain Soul is no longer cast for a shard. Shadow Bolt or the wand finishes the mob. With Improved Drain Soul it is still cast while mana is short, for the mana refund. *Keep soul shards under a limit* off: as before.
- **Forever's bags:** shards are counted and destroyed in JCore's corrected bag rows (the backpack and bags). The Buyback list is left out: before, shards sold to a vendor were counted, and a destroy could land on a Buyback row.
- **A destroy must be seen to work.** If the client says yes but the shard is still there 1.5 s later, nothing more is destroyed this session, and the log says so once (*destroying Soul Shard did nothing on this client*). Destroying has never been recorded on Forever.
- The switch has a tooltip in the warlock's window saying what the limit now does.
- Tests: new `aio_warlock_shards_test` (3) and `aio_shard_bags_test` (3).

## 1.73.1 (2026-10-04)
**Pet skills taken off autocast are pressed again.** The user: "I dont see any being used when its off auto".
- The likely cause: when the client does not say what the pet is attacking, every pet rule saw a pet on nothing. The routine Growl on the pet's own mob was then never pressed, and with autocast off nothing Growled at all. A whole-plugin test reproduced it: 0 Growls in 14 s on 1.73.0, one every cooldown now. It also fits the first in-game log, where only the urgent Growls ("on you", "your threat 84%") ever went out.
- Fix: when the client does not say, the pet's mob is the one it was last sent at (while it lives, up to 30 s), and for the taunt also a mob hitting the pet. Every pet rule sees it, as do Mend Pet's "is the pet holding anything" and the evade recall.
- A pet press is now confirmed by the skill's name when the client reports another rank's id than the pet book's. Before, every such press read as "no confirmation" and was marked down, enough to stop the routine Growl.
- **The log says why.** Every 20 s of a fight, one line lists each skill the engine holds off autocast and either when it was pressed or why it waits, e.g. *pet skills: Furious Howl waits: 1 of your group within 15 yd of the wolf (it needs 2: you are 28 yd away) | Growl pressed 2s ago*. If something still stays unused, that line names the reason.
- Tests: new `aio_boot_pet_skills_test` (4; the whole plugin with a hunter, its wolf and a mob).

## 1.73.0 (2026-10-04)
**Quests apart from the ESP.** The user: "quests ESP and Forever ESP have them be separate so if i dont want ESP but I want RestedXP I can have that".
- **Enable ESP** (the ESP page) switches off the ESP only. Quest marks, quest paths, Forever's quest areas, the guide's marks (Classic), the guide panel and its waypoint line follow the Quests page's own switches and still show with the ESP off. Both clients.
- With the ESP off nothing else is marked, and a quest mark leaves out the cast bar, the ring and the line. No threat panel, arrows or telegraphs then. Alerts keep their own switch.
- The toggle key (Z) still hides everything, quests included.
- The Forever ESP page's *Quest targets* row is gone: *Enable quest ESP* alone decides. If you had that row off, *Enable quest ESP* is switched off once for you.
- The Classic ESP page keeps its *Quest targets* and *Guide targets* rows until it moves to the icon card. *RestedXP guide only* is unchanged.
- Internal: `P.esp.render(visuals, master, quest_visuals)`; esp/init.lua draws only quest and guide entities with the ESP off; `elements.begin_frame(quests_only)`; forever.lua `read_settings(master, esp_on)`, `S.on.quest` = `questie_on`; quests.lua's draw_quest_lines follows `questie_on`; the HUD job draws the guide and the quest paths with the ESP off; page_forever takes `env.quests` (one-time migration `quest_row_1:<page>`).
- Tests: new `aio_boot_quests_apart_test` (5), 3 new in `aio_esp_forever_test`, 1 new in `aio_esp_marks_test`, 1 new in `aio_boot_rxp_only_test`.

## 1.72.0 (2026-10-04)
**Hunters: TAME on every beast you can tame, and what it teaches.** On the Classic ESP.
- **A violet TAME chip** before the name of a beast the game says can be tamed, at or under your level.
- **Its details line** says the family and the skills a beast of its level teaches, at the rank that level carries, e.g. *Cat: Claw 4? new, Dash 1?, Prowl 1?*. Above your level it says *Cat, tame at 32* instead, with no chip.
- **"?"** means not confirmed: which of its family's skills one beast has is the server's and never sent to the client. Once you have seen that kind of beast (its npc id) use a skill on you or your pet, the "?" goes. Read from the combat log; on Classic it names the skill but not the rank, so the rank is still its level's. What was seen is kept between sessions.
- **"new"**: higher than the rank your current pet has, or a skill it does not have.
- Where it comes from: the client's own creature cache (tameable flag and family; JCore 1.8.6) and its spell tables (`modules/beasts_data.lua`). The cache is written when the game closes, so a beast first met this session shows from the next one on.
- The ESP page has a switch for it, under Tags: "Hunters: TAME on beasts you can tame" (on).
- Internal: new `modules/tame.lua` (`info(e, now)`, `saw`, `seen`, `ctx.store("tame")`), `cfg.TAGS.tame` / `cfg.TAG_RGB.tame`, `esp/elements.lua` resolve_tags and detail_text. Each mark takes the frame's time, not a clock read (the frame-cost test caught 79 core.time calls a frame; now 16-19).
- Tests: new `aio_tame_test` (4), 1 new in `aio_esp_marks_test`.

## 1.71.0 (2026-10-04)
**Every pet skill is used when it helps, on the mob it helps with.** The numbers come from the client's own spell tables.
- **Furious Howl** (60 focus) only when two or more of your group (you count) are within 15 yd of the wolf. Before, autocast spent it every 10 s with nobody near, which starved Growl.
- **Dash / Dive** when the pet's mob is 15 yd or more away from it: an add on you, a pull from range.
- **Charge** (boar) when its mob is 8 to 25 yd away.
- **Thunderstomp** (gorilla) for two or more within 8 yd of it, or the mob on you beside it.
- **Shell Shield** (turtle) when it is tanking and falling fast, or three are on it.
- **Cower** only in a group with a tank, when the pet is about to pull its mob (90%) or already has. Never on autocast while the rotation runs: solo the pet is the tank.
- **Sacrifice** (Voidwalker) when you are about to die. **Seduction** on a humanoid add on you that is not your target; it shares the class's crowd control, so an add gets one answer. **Consume Shadows** between fights when the Voidwalker is hurt.
- **Focus:** a skill keeps 15 focus back for Growl while the pet is the tank and Growl is coming ready.
- Claw, Bite, Screech, Lightning Breath, Scorpid Poison, Firebolt and Lash of Pain stay on the pet's own autocast: on cooldown is right for them. Prowl stays as you set it.
- Each skill the engine presses is off autocast while the rotation runs, and back as it was when it stops. The 1.68.1 checks apply to each one: if one will not stay off on your client, it is left on autocast for the session.
- The pet's clock now knows its own 1.5 s global cooldown (Claw, Bite and most skills start it; Growl does not). A refusal inside it is asked again after it and never counts as "autocast will not switch off".
- Internal: new `modules/react/rules/pet.lua` and `modules/beasts_data.lua`, generated by the new `tools/jcheck/beasts_extract.js` from CreatureFamily, SkillLineAbility, SpellLevels, SpellCooldowns, SpellPower, SpellMisc, SpellRange and SpellEffect (WoWDBDefs: SpellPower, Creature, CreatureFamily, SkillLine in `tools/jcheck/dbd/`). `pet.lua` holds any skill (`aim`, `aimed`, `stuck`, `release_all`, `skill`, `beasts`); the taunt functions are wrappers. Growl's mode sync no longer asks the client's flag either. `petthreat.from_pet(row)`.
- Tests: 7 new in `aio_react_test`, 2 new in `aio_hunter_test` (its pet harness has a book of several skills).

## 1.70.0 (2026-10-04)
**Assist the tank.** The user: "in all dps classes lets add an option to assist tank meaning his target and swaps to his targets".
- New switch *Assist the tank*, off by default. It is in every class's window (a new Group section) and on the Rotation page (Targeting).
- When it is on and you play damage in a group, your target is the tank's. When the tank changes target, so do you, once the tank has kept the new one 0.3 s (at once if you have no target). It comes before the fight plan and the target score, and works with *Pick targets automatically* off.
- Not followed: the tank targeting nothing or a friend, a crowd-controlled mob that damage would wake, somebody else's mob, a mob past 60 yd, and, mid-fight, a mob not pulled yet. Then you target as before.
- The tank pulls. A mob not in combat yet is selected but not attacked, the pet is not sent at it, and a hunter does not open on it. Once it is in combat with the group you join in, even before you are in combat yourself. The engage key still opens at once.
- Who the tank is: the group's role. Era players rarely set one, so without it the tank is the member the mobs in combat are on, or the one in Defensive Stance, Bear or Dire Bear Form, or Righteous Fury. The last tank found stays the tank between pulls.
- It does nothing for the tank or the healer (group role, else a tank or healing profile), solo, or while the tank is dead.
- A line under the switch in the class window says what it is doing: *Assisting Tanky (group role): on Kobold Miner.*, *...: waiting for Tanky to pull Kobold Miner.*, *Assist: you are the healer.*
- New `modules/assist.lua`, asked by `targeting.better_target` and `rotation.may_engage_unit`. The class window now shows option sections that have no capability flag to every class, a live note row, and toggle tooltips.
- Tests: new `aio_assist_test` (6), 1 new in `aio_classwin_test`. Unverified in game.

## 1.69.1 (2026-10-04)
**Telegraphs you can see through.** The user, of a 5 yd Throw Dynamite painted solid gold: "u cant see shit with it".
- The cause was not the fill, which was 15%. The native ring glows inward from its edge (alpha × (distance from the middle / radius) ^ fade), and JCore passes a fade of 1.0, so the glow fell off in a straight line across the whole disc. Measured off the screenshot: 92% at the edge, still about 45% two thirds of the way in. The progress ring (alpha 200) glowed over the middle the same way.
- Each telegraph ring now gets the fade that brings its glow down to a quarter 0.5 yd in from the edge (0.3 yd for the progress ring), whatever the circle's size. A ring under a yard keeps the native default of 2.5. The colours, the fill and the slider are unchanged.
- Tests: 1 new in `aio_telegraphs_test` (an engineer throws dynamite at a group member; every ring over 1 yd must be down to a quarter 0.75 yd in). It fails on the old code.

## 1.69.0 (2026-10-04)
**The Forever ESP, reworked: the icon card.** Cleaner, the game's own icons, each fact once, and a page with a Style and a grid of what to show.
- Every mark is a card: the game's icons beside one pill of text. A creature-type icon, class crest, town-service icon or quest giver's ! / ? says what it is; an unknown name is no longer repeated as a word ("Elemental").
- Each fact once: on you is the ring (no "on you" pill, no solo "aggro #1 of 1"), elite / rare / boss is the target frame's dragon ring or skull (no ELITE pill), how it fights is a sword / bow / staff icon, health is the bar (no "100%"), in combat is the swords, threat only in a group.
- Quests: the attack / loot / use cursor, the count and the title on one row. Corpses: the bag and the pelt. Herbs and ore: icon, name and distance on one line. Casts: the spell's icon, and a shield when it cannot be interrupted. Town npcs: their service icon (repair, flight, inn, bank, trainer...) and title, no level.
- The art ships inside the plugin: `modules/esp/art_pack.lua` (78 icons + the status-bar texture, cut from the Era archives by the new `tools/jcheck/art_pack.js`), written once to `scripts_data/jambix_aio/art/` by `modules/esp/art.lua`. Players get the icons now; before, they existed only on this machine. `esp/forever_icons.lua` and `forever_icons_test` removed.
- The page (`modules/esp/page_forever.lua`): Simple is ESP (Style: Minimal / Clean / Detailed / Custom), In a fight, and an Enemies / World / Friends grid. Advanced adds every piece of a mark, the look, and per category what its mark shows (Everything / Icon, name, health and casts / Icon only), range and colour. Same page and ids: nothing saved is lost.
- One-time move: "Health as a number" off when still at its old default; the Style set to what the pieces read as.
- Fixed: a mob whose objective the game tags as found ("Roiling Winds destroyed") is a kill, not USE.
- New shared painter `modules/esp/card.lua`; config gains `DETAILS`, `CATEGORY_DETAIL`, `ESP_STYLES`, `ESP_PIECES`. The Classic ESP is unchanged (next pass).
- Tests: new `aio_esp_card_test`; `aio_esp_forever_test` and `aio_esp_split_forever_test` extended. Full suite 849 passed.

## 1.68.2 (2026-10-04)
**Pet mode Focus works again.** Broken since 1.68.0.
- The cause: the pet's focus (power) reader added in 1.68.0 took the name of the reader for the unit pinned in Focus mode. Focus mode's tick then got a number instead of the mob, and failed every tick.
- The power reader is now `pet.focus_power`; `pet.focus` is the pinned unit again.
- Tests: 1 new in `aio_hunter_test` (its pet harness keeps its P as `W.P`).

## 1.68.1 (2026-10-04)
**Growl: no more "Spell is not ready yet".** Seen in the first log of 1.68.0: two aimed Growls refused, and the mob came back to the pet a second later anyway.
- The cause: Growl was never really taken off autocast. The switch-off was skipped whenever the client said autocast was already off, so the pet kept Growling by itself and spent the cooldown first. The client's spell tables confirm Growl has its own 5 s cooldown and no global cooldown, so "not ready" meant it had just been used.
- Autocast is now switched off, and back on, without asking that flag.
- The pet's own cast events check it. If the pet uses Growl when we did not press it, autocast is switched off once more. If that happens again, Growl is left on autocast for the session ("will not stay off autocast here" in the log). The pet is then moved onto the mob that needs the Growl, and autocast Growls it there.
- A press the client refuses as "not ready" no longer costs the full 5 s: it is asked again a second later. Two refusals the pet never confirmed (or three in 20 s) also leave Growl on autocast.
- The reaction log names every spell sent with a client error: *client error after Auto Shot (or Growl, sent with it)*. Before, a refused Growl was blamed on Auto Shot.
- Readout: *Pet taunt: Growl left on autocast (...): the pet is moved instead* when it gave up.
- Tests: 3 new in `aio_hunter_test`, 2 new in `aio_react_test`. New DB2 definitions `tools/jcheck/dbd/SpellCooldowns.dbd` and `SpellCategories.dbd` (WoWDBDefs).

## 1.68.0 (2026-10-04)
**The pet's Growl goes where it is needed.** Every mob in the fight is checked, not just the pet's.
- **A mob hitting you is Growled off you** when it is within the pet's reach, even if the pet is attacking something else beside it.
- **A mob about to turn to you is Growled first:** your threat on it at 90%, or climbing to 100 within 2 s. Classic Era only: Forever's threat is unread.
- **Otherwise Growl goes on the pet's own mob whenever it is ready**, as autocast did. Not on a mob under 8% health, and not while the pet has under 15 focus.
- **Growl is off autocast while the rotation runs**, because autocast always spent it on the pet's own target. It goes back on when the rotation stops, you mount, the pet mode is Off or Focus, or the plugin is paused or unloaded.
- **A mob on you out of the pet's reach: the pet goes to it** and Growls it there. With Growl, the pet takes a mob hitting you in melee (or any mob on you while you are under 60%) even if the mob it leaves would turn on you. Your shots then move off that mob, so it stays on the pet.
- **Changing targets:** solo, a mob on the pet whose threat you are close to pulling (75%, 90%) drops down the kill order, unless Growl lands on it within a second.
- **Intimidation** (hunter): when the pet's mob has turned on you and Growl cannot bring it back (not ready, or it went out and the mob stayed on you).
- **Voidwalker:** Torment works the same way, and Suffering goes out for two or more around the Voidwalker.
- **In a group:** only a mob on you, never a boss, never one the tank is on. No upkeep Growl (the tank holds the mobs). Pet mode Tank ignores the group.
- **Forever:** the pet's spellbook reads empty there, so none of this runs and Growl stays on its own autocast.
- Readout: a *Pet taunt:* row (Growl's cooldown, the next mob, where the pet goes).
- Internal: new `modules/react/petthreat.lua` (the planner). New reaction *Pet: taunt* (threat category, priority 74, pet lane) and hunter reaction *Intimidation: give the pet its mob back* (73). `pet.lua` adds `aim_taunt`, `release_taunt`, `taunt_aimed`, `ready_in`, `focus` and `in_range`. `pet.cast` asks the client's range answer only for the pet's own target. `main.lua` adds `on_disable` / `on_unload` hooks.
- Tests: 8 new in `aio_react_test`, 4 new in `aio_hunter_test` (its pet harness records events and pet casts).

## 1.67.1 (2026-10-04)
**Fishing: no more "You are Away / You are no longer Away" spam.** Seen on Forever.
- The cause: the jump never reset the client's idle clock, so you went Away anyway. Each jump took Away off and the client put it straight back. That flag change was answered with another jump, about 30 times.
- A flag change within 30 s of our own jump is now its echo, not a reason to jump again.
- If Away comes straight back after a jump, jumping stops for the session. The Fishing page says "Stay active gave up: the game marks you Away anyway". Fishing goes on.
- Backstop: at most one jump a minute in answer to a flag change, and after three in ten minutes it stops too.
- The keep-alive now taps a turn (start and stop in the same tick, so your facing does not change) before the jump. The .api counts a turn as input that resets the idle clock; a jump may not count. Unverified in game.
- Trace lines: `fishing: player flags changed 0.4s after the keep-alive (echo 1)`, `fishing: stay active stopped: ...`.
- `main.lua`'s registration said 1.66.2; it now matches `header.lua`.
- Tests: 2 new in `aio_feedback_161_test`. The 1.61.2 case now fires its flag change outside the echo window.

## 1.67.0 (2026-10-04)
**Corpses you can't skin are left out, and levels are coloured like the target frame.** On both ESPs.
- **SKIN only when your Skinning reaches it.** A corpse's level sets the Skinning it needs: anyone can skin up to level 10, then 10 points a level up to 100 at level 20, then 5 a level (300 at 60). That is compared with your skill, gear bonus included (JCore 1.8.5).
- **A corpse you can't skin and can't loot is not drawn.** With LOOT still on it, it shows LOOT only. Auto-skinning no longer tries corpses above your skill.
- **No level on corpses.** A corpse row shows LOOT, SKIN and the distance.
- **A mob's level is in its target frame's colour:** grey, green, yellow, orange or red, by the game's bands. Only the number is coloured; the rest of the pill is unchanged. Only on what you can attack, like the frame; a friendly level stays plain.
- **Where the skill comes from.** On Forever no skill read has been recorded yet. If none answers there, the highest Skinning rank you know is used, and its cap counts as your skill: Apprentice 75, Journeyman 150, Expert 225, Artisan 300. A corpse past that cap is hidden; one between your real skill and the cap still shows SKIN. The trace says which source answered: `fesp skinning: skill 75 (rank)`.
- Tests: 4 new in `aio_esp_forever_test` and `aio_esp_marks_test`. The marks test's `label()` reads a pill with a coloured level as one label.

## 1.66.3 (2026-10-04)
**The ring under a mob is see-through.** With four to seven mobs on your pet, the ground under them was painted solid amber.
- The cause: the game's circle glows inward from its edge, and JCore's slow fade spread that glow across the whole disc. Every ring was a filled disc at full strength.
- The glow now stays on the rim. A ring on its own is see-through: red at about 80% for a mob on you, amber at about 60% for one on your pet or group, and the amber ring is thinner.
- The more rings there are, the fainter each is. From three rings, each red ring is at 60% of a lone ring's strength. From five, each amber ring is at 45%. Red stays the stronger, because it is the warning.
- Same fix for the red ring on the Classic ESP.
- Tests: 3 new in `aio_esp_forever_test` and `aio_esp_marks_test`. Eleven test files no longer put the live `scripts/` folder ahead of `JTEST_OVERLAY`, so a staged copy is tested in them too.

## 1.66.2 (2026-10-04)
**Sell junk only sells what is in your bags.** Seen on Forever.
- After a reload, items already sold were offered again from the merchant's Buyback list ("selling Broken Boar Tusk from bag 0 slot 39"). Each such sale changed nothing, and after three selling gave up for the visit ("3 sale(s) left their item in place").
- The cause: on Forever the bag list also holds the Buyback items, as backpack slots past the end of the backpack. Those are now neither sold nor watched. The trace says how many were left alone, and the backpack size used.
- This also removes a false "sell junk STOPPED": every sale moves the Buyback list, which read as another item leaving its slot.
- Tests: 2 new in `aio_forever_npc_test`, whose fake helper now lists the Buyback rows as the real one does.

## 1.66.1 (2026-10-04)
**Fishing counts catches right, and stops when your bags are full.** Seen on Forever.
- Catches were counted as "got away". On Forever the bobber click always reports failure, even when the loot window opens, so fishing never knew it had hooked anything. Now a click counts once it is sent, and a loot window that opens after it is the catch, even when the game's own auto-loot empties it at once.
- The catch's name is read as the window opens, so "Last catch" fills in with the game's auto-loot on too.
- "Stop when bags are full" now also stops when the game itself says "Inventory is full" after a catch. The stop reason quotes it.
- The free-slot count it checks before each cast is fixed in JCore 1.8.2.

## 1.66.0 (2026-10-04)
**Mend Pet is weighed, not just triggered.** The pet's health opens the question. The heal then waits for a reason the log names ("Mend Pet waits: ..."):
- **Never when it could get you killed.** Mend Pet is five seconds standing still. It waits during a bail-out, while you stand in danger ground, when your health would end the channel under the defensive line, when you have too few seconds to live, with a mob in melee with you (or arriving inside the channel) while you are under 50%, and when it would leave too little mana for Feign Death. Short of that, a mob in melee or on its way costs it points.
- **Only when it matters.** A pet that will outlive the mob it is holding finishes the fight and is topped up after it.
- **Only when it works.** If the pet would die inside the channel anyway, no channel. Mend Pet's healing is read from its tooltip against the pet's health.
- **Talents count.** With Improved Mend Pet, a feared, asleep or polymorphed pet is freed at any health, and a poison or curse on it gets it healed sooner. A Beast Mastery hunter's pet weighs more.
- **A heal that turns dangerous halfway gives way.** If a mob turns on you mid-channel and you are low, any reaction may cut it and the kite can step out. The log says "Mend Pet gives way: ...".
- Health Funnel gets the same safety checks.
- New `modules/react/petcare.lua`. Tests: 4 new in `aio_react_test`.

## 1.65.2 (2026-10-04)
**Fishing after Journeyman: no more "Spell not learned".** Seen on Forever.
- The cause: after one cast that started nothing (not facing water, say), fishing switched to the profession call for the rest of the session. That call casts Apprentice Fishing, and training Journeyman removes Apprentice, so every cast after that was refused until fishing switched itself off.
- Now, above Apprentice, fishing always casts the rank you know. A cast that starts nothing counts as a failed cast, and four in a row still stop fishing.
- The stop reason quotes the game's own error text.
- Each failed cast writes a `fishing:` trace line with the spell and the error text.

## 1.65.1 (2026-10-04)
**Telegraphs are see-through.** You can see mobs, and yourself, standing in the danger ground.
- The second fill that grew over the shape as a cast ran is gone. The cast's progress is now a thin line sweeping out to the edge.
- "Fill strength" is on the ESP page: 0-50%, default 15%, and never more than half. If yours was still at the old default of 25%, it is moved to 15% once.
- Cones are drawn from their own points, so the fill and the edge always match.
- New "Show telegraphs in": everywhere, or raids and dungeons only.
- A boss's mechanics get a heavier edge.
- Only danger is highlighted, never safe ground.

## 1.65.0 (2026-10-04)
**Telegraphs.** The ground an enemy spell is about to hit is painted under you:
- a circle around the caster, a circle where it aims, or a cone in front of it;
- it fills as the cast runs, and turns red while you are standing in it;
- a label gives the spell, what to do about it (from DBM: "Dodge", "Run out", "Breath: get out of the front") and the seconds left;
- missiles get a circle where they land;
- ground that stays bad (Flamestrike, Consecration) stays painted;
- alerts at the top of the screen cover room-wide spells, hazards on you (Chill, Living Bomb) and whatever you are standing in.

New "Telegraphs" section on the ESP page:
- on/off, and whose spells: every hostile cast, elites and bosses, or boss-mod spells only;
- hostile players, range, labels and alerts;
- with advanced settings: fill strength, missiles, and ground that stays.

New `modules/telegraphs.lua`. Tests: `aio_telegraphs_test`.

## 1.64.1 (2026-10-04)
**Quest marks are per objective.**
- Each objective's mobs and objects are marked only while that objective isn't done. Done comes from the quest log, matched by subject and plurals, or on Forever from the progress messages.
- Once every objective is done, the quest counts as complete and its turn-in is marked instead.
- A kill objective with no name in the quest data is checked against the unit's own name.
- An npc only finished objectives want no longer counts as a quest npc.
- Spawn paths lead only to targets still wanted.
- The quest index also rebuilds on the progress messages.

**Hunter kiting off by default.** "Run and shoot before there is a pet" now defaults to off. It is switched off once for existing players, and the switch is noted in jambix.aio.migrations.json.

## 1.64.0 (2026-10-04)
- New "Show advanced settings" switch (Overview page, off by default). It hides 6 sections and over 37 fine-tuning widgets: ESP Performance, ESP "Look and placement", Rotation Tuning, Cooldowns and Reactions, Automation Safety checks, ranges, colours and timings.
- The class sections on the Rotation page show only with advanced settings on.
- Hidden settings still apply. No widget moved page.
- Two stale Cooldowns labels removed.

## 1.63.0 (2026-10-04)
**Class windows hold the class's options**, with the same ids and values as the Rotation page:
- threat, stances and forms, wand, healing and pet mode, by capability;
- the hunter's kiting and step-out;
- the rogue's "Stealth by itself";
- the warlock's Healthstone, Soulstone and shard limit.

A status line shows the rotation on or off, the profile, and the stance or form.

## 1.62.0 (2026-10-04)
**A window per class.** It has three kinds of group:
- **Pick:**
  - paladin aura, seal, self blessing and Righteous Fury;
  - mage and warlock armor;
  - shaman shield;
  - Shadowform.

  Each offers Auto, None or a spell.
- **Keep:**
  - on by default: Battle Shout, Fortitude, Inner Fire, Arcane Intellect, Mark of the Wild and Thorns;
  - off by default: Shadow Protection, Trueshot Aura and Omen of Clarity.
- **Form:** warrior stance or druid form.

**How it behaves:**
- An untouched default acts only while the rotation runs. A choice made in the window acts whenever the plugin is on.
- The game leads: an action-bar cast becomes the pick, a click-off is respected, and an expired buff is recast.
- It waits while you're dead, mounted, stealthed, eating or casting.
- The rotation, spell window, reactions and group buffs skip what the window owns.

**Also:**
- The hunter's Aspects moved into the hunter's class window. The separate Aspects window is gone.
- Fix: a paladin no longer swaps Kings and Might every 2 s.

## 1.61.3
- Traces why the Aspects window isn't shown.

## 1.61.2
- Anti-AFK while fishing: a jump every 150 s, and after going Away ("Stay active" switch, on by default). Trace line for each jump.

## 1.61.1
- Fix (Forever): fishing below 75 failed, because the spellbook fallback picked Forever's Fishing id 1240948.
  - Now only the classic ranks are cast by id.
  - A cast by id that starts no channel switches to the profession call for the session.

## 1.61.0 (2026-10-04)
- "RestedXP guide only" switch: only the guide's marks, panel and line are shown.
- Rogue "Stealth by itself": Never / Only before an opener (the default) / Before an opener and near enemies.
- Fishing casts the highest known rank (18248, 7732, 7731). Before, it failed after skill 75.

## 1.60.0 (2026-10-04)
- The Debug page moved to the separate Jambix Debug plugin. The AIO waits up to 30 s for it, and has no Debug page without it.
- Trace lines read the "recording" flag live.

## 1.59.0 (2026-10-04)
- Forever ESP marks quest objects from the start, from the quest index and the quest database. COLLECT/USE plus a count, with the quest title under it.
- Trace line "fquests: db: ..." and a db_objects counter.

## 1.58.1
**Range measured hitbox to hitbox** (H.gap, H.melee_range, H.in_melee).
- Fixes "Target too close" at 8–11 yd, Raptor Strike and Mongoose Bite not being used on big mobs, and melee being switched off in melee.
- Learned range edges are now measured from the mob's edge.

## 1.58.0
- Group kill order (with a living tank): the tank's target, markers, mobs on the healer, and your threat.
- Hunter "Clip the add": Wing Clip the add, step 11 yd clear, and keep Auto Shot on the target.

## 1.57.1 (2026-10-03)
- Loot before the next pull: no new fight while auto-loot has a corpse in reach. The hold is capped at 10 s per corpse.

## 1.57.0
- The multi-mob plan runs on Forever, with a Forever status line on the Rotation page.

## 1.56.0
- Multi-mob plan (react/tactics.lua):
  - kill order;
  - the pet picks up the add;
  - area spells counted where they land;
  - outnumbered sets defensive.
- "Plan:" line on the Rotation page and on screen. Journal lines.

## 1.55.4 (2026-10-03)
**Forever audit:**
- Skin-only corpses are left alone while skinning is off (Era too).
- Quest paths are drawn on Forever.
- Fixed the doubled "losing the race" text.

**Also:**
- The Auto Shot log names its target through JCore.
- The loot-window trace names the coin slot.
- FOREVER_API.md regenerated from 38 sessions.

## 1.55.3
- A node is worked until it is gone. Successful swings no longer count as failed tries (Era too).
- Forever trace lines for done and giving up.

## 1.55.2
- Forever corpses are opened through JCore's ctx.loot.open, with no repress while an attempt is pending.

## 1.55.1
- Every auto-loot attempt is traced, and a corpse left unlooted gets a periodic "why".

## 1.55.0
- Every Forever workaround moved into JCore (JCore 1.6.0). forever_power.lua deleted.
- Quests read JCore's quest database. The Questie addon isn't needed.
- units.player_pet is used on every client.

## 1.54.2
- Forever: loot window slots are taken with loot_item (two passes) before the stuck-window closer runs. Trace lines added.

## 1.54.1
- An unlearned spell is never a candidate in the reactions or the rotation.

## 1.54.0
- Auto-loot and gathering work on Forever. The corpse and node lists are filled from the Forever ESP.
- Grey sales are checked by guid and slot, not by count. Trace line for the first sale.

## 1.53.0
- Game Lua quest reading on Forever (quest log, areas, units). Dormant: the client refused the bridge.

## 1.52.1
- Forever: is_spell_known false is final. Trace line for the spellbook.

## 1.52.0
**Forever creature cache:**
- names and titles;
- ELITE/RARE/BOSS pills, with category rows;
- alerts by rank.

**Also:**
- Rank is used by targeting and the plan.
- is_tap_denied is believed when true: tapped mobs are greyed, show no LOOT, and are never auto-targeted.
- Auto Shot trace says why there was no shot. A melee attack left on is stopped before a retry.

## 1.51.0
- Forever vendor and quests (all off by default):
  - sell grey items;
  - accept quests;
  - turn in quests and choose a reward by class gear rules.

  Hold Shift to skip.

## 1.50.1
- Forever fixes for every class: druid Cat Form spam, warrior Battle Stance spam and rage counting, and hunter and warlock pets not found.
- Boot tests for all nine classes.

## 1.50.0
- Hunter: out of Cheetah or Pack before a hit lands, into your last fighting aspect.

## 1.49.0
- Hunter Aspects window: one slide switch per aspect.
  - On keeps it up, including after death and reloads.
  - Off cancels it.
  - The window follows the game, and the choice is saved per character.
- The rotation no longer casts aspects.

## 1.48.2
- Fix: a loading screen stopped damage measuring ("Invalid game object!"). Now an identity check.

## 1.48.1
- Forever: Auto Shot re-armed after every shot. Per-mob trace line.

## 1.48.0
**The Forever ESP honours its page:** categories, ranges, colours, elements and the mark limit. It also orders marks like the Classic ESP.

**New on Forever:**
- herb, ore and chest nodes with icons;
- LOOT inferred from who fought the mob;
- tapped inferred from combat.

## 1.47.5
- Quest objects get USE/COLLECT/TURN IN/PICK UP chips. Npc and object ids are kept apart.

## 1.47.4
- A mob fighting a stranger is left alone by interrupts.
- A garbage channel id is ignored (Mend Pet is no longer clipped).
- Forever party roles (JCore 1.5.13).

## 1.47.3
- No quest, spawn or guide lines inside dungeons and raids (option to turn them back on).

## 1.47.1
- Critters off by default, switched off once by migration. The Forever ESP follows the same switch.

## 1.47.0
- Classic and Forever ESPs split: Forever gets its own "Forever ESP" page and its own fight file (jambix.aio.forever_fight.json).

## 1.46.0
- Rogue stealth only for an opener or a sneak (H.stealth_wanted).

## 1.45.2
- Forever quest marks: PICK UP / TURN IN / QUEST / KILL n/m / USE / COLLECT.
- "Unknown" is never learned as a name.

## 1.45.1
- Forever names also come from the ESP's learned names.
- "react sample" trace line.

## 1.45.0
**Rotation and reactions on Forever:**
- combo points, energy and rage counted;
- the GCD read from a probe spell;
- damage from tooltips;
- names from casts.

**Also:**
- Trace goes to jcore.trace.txt.
- A Forever row in the readout.

## 1.42.0 / 1.43.0
- Forever ESP (esp/forever.lua):
  - mobs, players, corpses and nodes;
  - name, health, role, level, status, threat and cast bar;
  - box, ring and line;
  - threat panel, alerts and arrows.
- Names learned from casts. "fesp" trace lines.

## 1.41.0
- The Classic ESP is switched off on Forever.

## 1.40.1 – 1.40.5 (2026-10-02)
- Forever nameplate workarounds tried and removed.

## 1.40.0
- ESP native calls per frame: 2,124 → 1,172 with the ESP on, 884 → 705 with it off.
  - The clock is read once a tick.
  - Settings are read once a frame.
  - Sweep rows are reused.
  - Corpse loot is read twice a second.
  - Time-to-die samples are bounded.
- No mark prints over another, above the head too.
- Perf test with call ceilings.

## 1.39.0
- Removed "Use offensive cooldowns", "Use on-use trinkets", "Allow single-target taunts", and the rest Eat/Drink sliders. Burst windows decide.

## 1.38.0
- Runners learned per mob name.
- Slows with a cooldown saved for runners.
- "Stop the runner" reaction.

## 1.37.0
- Learning per mob (react/learn.lua): immunities, range edges, dead zones and evades. "[learn]" log lines and a "Learned:" row.

## 1.36.0
- The pet tanks: specials wait on pet threat, and the pet is used to shed threat.
- Casts wait 0.25 s after moving.
- Ranged inner range widens against a closing mob.
- pet_threat log lines.

## 1.35.2
- The rotation gate never backs off its own spells.
- A shot counts as busy in the idle report.
- Manual Growl reaction removed.
- Client red text logged.

## 1.35.1
- The last class rotation options are retired: warrior, rogue, druid, paladin, shaman, priest, mage and warlock thresholds. Every threshold is now derived.
- New whole-plugin boot test.

## 1.34.1
- The readout shows what the rotation is doing. "Nothing to press" is fixed.

## 1.34.0
- Per-skill damage measured from the combat log (react/damage.lua), with weighing by DPS or damage per mana. "Damage per cast:" readout line.

## 1.33.1
**Four "standing there doing nothing" causes fixed:**
- error text treated as a refusal;
- a dropped pull;
- the bail-out standing still;
- long holds.

**Also:** "[idle]" log line.

## 1.33.0
- Profile picker removed: the profile comes from talents and role.
- Scored rotation (adapt.lua).
- All thresholds auto-derived, and the tuning sliders removed. Retired ids are listed in RETIRED.

## 1.32.0
- The reaction engine is the only path.
- Removed the interrupt, defensive, racial, dispel, break-contact, Growl, pet heal, stop-fighting, potion, fear and hearth options.
- Bail-out at 20%, ending at 35%.

## 1.31.0
- Reaction engine (modules/react/: world, detect, behavior, engine, memory, rules). Interrupts, defensives, potions, mana, the pet, threat, CC and escapes are scored together.
- One Mend Pet per health dip.
- Rationed reads.

## Before 1.31.0
- 1.27.0: every channel treated as interruptible.
- 1.5.0: class detection. Before, every class ran the warrior rotation.
- 1.2.0: ESP settings moved to "Jambix AIO/ESP" (reset once).

**Undated:**
- **Freeze fixes:**
  - phase-spread timers;
  - shard count cache;
  - SPELLS_CHANGED and QUEST_LOG_UPDATE coalesced;
  - "%d" error fixed;
  - failing jobs paused;
  - terrain queries capped;
  - P.opt memoised;
  - angle wrap and path walker caps.
- **Base Forever support:**
  - client detection;
  - trait talents;
  - quest log tracking;
  - both objective text formats.
- Escapes are cast on the enemy, not yourself.
- Field read (BURN/AOE/CONTROL/SURVIVE/FLEE).
- Resources postures.
- Burst windows.
- DoT ownership and spreading.
- Talents read live.
- Warlock drain-tank profile, Fear key and shard limit.
- Skill catalogue.
- Hunter Auto Shot guard and the pet-first opener.
- Spell window and forecast.
- Hardcore guardrails.
- Quest paths.
- Automation engine.

# JCore

**Not released yet (in the working tree with the JCore 1.8.2 work): the object sweep never asks a bag item for a position.** Forever closed at 19:04 on 2026-10-12 (The Darkened Bank, Duskwood, an hour in): "Calling GetPositionWorldSpace on an object Item-4619-0-400000007EE0A4C0 that does not have a position fragment! Fix calling code!" The visible list can hold an item, and `units.lua`'s sweep asked every visible object for its position. An object whose guid starts "Item-" is now skipped before that call (`positionless`; the guid is the one the sweep reads anyway, so the guard costs the client no extra call); World Click to Move's mouseover gets the same guard, with `is_item()` as well. Test: new `jcore_units_item_test` (asks three times on the old sweep, never on the new).

## 1.8.1 (2026-10-11)
**The world gate: nothing runs until a character is in the world (2026-10-12).** Blizzard's report 13:26:07 shows `ASSERT(IsLoaded())` in `WowClientDB2.cpp`, 0.2 s after the loader started the plugins at the character select screen (App Up Time 28 s, no character logged in), with loader frames between the game's main loop and the assert. The game has not loaded its world tables there. The black box ended on the first pre_tick, and the next update would have run the plugins' start-ups and Debug's context line, all of which read spell, map and zone names. Now every native callback in `main.lua` (update, pre_tick, render, window, menu, control panel, both spell-cast hooks, game events) returns at once until `core.object_manager.get_local_player()` answers a valid player. Only the update callback asks, so that is one native a frame at that screen. The gate is probed once at load, so a load in the world opens it at once and behaves as before. Once open it stays open: a loading screen or logout later runs as it always has. New: `JCore.in_world()`, the events `jcore.world.waiting` and `jcore.world.open`, and the README's *Connecting* block (and the example plugin) start a plugin behind it. The offline harness has no player, so `mock.install()` sets `JCORE_NO_WORLD_GATE`. Tests: new `jcore_world_gate_test` (3). With the gate forced open, all three fail. Not yet seen in game.

**The UI is drawn over the game's own windows.** The user, 2026-10-11, asked that every JCore UI paint over WoW's frames, never behind them. The loader's render pass is painted under WoW's UI, and its window pass (`core.register_on_render_window_callback`) over it. `draw._flush` now hands every bucket at `LAYER.HUD` and above to `draw._flush_window`, which `main.lua` registers on the window pass. That is windows, panels, popups, tooltips, toasts, and Jambix AIO's HUD panels and alerts. The world bands stay in the render pass. The hand-off happens only while the window pass has run in the last 3 render frames; otherwise the UI paints inline as before. One flush is painted by at most 2 window passes, so a stalled render pass cannot leave a frozen UI on screen. Mouse capture is unchanged. Switch: JCore > UI *Draw over the game's windows* (`over_game`, on). `draw.stats()` gains `ui_pass`, `over_game`, `window_calls` and `window_painted`, and the Core page's `draw:` line says over or under. Tests: new `jcore_ui_over_game_test` (8); the mock gains the window callback. Not yet seen in game.

**No line-of-sight rays on Forever, by default.** From 16:50 on 2026-10-11 Forever died a new way, five times (16:50, 17:08, 21:30, 21:36, 21:47): the client's "Fatal Error: Your game crashed" popup and no report in `Errors/`, no Windows crash event, no driver event, 4.4 GB of commit still free. That had never happened before that day. The first came 1.5 h after `geometry.sight` began casting `trace_line` (1.8.0), and from 18:40 `sightguard` sent every package's sight ask through it; the user saw it with the ESP busy, the biggest asker. Not proven, so a switch: `geometry.set_forever_rays(on)`, off. Off, sight on Forever is nil (unknown) and no ray is cast, calibration included. That is the state before calibration, which every caller handles: `line_of_sight` and the guard answer "in sight" and the server judges the cast, the ESP shows no *LoS* pill and fades no mark. The native stays unasked. `sight_stats()` gains `forever_rays`. The walk map's own rays are unchanged.
- Tests: `jcore_sightguard_test` (1 new: by default nothing reaches `trace_line` or the native, and every asker gets "in sight"); the ray tests switch the ray on.
- Seen in game: it died the same way at 21:52, four minutes after a load with this in. So the ray was not the cause, or not the only one. It stays off while the other suspects are tried one at a time (the UI over the game's frames, which came in at 21:11, after which the rate went from 2 in five hours to 4 in 40 minutes; then the ESP). Switch it back on once the cause is found.

**No game calls outside scripts/.api.** The user, 2026-10-12: "Check all our rotation and ESP matches with .API if anything is outside the .api we need to identify it", then "if its not in the .api remove it from game calls". The new `tools/jcheck/api_usage.js` lists everything our plugins touch of the loader, from the source and from the recorder, against the .api. The rotation and ESP were already clean. These were removed:
- **`services/gamelua` is off on every client.** It was the bridge to the game's own Lua through `core.execute` and `core.read_lua_*`: each Forever session it sent one chunk into the game's Lua and polled it back, and it had failed every session since 2026-10-03. No job, no file, no native any more. The interface stays: `state()` is "off" with the reason, `ready()` is false, `run()` sends nothing. Jambix AIO's `esp/forever_quests` already reads the quest log from `core.quests` when the bridge is down. Its game-side bodies (the quest log, unit chips and quest areas through `C_QuestLog`, `C_Map`, nameplates and tooltips) are dormant.
- **`units.player_pet` on Forever no longer asks `get_all_minions`.** It is an izi_sdk Lua extension, not a native, and Forever's game objects do not have it, so it never answered. The pet is found among the swept units as before.
- Tests: `jcore_gamelua_test` (rewritten: Era and Forever, against a fake bridge that would answer, not one of the five calls is made); `aio_forever_quests_live_test` (the bridge-only tests removed; the two left run as Forever); `jcore_era_client_test` (the reason).

**The loader's legit-cast callback is no longer registered at boot.** On 2026-10-12, in Shadowfang Keep, Forever died on key presses in combat (right-click, strafes, action buttons). The game's `TurnOrActionStop` and the strafes call a native hook that turns the target's name into a string. In an instance fight that name is a secret value, so the client raises a fatal script error. The black box had every pass of ours closed, and the user's game does not crash without injection. That callback is how the loader reports the player's own casts, which it can only see by hooking input. Nothing of ours used it (only Jambix Debug's recorder listened), so JCore stops asking for it, in case asking is what puts the hooks in. `JCore.enable_legit_casts()` registers it on demand. Not yet seen in game: if the key-press deaths go on without it, the hooks are the loader's own.

**Every error the core catches, for Jambix Debug's fault log (`lib/faults`).** The user: "add to the Debug All Captures of anything we running thats going Null, or Crashing us for any Error whatso ever and log it on the hit". The core ran every job, timer, event handler and stage in a `pcall` and wrote one rate-limited console line, with no traceback and nothing in a file. A new hub, `rt.faults` (`JCore.faults`), is built straight after the log. While a listener is set (Jambix Debug 1.1.0's fault log):
- Jobs, timers, handlers and the core stages run under `xpcall`. The traceback and the locals of the frame that raised are handed over with the job, subscription or stage.
- Warn and error lines of the log are handed over too, before the limiter, so repeats count. So are errors `cache.try` swallows, and (from the recorder's watch) natives that raised or went nil.
- The native callbacks mark each pass as it begins and ends (update, pre_tick, render, window, menu, control_panel, the spell-cast callbacks). With `faults.deep` set, the scheduler, the event bus and the core stages mark every job and handler too.

**Without a listener nothing changes:** a plain `pcall` and a nil check, so players' JCore runs as before. A runtime built without the hub (a test's) uses `util.no_faults`. New: `scheduler.has_jobs(phase)`, so Jambix Debug's black box leaves a pass that runs no job unmarked (pre_tick).
- Tests: `jcore_faults_test` (new, 9); `jcore_debug_split_test` (no listener and no file without Jambix Debug; listening after a late attach).

## 1.8.0 (2026-10-11)
**The reaction framework, `ctx.react`.** Jambix AIO's `modules/react` engine (its engine.lua, memory.lua and latch.lua, 1.31.0 to AIO 1.7.6) is the core's now, `services/react.lua`, generalised so any plugin can register reactions: rules as data, scored per lane, with a memory of what was just done and a journal of why.
- **One engine per plugin**, built on the first read of `ctx.react` and bound to the plugin's handle: it casts, subscribes and logs as the plugin, and its rules go on `unregister` (`react.remove_owner`, from the registry).
- **What a consumer tells it** (`engine.configure`): its spellbook by name (`spells`; spell ids by default), the catalogue's word on a target (`target_kind`), the gates a press passes (`key_allows`, `channel_active`, `press_blocked`), its own action kinds beyond `spell` and `hold` (`kinds`: each with `validate`, `execute`, and optionally `target_kind`, `lane`, `answer`, `spell_named`), and `band`, `filter`, `explain`, `trace`, `log`, `on_refused`, `units`. The picture `W` is the consumer's; the engine reads a few fields of it, all optional.
- **The memory is wired by the engine:** `jcore.cast.sent` for the owner, `UNIT_SPELLCAST_SUCCEEDED` / `FAILED` / `INTERRUPTED`, `UI_ERROR_MESSAGE` (laid on the attempt, journalled, handed to `on_refused`), the channel events, `jcore.combat.leave`. `memory.attempt` takes `answer` (`arbiter`, `sent`, `done`) for a kind that answers at once.
- `JCore.react`: `new`, `for_owner`, `remove_owner`, `engines`, `stats`, `latch`, `new_memory`, `ROTATION_SCORE`, `MODE_MODS`, `CONTEXT_MODS`. `diagnostics().react`; a "reactions:" line on the Core page's cost readout while an engine exists (one more footer row).
- The README's *Reactions (1.8.0)* section documents the shape of a rule, the pipeline, validation, the memory and the hooks.
- Tests: new `jcore_react_test` (12).
- Not yet seen in game.

**Fewer line-of-sight rays: the Forlorn Rowe crashes.** The user: "I keep crashing". Forever crashed twice on 2026-10-11 in Forlorn Rowe, Duskwood (WoW's `Errors/2026-10-11_13.55.38` and `14.05.49`), both with the client's own `ASSERT(m_data)` in `M2HitTest.cpp`, inside a line-of-sight ray from the player to a mob that a plugin asked for. The registers in the reports hold the two ends: once the mob being fought, 30 yards off; once a mob 58 yards off with nothing targeted. A plugin cannot catch an assert in the client, so the core now casts far fewer rays.
- **`spells.castable` on Forever asks once per target per tick**, whatever spells are asked about. Every spell cast its own ray before: a priority list of ten rules was ten rays at one mob each tick, and the reactions' checks added theirs. The README already said six spells on one target cast one ray; now they do.
- **`draw.unit_los` keeps a unit's answer for half a second**, not one frame. It only fades a mark behind a wall, and re-asked every frame it was about 97% of every ray the API recorder ever saw (the world layer's fade, up to eight rays a frame). A mark now fades up to half a second late; `set_los_budget(0)` still switches it off.
- Nothing that gates a cast changes within a tick. The crash itself is the client's; fewer rays is fewer chances at it.
- Tests: `jcore_forever_test` (2 new: five spells on one mob make one ray and the next tick asks again; the fade asks twice a second).

**No model rays on Forever: the client's `is_line_of_sight` is never asked there.** Fewer rays was not enough: Forever crashed twice more in Shadowglen, Teldrassil, as a druid (`Errors/2026-10-11_14.29.27` and `14.50.01`, the second after the change above), the same `ASSERT(m_data)` in `M2HitTest.cpp`, the same ray from the player to the mob (the selected one, 18 and 27 yards). All four reports are on build 70338, which the client patched itself to at 00:45 that night; none on 70170, 70205 or 70291 has it, through millions of the same rays in the API recorder. `M2HitTest` is the client testing a ray against a model (a tree, a rock, a unit) whose data has not loaded.
- **`geometry.sight(from, to)`**: true, false or nil (unknown). On Forever a `trace_line` through buildings and terrain only, a building's own doodads ignored (`WmoCollision + Terrain + IgnoreWmoDoodad`, read from `enums.collision_flags` where the loader has them): no model is tested. trace_line's boolean is calibrated first, as the walk map's is -- a ray down from the player's chest must hit, one straight up must not -- and until both agree the answer is nil; never the native. Kept 0.2 s per pair. Every other client asks `is_line_of_sight` as before.
- **Everything asks it:** `draw.unit_los` and `draw.los` (unknown paints the mark), `spells.castable` and `spells.in_line_of_sight` on Forever (unknown leaves the cast to the client), `geometry.line_of_sight` on Forever.
- **What changes in play:** a tree or a rock no longer counts as blocking sight; the client refuses a cast at a mob behind one ("Target not in line of sight"), which the refusal memory already handles. A wall fade or a cast gate may be a fifth of a second late.
- `geometry.sight_stats()` (calibrated, the boolean, rays cast, the mask); `geometry._reset_sight()` for the tests.
- Not changed: the walk map's wall rays still include doodads, since trees and rocks are what it maps; only Market's mail errands and the walk map overlay ask for them.
- Tests: `jcore_forever_test`: a trace_line answering as Forever's, and a native that fails the test if asked -- the melee gate, the one-ray-per-tick test and the fade test go through it; the mask has no doodad or entity bit; calibrated with true as a hit; `in_line_of_sight` asks the same ray; an unknown answer paints the mark.
- Not yet seen in game.

## 1.13.1 (2026-10-08)
**The walk map knows furniture.** The user, in Lakeshire's inn with *Show walk map* on: "see how its not marking these rails as u cant walk through it yes u can walk ontop of it but not through it". The overlay had painted the table tops as ground and left the benches and rails unmarked. Three causes, three fixes (`services/walkmap.lua`):
- **Slopes and steps.** A rise of up to 1.2 yards a yard (1.7 on a diagonal) was taken as a climbable slope, so a table top a yard up read as ground you could walk onto. Now a rise of more than 0.45 between two cells is halved up to three times to see whether it is spread out (a slope, still walkable to about fifty degrees) or all at once (a step: a table, a bench, a counter, a cliff). A step is never walked up -- the reason is `ledge` -- and it is kept on the edge between the cells, so the top is still somewhere to stand, walk along and step off.
- **Rays at walking height, and a shin ray.** The wall rays followed the ground the map had measured, which on a table was its top, so they rode up over the furniture. They now follow the line the character would walk (not up a step), at shin (0.35), knee and chest height; 24 rays a tick, up from 16.
- **What a ray hit.** A hit near a table top was excused as "the floor". Each hit is now probed just past it: nothing near its height is a wall; a top more than a step above where the ray came from is furniture -- a wall mark when it is narrower than a cell (a rail, a bench, which the cell centres miss), the ledge when it is wider; the floor rising smoothly into the ray is a ramp or a stair. A top whose cell had not been measured yet is left for the next sweep, and a wide top clears any old wall mark on it.
- The overlay paints the tops of steps deep orange (the old orange "edge" was paint only, and blocked nothing). `cell(pos).ledge`, `stats().steps`, and a step count on the Core page's walk map line.
- Tests: `jcore_walkmap_test` 24 (4 new: the inn's table, narrow bench and threshold; standing on the table; the walker round both; a building's ramp and stairs and a hillside staying walkable).

## 1.13.0 (2026-10-08)
- **`curtain_3d` grows four options.** `fill` (0..1): a see-through sheet of `triangle_3d_filled` between the rings, that strong at the bottom and fading to nothing at the top (skipped on a client without the call). `lines = false`: the sheet alone. `lod`: fewer points with distance from you, full detail out to `near` (20 yd), never under 10. `cull_height`: drawn while its top is on screen too, not only its foot.
- **`draw.beacon_3d(pos, color, opts)`:** a tall thin pillar of light to find a place or a far unit by: a narrow filled curtain (12 yd by default, `lod` and `cull_height` on) and a soft glow on the ground at its foot. Options: `height`, `radius`, `to`, `fill`, `glow`, `points`, `thickness`, `time`, `layer`, `droppable`.
- **`draw.pulse(at, color, opts)`:** a ring that opens out and fades for something that just happened. Fire and forget: JCore draws it on the frames that follow (in its flush), at a place or under a unit it follows. Options: `life` (0.7 s), `from` (0.6 yd), `to` (2.4 yd), `inner`, `layer`. `draw.pulse_count()`. At most 32 play at once.
- `draw.with_alpha(color, mul)`.
- Jambix AIO 1.87.0 is the user. Tests: 4 new in `jcore_draw_world_test` (the sheet, distance detail, a beacon whose foot is off screen, pulses at a place and on a unit).

## 1.12.0 (2026-10-08)
**The walk map** (`services/walkmap.lua`, `ctx.walkmap`). The user: "a System that allows you to map out the world even if its small Radiuses...like 20yard so it knows whats infront and not to go through it due to like an object or its blocked". A grid of one-yard cells round the player, 20 yards by default (up to 40), kept as the player walks and dropped on a zone change.
- **Five sources:** ground height probes chained cell to cell (too steep, a drop, a hole); deep water from the `{ water = true }` probe; wall rays at knee and chest height fanned out from the player, against buildings and doodads only; every nearby game object as a cost (rays miss stoves, chairs and benches, per the API); and stuck spots -- the character pushed forward 0.6 s and did not move -- saved per map in `scripts_data/jcore/walkmap.json` and cleared when the player is seen within half a yard of one. Roots, stuns, casts, swimming and flying are never taken for walls.
- **Rays calibrated, not trusted:** `native_intersect` and `trace_line` had never been called on Forever. A ray down under the player must hit and one at the chest must miss before any wall counts; the argument order, the meaning of `distance` and `trace_line`'s boolean are found that way, and the first hits are re-checked so a far-face hit flips the order. Without a working ray call, walls come from objects and stuck spots, and `rays()` says so.
- **Queries:** `ahead`, `probe`, `around`, `free_side` (which way round), `clear_line`, `steer`, `path` (A* round what is known; unprobed ground passes at a cost), `cell`, `blocked`, `mark`, `forget`.
- **The walker:** `walk_to(goal, opts)` faces the next waypoint and holds forward behind the movement lease (the `look_at` + forward that moves the character on Forever), re-plans as the map fills, cuts a corner only when the next leg is clear, jumps and re-plans when it stops getting closer, and ends `arrived`, `preempted`, `no way through`, `no progress`, `timed out` or `stopped`. A plugin's walk and its scan request go when it unregisters, and every walk stops on death.
- **Cost:** nothing is cast until something asks (a request, a walk, a query in the last five seconds, or the overlay); then at most 16 rays and 16 height probes a tick under a 1.5 ms cap.
- **See it:** *Show walk map* on the Core page (World) paints walls, stuck spots, ledges, water and objects, the line ahead and the route; a walk map line joins the frame-cost readout.
- **Windows snapped back while dragged.** With *Capture the mouse over windows* off (JCore > UI), a drag reached the game, which took the held button for a camera turn, hid the cursor and re-centred it near the screen's side, and the window went back with it. The title bar, the resize grip and any drag now always take the mouse; the setting still lets clicks on a window's content through. Tests: jcore_boot_test ("Capture the mouse over windows off..."), market_test ("the window follows a drag by its title bar on every tab...").
- Not yet seen in game: every ray and water answer above is from the API's documentation and the offline tests. Tests: `jcore_walkmap_test` (new, 20).

## 1.11.0 (2026-10-08)
- **`draw.ring_3d(center, radius, fraction, col, opts)`:** a flat ring on the ground that fills. One `core.graphics.render_circle_percentage_3d` (an SDF quad: soft edges, a band all the way round, the fill shading from `col` to `opts.to`) where the loader has it and the shader switch is on; otherwise the band as a `circle_3d` and the fill as `circle_3d_percentage` in the colour it has reached. A call that raises is warned about once and the outlines are used from then on. Options: `bg`, `to`, `inner` (0.70), `outer` (0.98), `start` (-pi/2), `direction`, `softness`, `thickness`, `layer`, `droppable`.
- **`draw.curtain_3d(center, radius, col, opts)`:** a rippling curtain of lines standing on a circle, the wave of Lemons' Aurora Systems built for many at once: worked out once per call, one colour per ring, one submission. 4 rings of 36 points with a vertical every third point is 180 `line_3d` calls (Aurora Systems' defaults are 1,020). The base stays on the ground. Options: `height`, `points`, `rings`, `verticals`, `folds`, `vfolds`, `wave`, `vwave`, `speed`, `spin`, `to`, `thickness`, `fade`, `time`, `layer`, `droppable`.
- **Windows no longer snap about while dragged.** On a frame where the client has no cursor, `get_cursor_position` answers -FLT_MAX on both axes (seen in the recorder). The UI took that as a position, so a dragged window was clamped to the top-left corner and jumped back under the cursor on the next frame. Such a frame now keeps the last position. Mouse capture is also re-asserted every frame of a drag, not only when it changes, so the game never sees the held button and turns the camera. Test: `jcore_boot_test` ("a cursor the client cannot report...").
- `draw.blend(a, b, t)`, a colour part of the way to another. `draw.shaders`, set by the JCore/UI page's switch, now *Shader drawing* (same id, `shaders`): windows and world rings together.
- Jambix AIO 1.85.0 is the user. Tests: `jcore_draw_world_test` (new, 8); 1 new in `jcore_boot_test` (the drag).

## 1.10.0 (2026-10-08)
- **Shader-drawn windows.** Where the loader has them, the overlay UI draws with its `core.graphics.render_*` SDF calls: window and popup shadows (`render_drop_shadow`, soft, instead of a hard offset copy), title bars, labelled separators and switches that are on (`render_linear_gradient`), the hovered switch row (`render_hover_pill`, eased), slider tracks (`render_slider_track`) and dropdown fields (`render_dropdown_field`). The JCore/UI page's switch turns them off: the plain shapes of 1.9. A client without one of the calls gets the plain shape for that call alone; a call that raises is warned about once and not used again until a reload. New theme keys `shadow_soft`, `title_glow`, `accent_lo`, `accent_hi`, `pill`, `streak`, `header`, `clear`; `ui.shader(name)` and `ui.paint.shadow / gradient / pill / slider_track / field` for widget code. The drop shadow's quad (the window grown by blur and offset, the window's size as the element) is unseen in-game: the first thing to adjust if it looks wrong.
- Tests: `jcore_ui_shader_test` (new, 7).

## 1.9.0 (2026-10-07)
- **The 2026-10-06 core is known, and what it fixed is used.** Nothing reports a core's date, so `world.client()` tells it by the functions it added (`core.get_server_time`, `core.quests.get_quest_log_quest_ids`, `core.character.get_xp`): new flags `core_20261006` and `quest_ids` (the quest-ID readers `get_quest_log_quest_ids`, `get_quest_objectives`, `is_quest_complete`). On that core `cancel_buff` and `completed_quest_list` are true on Forever (and the completed list on Retail): the core now reads the client's newer names there. `classic_quest_log` stays false on Forever: the core answers the log there now, but its leader boards are undocumented for Forever, so the quest-ID readers are what to use.
- **`input.cancel_buff` reaches the native on Forever** on that core. Before, it answered false without calling it, which was right only while the native looked auras up through UnitBuff.
- **`questdb.is_complete()` on Forever never said yes.** It compared Questie's answer with `true`, and Questie answers 1 / 0 / -1. It asks the game first on the new core (`core.quests.is_quest_complete`), then Questie, with `1` meaning complete.
- **`questdb.questie().is_quest_complete` answers Questie's 1 / 0**, not `true` / `false`, as the facade's "same calls as the Questie bridge" promised. A caller written for Questie's `1` never saw a complete quest through it (Jambix AIO's Forever quest log).
- **`questdb.active()` on Forever is the game's list** on the new core: no is_on_quest sweep. A quest under a collapsed header (the list shows only visible rows) is kept while `is_on_quest` says you are on it.
- Notes brought up to date with the new `.api`: threat `status` and `is_tanking` (both were wrong on the classic builds before that core; the board's fallback did the work), `get_group_role` (answers on every client; the Forever party-row read is kept), the Skill window on Forever (`player.skill()`'s "skill" source), the completed quest list, the game Lua bridge's quest reason.
- Jambix AIO 1.82.0 is the user. Tests: `jcore_forever_core_test` (new, 5: the flags, `cancel_buff` reaching the native, `active()` from the game's list with a collapsed header and an abandon, `is_complete()` and the facade's 1 / 0); `jcore_forever_test` asserts both new flags false on an older core.

## 1.8.12 (2026-10-05)
- **Counted combo points are kept through a target change.** `services/power.lua` zeroed them whenever the target's guid changed. Forever's guides say combo points no longer drop when you change target (Mobalytics' rogue guides; Icy Veins has them staying put), so a rogue or a cat that switched lost points it still had, and its finisher waited for nothing. They are kept now; ten seconds out of combat still empties them.
- **"That ability requires combo points" means none.** The client's red text sets the count to 0, the downward half the counter lacked (a finisher the client calls usable still means at least one). Were the guides wrong about target changes, the first finisher on the new target is refused with that text and the count follows.
- Jambix AIO 1.80.0's rogue and druid are the users. Test: `jcore_power_test` (a new target keeps them; the red text empties them).

## 1.8.11 (2026-10-05)
- **`loot.take_window()` takes slots 0 to the count minus 1.** It took one more, for a client that counts from 1, on the reasoning that the extra slot does nothing (1.8.8 kept it so). On Forever it does not: the loot study (2026-10-05) read every item at 0 to count - 1 and nil at the count, and `loot_item` raised "specified invalid slot" for that slot, 14 of 54 calls. The `.api`'s 0-based contract was right.
- Jambix AIO 1.78.2's loot window pass is the user. Test: `aio_forever_loot_window_test` (the fake client raises past the window).

## 1.8.10 (2026-10-05)
- **A window's own scale.** `scale = 1.25` in a window's options draws that window at the global *UI scale* times 1.25: its title bar, padding, widgets and text, the lists its dropdowns open, and its tooltips. Every other window keeps the global scale, which is put back when the window ends. It is how a window offers its own text size.
- `ui:metrics().scale` is the scale in force where it is asked. A number given as a text size follows it.
- New `ui:set_size(id, w, h)`: sets a window's size and remembers it, like `set_position`.
- Jambix AIO 1.78.1's Reactions window is the first user. Test: `jcore_boot_test` ("a window's own scale: ...").

## 1.8.9 (2026-10-05)
- **Scroll regions (`ui:scroll`) can be dragged.** A press on the thumb holds it where it was taken. A press on the track centres the thumb on the cursor, and the drag goes on from there. The thumb lights up under the cursor. The bar takes the press before the content does, so a press on it never also reaches a widget beneath it.
- **The wheel goes to what is inside a region first** (a code box, a list, a nested region). The region scrolls only when nothing inside took the wheel, as a window body always did. Before, the region scrolled first and a code box inside scrolled too, so both moved at once.
- A region whose content fits it to within a pixel shows no scrollbar (floating point made one appear for a region sized to fit).
- New `ui:avail()` -> x, y, w, h_left: where the next widget goes, and the room left below it, down to the bottom of the enclosing scroll region or window body. A pane that fills the rest of a resizable window asks for `select(4, ui:avail())` as its height. New `ui:metrics()`: pad, gap, row, title_h, scrollbar and the font sizes at the current scale.
- A resizable window is kept within the screen and at least its `min_w` / `min_h`. That covers a size saved on a larger screen and a drag past the edge.
- Jambix AIO 1.77.0's Reactions window is the first user. Test: `jcore_boot_test` ("scroll region: fills the window by ui:avail, ...").

## 1.8.8 (2026-10-05)
- **`is_tap_denied` is read the way the contract types it.** `scripts/.api` says it answers a number; Forever's client answers a boolean. `loot.lua` took only `true`, so a `1` from a build that keeps to the contract counted as nobody's mob, and its corpse as ours to loot. Now `true` or any non-zero number is somebody else's tag. That holds in `loot.tapped()` (the 2 s poll per hostile) and in `loot.corpse()` (the direct read), the same way Jambix AIO's ESP (`esp/classify.lua`) already read it. Jambix AIO's targeting, Reactions and Forever ESP get it through `loot.tapped` / `loot.corpse`.
- Unchanged on purpose: `take_window()` still takes slots 0 to the count inclusive. Under the `.api`'s 0-based contract the extra slot does nothing, and it covers a client that counts from 1.
- Test: 1 new in `jcore_names_loot_test` (a `1` is tapped, a `0` is not, a corpse with loot that answers `1` is not ours). It fails on 1.8.7.

## 1.8.7 (2026-10-05)
- New `ui:code(id, default, opts)`: a multi-line code box. Returns the text, whether it was edited this frame, and whether it has the keyboard. Enter breaks the line and keeps its indent, Tab puts in four spaces, the arrows walk the lines (Up and Down keep the column), Home/End, Backspace and Delete join lines, Ctrl+A / C / X / V, Escape gives the keyboard back. A click places the caret; the wheel scrolls; the caret is kept in view both ways.
- Lua is coloured (keywords, strings, numbers, comments) and so are the names in `opts.words`. Line numbers in a gutter (`line_numbers = false` hides them). `error_line` marks a line red and `error` writes the message under the box. `disabled` makes a read-only view. `rows` / `h` size it.
- Up and Down are polled while a field has the keyboard (only then, as before for the other keys).
- First user: Jambix AIO 1.76.0's Reactions window (Lua conditions, actions, the Library).
- Tests: 1 new in `jcore_boot_test` (clicks the box, types, Enter, Up, Home, Backspace across a line, Tab, Escape) through the real toolkit.

## 1.8.6 (2026-10-04)
- New `creatures.beast(npc_id)`: `{ tameable, family, type, name, classification }` from the client's creature cache, on Era as on Forever. Tameable is the type flags' bit 0 (CREATURE_TYPE_FLAG_TAMEABLE). On Era the file is read the first time it is asked, never before.
- Era's cache layout (build 70003) is read now. It has one more header bit after the cursor length and one more u32 before the display count. The layout is chosen per file by which one more of its first records hold to. All 977 records of the user's Era cache hold; Forever's 70205 file keeps its layout.
- On Era `info`, `name` and `classification` still answer nil, so no Era name or rank changes. `stats().layout` says which layout was read.
- Tests: the real Era cache is a fixture now (`tools/jtest/mock/fixtures/era_creaturecache_70003.wdb`); 1 new in `jcore_creatures_test`, 1 new in `jcore_era_client_test`.

## 1.8.5 (2026-10-04)
- New `player.skill(key)` for skinning, herbalism, mining and fishing. Returns the skill (gear bonus included), how it was read, and the most it can be now. Answers are kept five seconds, since skill rises with use. Sources, first that answers:
  - `profession`: get_professions + get_profession_info. Never recorded on Forever yet.
  - `skill`: the Skill window's line (Era, TBC).
  - `rank`: the highest rank in the spellbook. Its cap stands in for the skill.
- New `player.skin_required(level)`: the game's rule (1 up to level 10, then 10 a level to 100 at 20, then 5 a level).
- New `player.can_skin(level)`: answers yes or no, plus what the corpse needs, the skill compared and its source. A level that didn't read is never a no.
- Tests: `jcore_player_skill_test` (5).

## 1.8.4 (2026-10-04)
- Fix (Forever): items you had sold still counted as taking bag slots, so "Stop when bags are full" could stop fishing too early.
  - inventory_helper lists the merchant's Buyback items as backpack slots past the backpack's real size. 1.8.2 used the helper's own free-slot total, which counts them.
  - Free slots are now each bag's size minus the helper's rows that sit inside it. The `inventory:` trace line says how many rows were left out.
- New `inventory.bag_rows()`: the helper's rows that sit inside the backpack and bags, plus the number left out and the total capacity. Lets other code skip Buyback rows the same way.

## 1.8.3 (2026-10-04)
- Fix: spell icons printed `[ERR] icons_helper: wowhead spell lookup failed, code=403` in the console.
  - The loader's `icons_helper` reads www.wowhead.com, which refuses it (403 for every id, and for a plain request too). Icon names now come only from Wowhead's tooltip service.
  - `draw.spell_icon` goes through the assets (`spell:<id>`) instead of the helper, which never drew anything in the game.
- Fix (Forever): Forever's own spells had no icon ("no icon name for spell 1278067", Bait and Tackle). Wowhead's Forever data (dataEnv 16) is now asked first there, then Classic, then live.
  - An id that no data knows is given up on quietly, without a warning. A lookup that could not reach Wowhead is retried later instead of given up on.
- Quieter boot on a loader that cannot read the game archives. The reason is said once, at info; when it is the same as last session's, it goes to the debug log. The assets' "art from the game's archives is not available" line is debug too.
- `gamelua`: when the last session's `jcore.gamelua.json` says the bridge failed, the probe runs once and quietly instead of three times aloud. A bridge that answers is still announced, and the Debug page's "probe again" still does all three.
- Tests: new in `jcore_forever_test` (icons), `jcore_gamelua_test` (3), `casc_test`; `aio_esp_perf_test` pins no warning.

## 1.8.2 (2026-10-04)
- Fix (Forever): `inventory.free_slots()` / `is_full()` were wrong there.
  - Forever sends no bag events, so the bag walk was kept until the next gear change. On Forever every bag answer now expires after 1 s.
  - Bag 0 there is the player's whole item array (worn gear and sold items too), so the slot count counted far too much. On Forever free slots now come from the loader's `inventory_helper`, with the old count as the fallback. Each new answer is an `inventory:` trace line.
  - Era and the other clients are unchanged.

## 1.8.1 (2026-10-04)
- Fix: picking a row from a dropdown's list never counted as a change, so windows that mirror a setting put the old value back.
  - It broke the class window's pet mode, its other option dropdowns, and its pick lists (aura, seal, armor, shield, Shadowform), plus JCore's menu mirrors.
  - The pick is now reported on the next frame.

## 1.8.0 (2026-10-04)
- New `services/telegraphs.lua` (`ctx.telegraphs`): live telegraphs from enemy casts, missiles, ground left behind, DBM hazard auras and (Era) combat-log hits. It provides `active`, `on_me`, `danger_at`, `covers` and `info`, and the events `jcore.telegraph.started` and `jcore.telegraph.on_me`.
- New core stage "telegraphs" after missiles. The Core page has a `telegraphs:` line.
- Data in `scripts_data/jcore/telegraphs/{vanilla,forever}`, from the new `tools/jcheck/telegraph_extract.js`:
  - the game's own spell tables, read offline through the new `lib/casc.js` and `lib/db2.js` with WoWDBDefs;
  - DBM's classic mods;
  - Plater's cast scripts.
- Tests: `jcore_telegraphs_test`.

## 1.7.0 (2026-10-04)
- Recorder, Dump and loot study moved to the Jambix Debug plugin, found at boot or attached late (JCore.attach_debug).
- The 1.6.11 and 1.6.12 loot experiments removed.

## 1.6.12
- Experiment: use_object as a third corpse call (removed in 1.7.0).

## 1.6.11
- Experiment: target the corpse before pressing (removed in 1.7.0).
- New jcore.loot.nothing event.

## 1.6.10
- Forever: a duplicate LOOT_OPENED within 0.5 s is ignored. It used to mark another corpse looted.

## 1.6.9
- loot.corpse follows has_loot once it has answered, so empty corpses aren't pressed.

## 1.6.8
- Loot study (services/lootstudy.lua): corpse flags and how loot windows open, on every client.

## 1.6.7
- After a walking press, press again from beside the corpse after 0.5 s.
- Recorder sweep trace limited to 100 yd.

## 1.6.6
- Forever damage meter probe, with enemies.meter_summary().

## 1.6.5
- The loot call that last worked goes first, alternating with the other per corpse. Skin tries are counted apart.

## 1.6.4
**Forever enemies:**
- damage_rate from your health;
- control from debuffs;
- threat proven unread (enemies.threat_readable).

## 1.6.3
- A loot window more than 8 s after a try goes to the nearest corpse.
- A window within 2 s of a gather or skin cast belongs to that cast.
- A skinned corpse is done.

## 1.6.2
- loot_object tried first, pressed once and waited on.

## 1.6.1
- ctx.loot.open and ctx.loot.opening: on Forever the calls alternate until one opens. "loot:" trace lines.

## 1.6.0
**Every Forever quirk is answered in JCore:**
- world.client() flags;
- names service;
- classification from the creature cache;
- loot service;
- power service;
- shapeshift_index;
- channel_spell_id;
- spells.learned.

**Also:**
- Quest database (ctx.questdb), extracted from QuestieDB.
- Dump page.

## 1.5.16
- ctx.gamelua bridge to the game's Lua, Forever only. The probe failed, so it's dormant.

## 1.5.15
- ctx.creatures: the Forever creature cache (creaturecache.wdb), giving name, title, type, rank and quest drops.

## 1.5.14
- Forever pet lookup (units.player_pet): minions, then is_pet and owner.

## 1.5.13
- Forever party roles from the party rows.

## 1.5.12
- API recorder format 2.

## 1.5.10
- Forever castability checked by JCore itself. Before, the loader's spell_helper called every spell uncastable.

## 1.5.7
- Forever GCD read from a no-cooldown spell.
- Impossible channel ids answer nil.

## 1.5.4
- Forever API recorder.

## 1.5.3
- Game art fails for good when the archives can't be read.
- time_to_die samples bounded.
- Sweep facts reused: about half the native calls per frame.
- Each tick stage runs under its own guard.
- Cast lanes handed out per decision.
- Projection cache bounded.

## 1.5.2
- CASC reader tries other roots and saves a diagnosis to jcore.casc.json.

## 1.5.1
- Client folder detection prefers the running client's folders.

## 1.5.0
- Threat service on its own budget.

## 1.3.1
- Never sends a nil tint, which made portraits invisible.

# Jambix Debug

## 1.1.0 (2026-10-11)
**The black box at the character select screen (2026-10-12).** The context line no longer asks for the map and zone names while JCore waits for the world: those natives read tables the game has not loaded at that screen, and the line ran in the first update pass of a load there, before the "> update" mark (`last_context` starts at -1e9). New marks: "G waiting for the world (the character screen)" and "G in the world: the passes start". A box that ends on the first one died before any of our passes ran.

**Faults: every error, native raise and nil, logged on the hit, and a black box for the crash with no report.** The user, after an evening of "Fatal Error: Your game crashed" popups with nothing in WoW's `Errors/`: "add to the Debug All Captures of anything we running thats going Null, or Crashing us for any Error whatso ever and log it on the hit so we can fix it/report it".
- **New page, Jambix Debug > Faults** (`services/faults.lua`), built by JCore before the recorder. It listens on JCore 1.8.1's `rt.faults` and writes to `scripts_data/jcore/jambix.debug.faults.log`.
- **Each fault is written in full on its first hit:** ERROR (a job, timer, handler or stage raised), NATIVE (a native raised, even when the caller's pcall swallowed it), NULL (a native went nil after answering values, once per call site), SWALLOWED (cache.try), LOG (warn and error lines). An entry has the traceback, the locals where it raised, the job and its file:line, what was running, and where you were (zone, position, combat, target, units, fps).
- **Repeats are counted**, and written again at the 2nd, 10th, 100th... hit. A summary by count goes to `jambix.debug.faults.summary.txt` every 30 s.
- **The crash black box.** Marks are written ahead of the work to `jambix.debug.blackbox.1.txt` and `.2.txt`, so a game killed outright still leaves the last thing it ran on disk. Levels: off, once a second (context), every pass (default), every job and handler (heavy). The box steps down by itself when it costs over 60 ms a second.
- **At the next start, a CRASH entry:** when the session that never logged out died, and the passes still open then.
- **The recorder's watch.** Its wrappers stay in with *Record calls* off, and every call goes through a pcall. A raise is handed over and raised again untouched; a nil after values is handed over once per site. The first answers are searched for game objects, so their methods are watched too. New: `recorder.set_watch`, `watching`, `watch_stats`.
- Page switches: *Catch errors*, *Watch every native call* (Forever), *Crash black box*, *Write the summary now*, *Clear the fault log*. The live lines show counts by kind, the watch, the box's cost, how the last session ended, and the newest faults.
- Not caught: a plugin's own `pcall` round its own Lua code (the global `pcall` is not replaced: the loader attributes calls by walking the stack), and the loader's packed code.
- **The Dump page's click-to-move probe is gone.** It called `core.input.cm`, which is not in .api (2026-10-12: "if its not in the .api remove it from game calls"). `jcore_dump_test` now checks that nothing calls it.
- Not yet seen in game. To check there: the box's cost on the page at *Every pass*, and that a crash's next start writes the CRASH entry.

## 1.0.0 (2026-10-04)
- First release, not shipped to players: the API recorder, Dump page, loot study and the AIO Debug page, moved out of JCore and Jambix AIO.

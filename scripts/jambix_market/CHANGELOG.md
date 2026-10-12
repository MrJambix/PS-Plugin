# Jambix Market changelog

## 1.2.5 (2026-10-12)

The user, after a look at the formulas and the books: "yes" to both changes, "and then clean the
data so we can start fresh again".

- **Vendor flips are harder to buy.** They were 100% sure by construction, so the Kelly share
  handed them a lot of gold for pennies: 229 Murloc Eyes for 3s 13c, 77 Boar Intestines for
  77c, piles that sat in the bags for days (3g 22s waiting to make about 40s). Now:
  - at least 15% under what the vendor pays (was 5%);
  - a full stack must make 2s at the vendor (`pricing.vendor_stack_pays`), so an item earning
    a few copper a unit is never bought however many are listed;
  - at most a fifth of capital in vendor flips at once (`policy.vendor_room`);
  - four bag slots are always left free;
  - a vendor flip that is big money on its own (a certain +10g) skips the last two: it is held
    to the deal share like any big deal.
- **Posting comes before buying.** Stock that came back by mail is posted the moment the
  auction house is open, before gold goes into new deals (Thick Spider's Silk had sat unposted
  for four days).
- **Data cleared** at the user's request (backed up first): prices, scans, gear rolls, ledger,
  journal, policy, posts, errands and presence. Prices need three scans over an hour again;
  the confidence bar starts at 99%, the cut at 5%, the deposits at Forever's known rates.
- Tests: the vendor rules (margin, stack floor, capital cap, bag room).
- **Starts only once a character is in the world.** On 2026-10-12 the loader started the
  plugins at the character select screen, and the game died 0.2 s later (`ASSERT(IsLoaded())`,
  a game table read before the game had loaded it). The start-up now waits on JCore 1.8.1's
  `JCore.in_world()` as well as on JCore itself.

## 1.2.4 (2026-10-11)

The user: "I think the Auto has minor Wizard oil incorrectly being read??? check log".

- **The bug**: an item search answers one ROW for several identical auctions ("75 Minor Wizard
  Oil, 4s"), and its price is the price of ONE. Auto read it as 75 oils for 4s, bid 4s, got one
  oil, and booked 75. Twenty bids booked 1,353 oils for 92s, "expected" to bring 67g at a
  vendor, and the same misreading bought a Woolen Reagent Bag for 4g (read as 14 for 4g), two
  first-aid manuals for 2g 95s and six recipes for 52s, all "for a vendor" paying 50s, 25s and
  2s 50c. About 6g lost, out of 7g.
- **Fixed**: a row of more than one is read as that many auctions at that price each, and a bid
  takes one of them. A resale against a row like that competes with the rest at the same price
  (so none is planned); a vendor flip of a 4s oil makes 1s and is under the floor.
- **The books repaired once**: every buy of a single item (stack 1, not gear) is one unit a
  bid; the holdings are rebuilt from the rows, the cost as paid. On the user's ledger: oil
  1,353 → 20, recipes 49 → 6, the bag 14 → 1, manuals 49 → 2.
- **Recovering the loss**: a single item Auto bought for a vendor goes to the Gear tab's "Post
  these yourself" when the auction house pays more than the vendor, instead of being sold to
  the vendor. At the time: the bag listed at 3g 56s (a vendor: 50s), the manuals at 1g 43s each
  (25s), the recipes at 7s (2s 50c); the oils go to a vendor (5s against 4s listed). The Gear
  tab's buyout has no floor at what was paid: "If it sells" shows the loss or gain.
- **Mail**: an item back by mail is recorded when the mail leaves the inbox, not each time the
  loot is asked for. With the bags full, the same oil mails were asked for every five seconds:
  183 "Mail back" rows for 20 oils. Those rows do not count toward any total.
- **Tests**: a grouped search row buys one at the price of one (pricing and the trader); a mail
  looted at the fourth ask is recorded once; the books repair on a seeded ledger.

## 1.2.3 (2026-10-10)

The user: "Market should always be of and require us to turn it on".

- **Off at every load**: Market and AUTO are both put back off each time the scripts load,
  whatever was saved, so neither resumes by itself after a reload.
- **While off, nothing happens on its own**: no scans, no window opening with the auction house,
  no reading of your auctions, no gear reminder, no trading, no anti-AFK and no mail runs.
- **Still recorded while off**: your gold and the sale mails you take, so the lots of what Auto
  posted still settle.
- **Turning it on**:
  - The switch at the top of the settings page, or the window's one button: "MARKET IS OFF —
    click to turn it on".
  - Pressing AUTO turns Market on too.
  - Turning Market off turns AUTO off with it.
- **Shown everywhere**: the settings title and the first live line say whether Market is off, on
  (scanning), or on and trading.
- **Tests**: switches saved ON come back OFF at load; the window offers the button; every test
  boot turns Market on.

## 1.2.2 (2026-10-10)

The user: "let's take a look at If it's buying gear and weapons cause its not so far".

- **Why no gear was ever bought** (the user's files, 17:55): no single item could be found by
  the search a purchase makes.
  - A single item's search goes by its item key, which needs the ITEM level. Auto searched with
    the level the scan reports, which on Forever is the level to USE it (Edged Bastard Sword: 13;
    item level 18). It then retried with 0.
  - For 2,765 of the 2,909 single items seen, that found nothing. Only items whose two levels
    match (a Fishing Pole: 1 and 1) were ever found. The recorder shows no `place_bid` in any
    session.
  - Those empty searches also took gear deals off the list.
- **Fixed**:
  - A search tries the item level first, then the scan's level, then 0.
  - A search that found nothing of a single item is not believed over the full scan: the
    purchase's own search decides.
- **1.2.1 at work**: the latest scan read 100% of single items' links (89% before), 3,538 rolls
  have sales on record, and 956 can be judged. No gear deal today all the same: prices are
  still falling.
- **Tests**: the fake auction house now answers an item search only by its item level, as
  Forever does. The old search fails eight gear tests; the new one passes all 23.

## 1.2.1 (2026-10-10)

The user: "past couple hours still hasn't bought any deals for Armor/weapons".

- **Why nothing was bought**:
  - 1.2.0 compared gear sales only when a scan read 90% of single items' links. The user's 27
    scans read 89%, so no roll ever had a sale and none could be judged.
  - The same bar also held back all gear buying.
  - The recorder showed it: 112,934 of 1,053,324 link reads came back blank. None of Auto's
    bids reached the game, because none were made.
- **Fixed**:
  - Blank links are asked again after the read, up to three passes a second or two apart, and
    the client is asked to load each such item.
  - An item seen only without a roll (a blue, a bag) counts a blank-link auction as its one roll,
    and is judged on its whole price history (every sale since it was first seen).
  - Sales are compared item by item: only an item with an unread link (and more than one roll)
    is left out, never the whole scan.
  - No scan-wide bar on buying gear: each purchase's own search must still say every auction's
    roll, and it is searched once more when it does not.
- **What the user's own data says** (their files, 2026-10-10 09:09):
  - With the fixes, 836 rolls can be judged and 229 had an auction 25% or more under its usual
    price.
  - Still no deal today: 164 were refused by the crash check (several cheap at once) and 55
    had the next auction just above.
  - The gear market there is falling day by day (Silvered Bronze Leggings 99s → 97s → 88s →
    68s → 44s; Raider's Shoulderpads 30s → 11s): today's cheap piece is tomorrow's price.
  - Rolls with a suffix start counting sales from the next scan on.
- **Tests**: `market_gear_test.lua` 23 (blank links asked again, a roll-less item's blank link,
  no scan-wide bar). The missing-link test was strengthened: it now fails without the fix.

## 1.2.0 (2026-10-09) "Gear"

The user: "lets identify weapon and gear that we can Flip for price like the rest but we will
have to post it ourselfs".

- **Why**: Forever never takes `post_item` (the test plugin, `scripts/jambix_postprobe`, tried
  every form of it). Stackable goods post; a single item posts only through the auction house
  window.
- **Gear priced by roll**:
  - A full scan reads the link of every single item (weapons, armor, bags, recipes). The random
    suffix is a bonus id in it ("of the Monkey" apart from "of the Owl").
  - Prices, sales and deals are kept per roll in `jambix.market.<realm>.gear.json`, and the saved
    scan keeps each auction's roll.
  - Sales are compared only between scans that each read 90% of the links or more.
- **Gear deals, on the Deals list with the rest**, by the same bar, floor, size and big money:
  - half a day of selling is credited to a 48-hour post, because nobody reposts it;
  - each piece is one purchase and one 60%-of-vendor deposit;
  - the search before buying must say each auction's roll (never blind).
- **Auto buys them; you post them**:
  - At most two bought pieces wait for you. Gear buying stops if the game answers neither of its
    first two bids (`place_bid` is still unseen live), until Auto is switched on again.
  - Auto never posts, cancels or vendors gear it bought.
  - Your post of a piece Auto bought joins its lot, with the deposit measured from your gold.
  - The sale mail is matched by the roll's full name.
- **Gear tab**:
  - Post these yourself: each roll in your bags, Auto's first, with the buyout to type in, the
    cheapest other of the same roll, the deposit, and what it makes.
  - The gear deals, with a Roll column so a long name never hides the roll.
  - Cheap, but not sure enough: shown, never bought.
- **Elsewhere in the window**: the header lists "Post these yourself", a pop-up says it when the
  auction house opens, and the Auctions tab compares gear with its own roll.
- **Fixed, a latent bug**: a single item (a bag, a recipe) could be planned as an item-level
  resale, bought, fail to post, and then be sold to a vendor. Single items are now resold only
  as gear, by you.
- **Your own gear sales** now carry the item in the ledger (the mail's suffixed name used to
  match nothing).
- **On the user's real data**: of 2,255 single items listed, 170 were 25%+ under their usual
  price. Nearly all were the price falling (Raider's Shoulderpads: usually 24s 57c, all six
  listed at 12s), and the crash check rightly refused them. Gear deals will be rare.
- **Reviewed** (an independent review with repro probes; 7 findings, all fixed):
  - Gear Auto holds is a holding of its own ("id:roll", "13127:" for no roll). A vendor flip
    of the same item could otherwise take its place or turn it into a vendor flip, and a
    merchant visit sold the gear piece. Vendor selling also skips any slot whose roll Auto holds
    as gear, or whose roll cannot be read.
  - The two-waiting cap holds piece by piece: a purchase plans no more than the room left, and
    each bid checks it again.
  - Your post that leaves the auction house without being seen sold (you cancelled it, or it
    expired) is not a sale. Your repost is taken in with its own deposit.
  - Only your auctions made after Auto bought the roll are taken in as its pieces: made in this
    session after the buy, or with an auction id above the one it bought. A sale mail is Auto's
    only while one of its pieces of the roll is up.
  - A piece you keep, equip, bank or sell yourself is taken off Auto's stock as yours ("Yours
    now" in the Trade log). That happens when it is in none of the bags, your auctions or the
    mailbox, with the mailbox read since. It no longer counts as waiting forever.
  - Sales of an item's rolls are compared only when every listing of it had its link read in
    both scans.
  - Projected profit counts gear deals only while Auto may buy gear, and no more than the room.
  - Also: an endless loop (your auctions ↔ a roll's cheapest seller), found by the tests.
- **Tests**: `market_gear_test.lua` (22 tests: 16, plus 6 for the review). The window tests draw
  all eight tabs.

## 1.1.0 (2026-10-08) "Big money"

The user: "At what point should the equation be like I can make a lot of money here, not just a
few copper or silvers?"

- **Big money**: a deal expected to make at least 5% of capital (never under 20s) and 4 times
  its deposits, after the cut, its deposits and the chance it fails, judged at the size one deal
  may get now. Said in the activity list and popped up when bought; marked BIG on the Deals tab
  and the Overview; "big*" with what it needs when money is short.
- **Never bought**: a deal making under 5s, under twice its deposits, or under 0.1% of capital.
  The 5s learns from how far small lots fall short of their plan (90th percentile of the last
  20, from 5, capped at half the big-money line).
- **The half line**: smaller deals fill stock only to 50% of capital; 50% to 70% is kept for big
  money.
- **Order**: by expected profit a day on the gold tied up, instead of profit a day.
- **Honest deposits**: Forever's 48-hour deposit is 60% of the vendor price × units, at least 1s,
  charged post by post (it had been a flat median of past deposits: 1s 82c planned for a post
  that took 9s). The rate is learned from posts over 1s.
- **The auction house cut fixed**: a sale is read against the post that fits it (3% to 8%); the
  learned 4.3% (a sale read against an expired post) is reset to 5% once.
- **Two posts**: once ten purchases have sold out with at least 98% making money, a resale may be
  judged over two 48-hour posts (one day of selling credited each), planning two lost deposits
  and still profitable after four.
- **Cooldown**: an item whose lot lost money is not resold for 2 days (7 after two in a week).
- **Learned vendor days**: how long a vendor flip's gold waits for a merchant.
- **Watch list**: quick scans search the most valuable items a deal could afford, where big
  discounts show up.
- **Mail runs behind a checkbox**: "Walk to the mailbox and back to the auctioneer by itself",
  on the settings page and in the window, off by default (the pathing is being reworked). Off,
  you walk to the mailbox and Auto takes the mail when you open it; unticked mid-run, the run
  stops at once. JCore's obstacle map (`ctx.walkmap`) is no longer used.
- **Stream backtest** (`market_sim_test.lua`): 1.89g → 2.63g a day at 15 markets an hour, 3.09g →
  4.76g at 60, 100% of lots profitable in both.
- **Reviewed** (4 reviewers, each finding put to a skeptic; 1 of 18 refuted). Fixed:
  - the half line is held on the deal actually bought: a deal flagged big at an older look, or
    one that shrinks at the buy's own search, is held to what smaller deals may spend;
  - a lot's planned profit and the big-money message use the price actually paid;
  - "big once money is free" ("big*") now shows for deals that fit the money free;
  - no resale is planned before the client has told an item's vendor price (its deposit);
  - the Deals tab shows the deposits a deal was planned after (one per post);
  - planning about 2.6x faster (purchases counted, not units; the row walk stops once no
    dearer row can pay), with identical results;
  - the anti-AFK step is a sidestep each way (forward-and-back drifted about 11 yards an hour);
  - wording: "purchases" (not "resales") made money; the big-money line "at least 20s"; why
    smaller deals wait.
- Tests: `market_test.lua` 63 tests; `market_sim_test.lua` adds the stream backtest.

## 1.0.0 (2026-10-07)

First release. WoW Forever only.

- **Scans every 3 minutes** while the auction house is open:
  - a full scan (`replicate_items`, read in budgeted chunks) tried every 3 minutes. The
    server's own limit (15 minutes on retail; unknown on Forever) is learned from the scans
    it refuses, so refused tries are not repeated, and the cycle lines up with the moment a
    full scan is allowed again;
  - a quick scan of what matters when the server will not give a full scan: Auto's stock,
    your auctions, the deals, then the biggest-turnover items (80).

  A throttled full scan is not folded in. On Forever `REPLICATE_ITEM_LIST_UPDATE` fires on its
  own, so the list itself is judged: one that never moves from what the client held is thrown
  away unread, one identical to the last scan (auctions, units, value) is thrown away after
  reading, and one that changes while it is read is read again. Searches update prices and the
  usual price; the sales estimate compares full scans only.
- Each full scan is folded into a per-realm price history: market value, usual price,
  listings, sellers, and 14 days of daily rows.
- **Projected profit**, shown under the AUTO button, announced the moment Auto starts, and
  re-announced after every scan. It counts the deals Auto can buy, each planned again at the
  size Auto may spend, weighted by how sure each is, plus what its stock is expected to make.
  Beside it: what Auto's own trades have made since it started.
- Sales estimated from one scan to the next, using time-left bands to rule out expiry, with
  repricing, Auto's own purchases and Auto's cancels taken off.
- Deals: vendor flips, and resale flips priced against the next seller left after the
  purchase.
- **AUTO button.** Buys, posts what it bought, cancels and reposts undercut auctions it posted
  while that still pays, collects auction mail, and sells vendor flips at merchants. The
  window has no manual trading. Turning Auto off stops a job in progress at its next step.
- **Everything automatic; no settings.** What to spend and when is decided from your gold
  (`modules/policy.lua`):
  - capital = gold + stock at cost;
  - 10% always kept;
  - at most 70% in stock;
  - each deal sized by quarter Kelly from how sure it is, what it makes and what it could
    lose (chance taken two points lower first, at most half of capital);
  - least profit max(50c, 0.05% of capital);
  - deals ranked by expected profit per day to sell.

  The auction house cut is learned from sale mail, and the auction length is chosen from the
  sales rate.
- **Profit formula, reviewed for accuracy.** Every resale gets the chance it makes a profit
  (price risk × chance it sells in time), and is bought only at or above the confidence bar.
  Vendor flips are always sure. The review also added:
  - the 95% lower bound of the sales rate, with repricing not counted as sales;
  - planning against the cautious price and the market left after the purchase;
  - the price trend counting against a deal;
  - crash detection, where several sellers going cheap is the price moving;
  - stock already held counting against what can sell in time;
  - three scans over an hour required before a resale;
  - gear excluded;
  - bought stock never posted above the price it was judged at.

  The backtest (`market_sim_test.lua`, buyers taking several units, Forever's flat deposit)
  made money on 100% of 128 resales at 99%, against 79% for the original formula.
- **Self-tuning confidence bar.** Starts at 99%, and moves so that 98% of Auto's purchase lots
  make money once sold out, fees included.
- Purchases re-planned on a fresh search. A commodity quote is confirmed only if it is within
  what the plan may spend and what is free, still makes the least profit, and is still as sure
  as the bar.
- Every post and vendor sale is checked by item GUID within the bags. If the wrong item moves,
  that action stops for the session.
- Ledger:
  - gold by day (a 0 believed only after ten seconds);
  - purchases with the profit expected;
  - sales with the profit made;
  - fees;
  - stock held;
  - the profit on offer each day;
  - the success rate measured per purchase lot ("N of M purchases made money once sold"),
    beside what the purchases predicted.
- Fixes from the first live sessions:
  - a cancel counts only when `AUCTION_CANCELED` names its own auction (it also fires for
    auctions a purchase used up);
  - a search nobody answers no longer wipes the item's price;
  - an auction you listed by hand is never cancelled;
  - holdings bought by an early build get their lot rebuilt from the trades;
  - a day's low of 0 from a loading screen is repaired;
  - **sales counted in purchases, not units**: one buyer taking 53 is one sale, and how sure
    a resale is comes from the number of buyers and the units each takes;
  - **Auto's own purchases are never counted as sales**: read from the ledger at every scan,
    so a reload does not lose them, and repaired once in a price file that already counted
    them (53 of 60 Rockscale Cod "sold" were Auto's own);
  - a resale needs the item seen selling to other players: three purchases or more, in two
    scans or more;
  - **deposits**: learned from the gold each post took (1s flat on Forever), and each resale is
    planned after one lost deposit per stack; a repost must also pay for the deposit the
    cancel forfeits;
  - the window shows the stock Auto holds beside your gold, and "Today" counts it at cost, so
    gold spent on stock no longer reads as a loss;
  - **the trade journal**: every buy, sale, post, cancel, fee and mail return kept for good in
    `jambix.market.journal.json`, with exact all-time totals (invested, returned, cost of what
    sold, fees, profit made, still in stock, cash) and your own items' sales kept apart; the
    Ledger tab shows them, and a filterable Trade log;
  - **posts last 48 hours** (they had been 12 for fast sellers); deposits are learned per
    auction length;
  - **money waiting in the mailbox**: the inbox's sale mails last seen, plus auctions sold
    since;
  - **the Vendor tab**: every carried item a vendor buys, against the auction house and what
    was paid;
  - the window keeps a size you can change (bottom-right grip) instead of growing past the
    screen, so it can be dragged anywhere;
  - **mail runs**: with money waiting, Auto walks to the nearest mailbox (Sentinel
    Navigation), takes every mail but a COD one, walks back and opens the auction house
    again. Every walk is watched (replans when it gains nothing, stops cleanly when stuck,
    pauses runs 30 minutes); combat, death or Auto off end a run;
  - **mail runs walk for real**: Sentinel took the route and never moved the character in
    the user's game. A run now follows the way you walked it (learned from your own walks to
    the mailbox and back), else Sentinel if it moves you within 4 seconds, else straight at
    the mailbox, by facing and holding forward (what moves a character on Forever). Stuck: a
    jump and a sidestep, five times, then it stops and lets go of every key. Every run is
    logged in `jambix.market.errands.json`;
  - **staying active**: a keep-alive every 2 minutes while Auto is on (a turn, then a step,
    then a jump), learning from the game's "You are now Away" which kind works, and saying so
    when none does.
- Tests:
  - `tools/jtest/tests/market_test.lua` (Forever, 48 tests);
  - `market_errands_test.lua` (the mail run and staying active, in a fake world);
  - `market_era_test.lua` (Era, inert);
  - `market_sim_test.lua` (the backtest).

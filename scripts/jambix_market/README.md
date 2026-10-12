# Jambix Market

Makes money on the **WoW Forever** auction house. It scans the auction house, works out
what each item is worth and how fast it sells, and buys and sells when there is a profit.
It decides on its own what to spend and when, from your gold. It records the profit it
expected and the profit it actually made.

It runs on Forever only. On any other client it registers, shows one line on its page, and
does nothing. It needs JCore 1.7.9 or newer (the old 1.13.1: JCore was renumbered to match
project-sylvanas.net).

## Using it

**Market is off every time the scripts load**, and so is AUTO, whatever they were last time.
While off, nothing scans, opens, reads your auctions, trades, keeps you active or walks. It
still writes down your gold and the sale mails you take, so what Auto already posted settles in
its books.

1. Turn it on: the switch at the top of its settings page, or the **MARKET IS OFF — click to
   turn it on** button in the window (its key, or "Open the market window"). Then stand at an
   auctioneer and open the auction house. The **Jambix Market** window opens with it. Drag it by
   its title bar; resize it from its bottom-right corner (it keeps the size you give it and
   scrolls inside).
2. Press **AUTO** (which turns Market on too, if it is still off). Straight away it shows the **projected profit**: what it has found it can
   make (see below). It then:
   - scans the auction house every 3 minutes;
   - buys the best deals, sized from your gold (see "Money");
   - posts what it bought, except gear: the game will not let it post a weapon, a piece of armor
     or any other single item, so **you post those** at the buyout the Gear tab shows (see "Gear");
   - cancels and reposts its auctions when someone undercuts them, as long as that still makes a profit;
   - takes the mail whenever you open a mailbox, and, if you tick "Walk to the mailbox and back
     to the auctioneer by itself", walks there and back on its own (see "Mail runs");
   - keeps you from going Away (see "Staying active");
   - sells vendor-flip items when you open a merchant.
3. Press it again to stop. Stopping halts a purchase or post in progress at its next step. It
   does not touch anything already listed, and the activity list says what the session made.

There is nothing to set for the trading. The settings page has the plugin's on/off switch (off at
every load), the AUTO switch (off at every load), the mail-run checkbox (also in the window, off
by default), a button and a key to open the window, and two reset buttons (forget prices, clear
the ledger).
It also shows, live, what the plugin has decided from your gold.

The window has no Buy, Post or Cancel buttons; Auto does all of that, except posting gear (the game
does not allow it). The tabs show what it is doing:

| Tab | Shows |
|---|---|
| Overview | Your gold, the session and today's change, what the bags and your auctions are worth, profit on offer, actual and expected profit, the success rate, the scan, the mailbox, the best deals, the fastest sellers, recent activity |
| Deals | What is worth buying now, with how sure each is. Auto buys from the top. Gear deals are on it too, marked "gear". |
| Gear | Weapons, armor and other single items, **by roll** ("of the Monkey" apart from "of the Owl"): **Post these yourself** (each piece in your bags, Auto's first, with the buyout to type in, the cheapest other of the same roll, the 48-hour deposit and what it makes if it sells), the gear deals, and cheap rolls not sure enough for Auto |
| Sell | What you carry, and whether Auto will post it, sell it to a vendor, or keep it (with the reason); gear says "you post it" |
| Vendor | Everything you carry that a vendor buys: what the vendor pays, what the auction house would bring after its cut, what you paid if Auto bought it, which is better and by how much, and the gain against what you paid. Vendor-better first. |
| Auctions | Your auctions: whether each is the cheapest or undercut, and what it makes if it sells |
| Market | Every item. Views: best sellers, listed but not selling, most valuable, price drops and rises, most listed. Searchable by name. |
| Ledger | **All time**: invested, returned, cost of what sold, fees, profit made, still in stock. Then by period: bought, sold, fees, expected against actual, per item. The **Trade log**: every buy, sale, post, cancel, deposit and mail return, filterable. Gold by day, and the profit on offer each day. |

The header shows, under the AUTO button:

- **Projected profit**, in large type. It covers the deals Auto can buy now, best first, each
  planned again at the size Auto may spend on it and counted at its profit times how sure it
  is. It adds what the stock Auto already holds is expected to make.
  - Beside it: how many deals Auto can buy and what they would cost, plus everything found
    whether you can afford it or not.
  - When it changes: it is said in the activity list when Auto starts and after every scan, and
    it pops up when Auto first finds something and whenever it moves by a quarter. It is in the
    settings page's title too.
- **Since Auto started**: what Auto's own trades have actually made since you pressed AUTO,
  beside the projection it started with.
- **Gold, In stock, Today.** Gold spent on stock is not gold lost, so the stock Auto holds is
  shown beside your gold, with what it should sell for. "Today" counts that stock at what it
  cost: buying moves gold into stock, and only fees and sales change it.
- **Waiting in the mailbox**: the sale mails the inbox held the last time a mailbox was open
  (exact), plus auctions that sold since, at their price after the cut with the deposit back
  (estimated). Also on the Overview, where it counts toward "Worth in all".
- **What your gold allows right now**: what can be spent, the most for one deal, the reserve,
  how much is tied up in stock, and the confidence bar.
- **Post these yourself**: gear Auto bought that is in your bags, with the buyout for each.

## Mail runs

**Only with the box ticked.** "Walk to the mailbox and back to the auctioneer by itself" is a
checkbox on the settings page and in the window (one value: either one changes both). It is
**off by default**, because the pathing is being reworked. Off, nothing moves you: you walk to
the mailbox yourself, Auto takes the mail the moment you open it, and your walks are still
learned as routes for when you tick it. Unticked during a run, the run stops at once and lets go
of every key.

With the box ticked, when Auto is on, the auction house is open and nothing else is under way
(no purchase or post, no scan), Auto walks to the mailbox if there is something worth the walk:

- **Worth it:** sale money of at least 5s, or 0.5% of your capital if that is more. Any money
  or items count once 20 minutes have passed since the last run. Runs are at least 10
  minutes apart.
- **The mailbox:** the nearest object named "Mailbox" within 100 yards (the one near the
  auction house).
- **The run:**
  1. Walk to the mailbox (see "How it walks") and open it.
  2. Take every mail: auction money, won, cancelled and expired items, and any other
     letter's money and items while there is bag room.
  3. **A mail with a COD charge is never taken**, since taking it would pay the charge. The
     activity list says how many were left.
  4. Walk back to the spot you stood at when the auction house opened, and open it again by
     the auctioneer.

The window stays open during a run and shows each step and the yards to go.

**How it walks.** On Forever, what moves a character is facing a point and holding forward
(Jambix AIO's kiting proved it). Sentinel Navigation took routes in the first build but never
moved anyone. So a walk is, first choice first:

1. **The way you walked it.** While you walk, your positions are kept. Walk from the auction
   house to the mailbox and open it, or walk back from it and open the auction house, and
   that walk is learned (`jambix.market.errands.json`). A run then follows it point by
   point, so it goes where you went, around every wall you went around.
2. **Sentinel Navigation**, when it is connected and no way is learned yet. If it has not
   moved you 4 seconds after taking the route, it is dropped for the session.
3. **Straight at it**, when the mailbox is within 60 yards.

With none of these, no run starts, and the window says: walk to the mailbox and back once.

**Not getting stuck.** Every walk is watched:

| Problem | What happens |
|---|---|
| Following your way or a straight line, no progress for 1.5 seconds | A jump and a sidestep, left then right in turn |
| Five of those without getting on | The run stops |
| Sentinel: no yard gained in 8 seconds | The route is planned again; after two, the walk goes on straight |
| One walk takes over 90 seconds | The run stops |
| Something else takes your movement or facing (a rotation, a defensive) | Every key is let go, and the walk waits |

A run that stops lets go of every key (you stand still), says where and why, and pauses runs
for 30 minutes. Combat, death, or turning Auto off end a run at once. Every run is logged, the
last 120 lines, in `scripts_data/jcore/jambix.market.errands.json`.

## Staying active

While Auto is on, a small input goes out every 2 minutes so the game does not mark you Away
(which it does after about 5 minutes without input, before logging you out). On Forever a
jump alone did not count as input (Jambix AIO's fishing found this), so three kinds are tried
in turn:

1. a short turn each way, so your facing ends where it was;
2. a short sidestep left, then right (it ends where it began, and never touches the forward
   key, so it cannot walk you off or cut off your own walking);
3. a jump.

The plugin watches for the game's "You are now Away" message. A keep-alive that worked holds
Away off for 5 minutes, so Away within 5 minutes of one means that kind does not work: it is
dropped for good, and the next is tried. A kind with no Away for 15 minutes is marked as
working. If none works, keep-alives stop and the window says so: on that client, only your
own keyboard or mouse keeps you active. Nothing is sent while you type, in combat, or while
dead.

## Gear: Auto buys it, you post it (1.2.0)

**Why you post it.** On Forever the game never takes the call that posts a single item
(`post_item`). The test plugin (`scripts/jambix_postprobe`, 2026-10-09) tried every form of it:
buyout only, a bid under the buyout, a bid equal to it, a bid alone, no bid, the commodity call,
the game's own `C_AuctionHouse.PostItem`, and the slot either side. Nothing listed, and the game
said nothing back. Stackable goods post fine. A single item (every weapon and piece of armor, bags,
recipes: one to an auction) can only be posted through the auction house window, by you.

**Priced by roll.** One item covers every random suffix: a Bandit Cloak "of the Monkey" and one
"of the Owl" sell for very different prices. Forever writes the roll into the item's link as a
bonus id, so each full scan reads the link of every single item. Prices, sales and deals are then
kept per roll.

- **Blank links.** About one link in ten comes back blank the first time, before the game has
  loaded the item, so the scan asks those again, up to three times.
- **Items with no roll**, such as a blue with fixed stats, are one roll. They are judged on the
  item's whole price history, as long as no auction of that item has ever shown a roll, and an
  auction of theirs with a blank link counts as that roll.
- **Unread links.** An item that still has a listing with an unread link is left out of that
  scan's sales comparison, because the missing listing would look like a sale.

**The same rules as everything else**: the same confidence bar, least profit, deal size, order
and big money. Gear is held to three stricter terms:

- **Half a day of selling** is credited to a 48-hour post, not a whole day. Nobody reposts it
  when it is undercut: Auto cannot, and you may be away.
- **One item per purchase and per post.** Each one is a 48-hour deposit of 60% of its vendor
  price, returned when it sells and lost if it does not.
- **Never bought blind.** The search right before a purchase must say each auction's roll, or
  nothing is bought.

**What Auto does**: buys gear deals like any other deal, with two limits:

- **Two waiting.** It keeps at most two pieces waiting for you to post (in the bags or the
  mailbox); then it buys no more gear until you post them.
- **Bids must answer.** Buying a single item uses `place_bid`, which had never run on Forever
  before this version. If the game answers neither of its first two bids, gear buying stops
  until Auto is switched on again, and the deals stay listed for you.

Auto never posts, cancels or vendors gear it bought.

**What you do**: open the Gear tab and post each piece under "Post these yourself" at the
buyout shown, for 48 hours. The window header lists them too, and so does a pop-up when you open
the auction house.

- **The buyout shown** is 1c under the cheapest other auction of the same roll. It is never under
  the vendor price or what Auto paid plus 10% after the cut. For Auto's pieces it is never over
  the price Auto bought them against.
- **Your post is picked up.** When your auctions are read (at once after you post), your post of
  a piece Auto bought joins its lot with its deposit, measured from your gold when the auction
  was made.
  - Only an auction made after Auto bought the roll counts as its piece. Any other auction is
    yours.
  - The sale mail names the roll ("Auction successful: Bandit Cloak of the Monkey"), and settles
    the lot only while one of Auto's pieces of that roll is up.
  - A post that leaves without selling (you cancelled it, or it expired) is not a sale, and your
    repost is taken in again.
- **Undercut gear is yours to repost.** The Auctions tab compares gear with its own roll only.
- **A single item bought for a vendor** that the auction house pays more for (after its cut) is
  listed under "Post these yourself" instead of going to the vendor. Its buyout has no floor at
  what Auto paid: "If it sells" shows the gain or the loss, and you decide.
- **A piece you keep becomes yours.** If you equip, bank or sell a piece yourself, it is in none
  of the bags, your auctions or the mailbox the next time all three are seen. It then leaves
  Auto's stock at what it cost, shown as "Yours now" in the Trade log, and no longer counts as
  waiting.

**What to expect.** On the user's own data (the last full scan, 2026-10-09):

- Of 2,255 single items listed, 700 sold often enough to judge, and 170 had an auction 25% or
  more under their usual price.
- Almost all of those were the price moving, not a bargain. For example, Raider's Shoulderpads
  usually sold for 24s 57c, and all six listed were at 12s.
- The crash check (`pricing.level_shift`) rightly refused 107 of them. 53 had the next auction
  just above the cheap one, and the rest were not sure enough.

So gear deals will be rare. The "Cheap, but not sure enough" list on the Gear tab shows the ones
that came close: Auto never buys those, so whether to buy them is your call.

## Big money (1.1.0)

You asked: "At what point should the equation be like I can make a lot of money here, not just
a few copper or silvers?" The answer Auto now works by:

> **A deal is big money** when, at the size your gold lets Auto buy it now, it is expected to
> make **at least 5% of your capital, and never less than 20s**, after the auction house's 5%,
> the deposits Forever really takes, and the chance it fails. **Deals that would make under 5s,
> or under twice their own deposits, are never bought.** Smaller deals **stop once half your
> money is in stock**, so the last 20% is always there when big money shows up.

| Your capital | Least profit | Big money from | Smaller deals stop at | Stock limit |
|---|---|---|---|---|
| 2g 50s | 5s | 20s | 1g 25s | 1g 75s |
| 6g | 5s | 30s | 3g | 4g 20s |
| 20g | 5s | 1g | 10g | 14g |
| 100g | 10s | 5g | 50g | 70g |
| 1000g | 1g | 50g | 500g | 700g |

Every line is a share of capital, so Auto aims higher as you grow. In the user's first 29 real
purchases, the two finished big deals (Perfect Deviate Scale, Free Action Potion) made half of
all the profit; 17 small buys (mostly vendor flips of 50c to 4s) made 5% of it. Under 1.1.0
those 17 are skipped and their gold goes to the deals that pay.

How the expected profit is worked out:

- **Profit** is what the units sell for after the cut, less what they cost, less the deposits
  the resale may lose (one per post; see "Deposit").
- **Expected profit** is that profit times how sure it is, less what failing would cost times
  the chance it fails (the units sold off cheaply and the deposits gone). A vendor flip cannot
  fail: its profit.
- **Order.** Deals are bought by what they earn **a day on the gold they tie up**: expected
  profit ÷ (cost × days until it sells). A deal that doubles your money in a day beats one that
  makes a little more over a week.
- **When money is short.** A deal that would be big money with your money free, but is not at
  what one deal may get now, shows as "big*" with what it needs.

## Money: decided by the plugin

Your gold is read every two seconds. Nothing here is a setting; every figure comes from your
gold, the stock Auto holds, and how its own trades have gone.

| | Rule |
|---|---|
| Capital | Your gold plus what the stock Auto holds cost |
| Reserve | 10% of capital, always kept (deposits, reposts, a cushion) |
| Stock | At most 70% of capital in unsold stock. A deal that is not big money stops at 50%: the last 20% is kept for big money. |
| One deal | Quarter Kelly: the share of capital a trade deserves from how sure it is, what it makes, and what it would lose (what a vendor, or a market two standard deviations lower, would still pay). The chance is taken two points lower than the model says first. Never more than half of capital or more than is free. |
| Least profit | 5s, twice the deposits the deal posts, or 0.1% of capital, whichever is most. The 5s rises (never past half the big-money line) when small resale lots have fallen short of their plan by more: the 90th percentile of the last 20, once there are 5. |
| Big money | A deal whose expected profit (after the cut, its deposits and the chance it fails), planned at what one deal may get now, is at least 5% of capital (never under 20s) and at least 4 times its deposits. It may use the 70% line; it is said in the activity list and pops up when bought. |
| When | By what each deal earns a day on the gold it ties up: expected profit ÷ (cost × days until it sells; for a vendor flip, days until you visit a merchant, learned from the last ten). Auto buys from the top while money is free, and waits when nothing clears the bar. Posting what it holds comes before buying. |
| Vendor flips | At least 15% under what the vendor pays, and a full stack must make 2s at the vendor. Unless the flip is big money on its own, at most a fifth of capital goes into vendor flips at once and four bag slots are always left free. They cannot lose, but they wait in the bags until you open a merchant. |
| An item that lost | Not bought to resell for 2 days after a lot of it lost money; 7 days after two within a week. |
| Confidence bar | Starts at 99%. It tunes itself so that **98% of Auto's purchases make money** once sold out, fees included (see "The success rate"). Under 98% it rises half a point (99.9% at most). Over 99% after ten purchases it falls a quarter point (95% at least). |
| Auction house cut | 5% until a sale says otherwise. Each "Auction successful" mail is read against the post it fits: the same item and quantity, reading 3% to 8%. (1.0's learning once read a sale against an older expired post and drifted to 4.3%; 1.1.0 starts again from 5%.) |
| Auction length | **48 hours**. A resale is judged on one day of selling per post: over one post, or over two once ten purchases have sold out and 98% of them made money (back to one if the rate falls under 98%). |
| Deposit | Forever's 48-hour deposit: 60% of the vendor price × the units in the post, at least 1s (exact on every post so far: Lion Meat 2s 64c, Thick Spider's Silk 9s, Wool Cloth 3s 96c a stack). The rate is learned from posts over 1s. A deposit comes back when the auction sells and is lost when it is cancelled or expires, so a resale judged over k posts is planned as losing k deposits, and must still make money after two more. |

A sure trade with little to lose gets a large share; a thin or risky one gets little or nothing.
With 2g 52s, for example, it keeps 25s, may spend 2g 27s, and puts at most 1g 26s on one deal.

## Scans

A scan cycle runs **every 3 minutes** while the auction house is open, and does the most the
server allows each time:

- **A full scan**, tried every 3 minutes: every auction. It updates prices, and is the only
  thing that updates how fast things sell (scan against scan).
  - On retail, Blizzard allows one full scan every **15 minutes, account-wide**
    ([C_AuctionHouse.ReplicateItems](https://warcraft.wiki.gg/wiki/API:C_AuctionHouse.ReplicateItems)).
    Whether Forever holds to that is not known yet, so the plugin finds out.
  - When the server refuses a full scan (below), the plugin notes it. When one then works
    within 15 minutes of the last, the time it took becomes the gap, so refused tries are not
    repeated every period. After three clean full scans in a row it tries one cycle sooner, in
    case the server allows more. The gap is never more than 15 minutes.
  - The window's Auction house section shows the gap in use.
- **A quick scan** when the server will not give a full scan: fresh searches of what matters
  most, up to 80 items, in this order:
  1. what Auto holds;
  2. your auctions;
  3. the current deals;
  4. the **watch list**: items a resale may be judged on (seen selling, not gear) that one deal
     could buy with your money free, the most valuable first, where big money shows up;
  5. any slots left: the items that turn over the most money.

  An item searched in the last two minutes is skipped. Prices, the usual price and the deals
  update from these searches; Auto keeps trading while a quick scan runs.

The limit is shared by everything on the account, so another addon or character may have used
it. Then the server sends no new list, and the client still holds the previous one. Folding
that in again would look like nothing sold since the last scan. On Forever the "new list" event
cannot tell (it fires on its own, thousands of times), so the list itself is checked:

- a list whose size never moves from what the client held before asking is thrown away unread;
- a list that is exactly the last scan's auctions, units and value is thrown away after reading;
- a list that changes while it is read is read again.

The activity list says when a scan is not used, and a quick scan runs instead. If full scans
answer nothing at all, the plugin backs off (up to an hour) and quick scans carry on.

## Where the numbers come from

- **Market value.** The cheap end of the listings, as TSM's DBMarket works it out: the cheapest
  15% of units, up to 30% while each price is within 20% of the last. Anything more than 1.5
  standard deviations above that set's mean is dropped. What is left is averaged by unit.
- **Usual price.** The market value averaged over time, with a three-day half-life.
- **Sold per day (estimated).** Between two scans, a listing that left with too much time
  left to have expired was sold. A listing that left with under 30 minutes, or 2 to 12 hours
  over a long gap, might have expired, so it is not counted as sold. A seller who takes items
  down at one price and lists them at another has repriced, not sold, so those are netted out.
  A plain cancellation by someone else still can't be told apart from a sale. These are
  estimates.
  - **Purchases, not units.** One buyer taking 53 is one sale, not 53. Each price that lost
    units counts as one purchase, and how sure a resale is comes from the number of
    purchases.
  - **Auto's own buying is not demand.** Everything Auto bought (read from the ledger, so a
    reload does not lose it) and every auction it cancelled is taken off before a scan is
    counted. In the first live sessions, 53 of the 60 Rockscale Cod "sold" were Auto's own
    purchase; that was repaired in the price file.
- **Deals.** Two kinds:
  - **Vendor flip:** listed for less than a vendor pays. Always sure: the vendor's price does
    not move.
  - **Resale flip:** buy the cheap listings and post again just under the next seller you did
    not buy. Taken only when it is at least as sure to make a profit as the confidence bar
    (see below).
- **Before every purchase** the item is searched again, and the purchase is planned on what is
  listed at that moment. Nothing is bought if the deal has gone. A commodity is bought only
  if the server's actual quote is within what the plan may spend and what is free, still makes
  the least profit, and is still as sure as the bar. Otherwise the purchase is cancelled.
- **Post price.** 1c under the cheapest other seller. Never above twice the usual price.
  Stock bought to resell is never posted above the price it was judged at. Never under the
  floor: the vendor price after the cut, or what was paid plus 10%. If the market is under the
  vendor's price, the item goes to a vendor instead; otherwise it waits.

## How sure a resale is

A resale fails in only two ways: the price falls below what it cost (after the cut) before it
sells, or not enough of it sells before the auction ends. Each deal's **Sure** figure on the
Deals tab is the chance that neither happens:

- **The price.**
  - **Planned against the cautious price.** That is the lowest of the item's usual price, the
    median of its recent days, and the market value of what is *left* once the cheap listings
    are bought.
  - **The chance it holds.** A lognormal with the item's own day-to-day volatility (from its
    history, assumed 15% until it has days of its own). A price that has been falling counts
    against it.
- **The sales.** A Poisson chance that enough *purchases* arrive within the auction's length:
  N units sell when N ÷ (units a purchase takes) buyers come.
  - The rate is the **95% lower bound** of the purchases seen over how long it was watched,
    less a quarter for cancellations counted as sales. Three purchases seen say little; two
    hundred say a lot, however many units each took.
  - Stock Auto already holds of the item counts too: it sells to the same buyers first.
  - No more units are bought than are sure to sell in time.
- **The deposits.** The profit is counted after one lost deposit per stack posted, and the
  price must clear what the units cost plus those deposits.
- **The vendor floor.** If a vendor pays more than the units cost plus the deposit, the
  trade cannot lose, so it is 100% sure.

A resale is never judged on thin data. The item must have been seen in **three scans over at
least an hour**, and **seen selling to other players: three purchases or more, in two scans or
more**. One buyer once proves nothing. After this rule arrived, resales wait until full scans
have counted purchases this way (about an hour of auction-house time); vendor flips carry on. **Gear** is left out, because one item id covers every random suffix ("of the
Bear", "of the Eagle"), at very different prices.

**A crash is not a deal.** One or two cheap listings are a seller in a hurry or a mistake.
Three or more listings 20% under the usual price, or cheap units making up more than a quarter
of everything listed, mean the price has moved. The resale is then planned at the price those
sellers agree on, so nothing is bought to resell above it.

### The backtest

`tools/jtest/tests/market_sim_test.lua` runs the plugin's own planning code against simulated
markets. The planner sees only noisy data:

- Sales counted over 2 to 72 hours, inflated up to 80% by cancellations.
- One to seven days of prices.
- Listings where one time in five the cheap ones are a real crash.

Each trade is then played out hour by hour, with these in it:

- Buyers who take 1 to about 20 units at once.
- Prices drifting (on average down) at each item's own volatility.
- Competitors undercutting, and Auto's reposts.
- Forever's flat 1s deposit per post, returned with a sale and lost on a repost or on what
  does not sell.

It succeeds if it ends with more copper than it started with.

| Rule | Trades (6,000 items) | Made money | Model predicted | Net |
|---|---|---|---|---|
| Original 1.0.0 formula | 2,298 | 78.98% | - | +9,625g |
| Each unit counted as a buyer, 99% (before the live fix) | 237 | 99.16% | 99.89% | +702g |
| Sure ≥ 90% | 234 | 99.57% | 97.81% | +442g |
| Sure ≥ 95% | 189 | 99.47% | 99.12% | +330g |
| **Sure ≥ 99% (where the bar starts)** | **128** | **100.00%** | 99.90% | +205g |
| Vendor flips | 141 | 100.00% | 100% | - |

Counting units as buyers promised 99.89% and delivered 99.16%; counting purchases keeps the
promise. Before buyers took several units and deposits were flat, the 99% bar made money on
2,782 of 2,784 resales over three seeds (99.93%).

**The stream backtest (1.1.0).** The table above judges one deal at a time. Money is made over a
day of deals competing for the same gold, so a second backtest runs 7-day streams of the same
simulated markets against 4g 90s of capital (profit taken out every 15 minutes), deals live
about 2 hours, Forever's 48-hour deposits, up to 4 posts and 3 reposts a day, and a merchant
about once a day:

| Markets an hour | 1.0 rules | 1.1.0 rules | Lots that made money |
|---|---|---|---|
| 15 | 1.89g a day, 76 lots | **2.63g a day**, 62 lots | 100% → 100% |
| 60 | 3.09g a day, 151 lots | **4.76g a day**, 115 lots | 100% → 100% |

Big-money lots made 92% (15/h) and 83% (60/h) of what 1.1.0's lots made. Fewer, bigger trades
make more. The longer design runs (8 streams × 14 days) gave +21% to +67% a day, and at least
98% of lots profitable even with prices falling 15% a day and sales counts tripled.

**What this means:**
- **Profit vs. certainty.** The old formula made more gold overall but lost on one trade in
  five. The new one trades less and almost never loses.
- **This is a model of a market, not the Forever auction house.** The real rate is measured
  as Auto trades (below), and the confidence bar moves with it.
- **Reposting.** An undercut auction is cancelled only if the new price, after the cut, still
  clears the floor by more than the cancel costs plus the deposit the cancel forfeits. A post
  stays up at least 15 minutes. Each item is reposted at most 3 times a day. A cancelled
  auction's items come straight back to the bags and are posted again.

### The success rate

A **purchase lot** is what Auto holds of an item from its first purchase until the last unit
has sold. It made money if its sales are more than what the units cost plus every deposit and
cancel fee it took meanwhile. Each sale on its own never sells under cost, so counting sales
would always say 100%. The Overview and Ledger show "Success so far: N of M purchases made
money once sold", next to what the purchases predicted. This is the rate the confidence bar
tunes to 98%.

## What is recorded

**Every trade is kept for good** in `scripts_data/jcore/jambix.market.journal.json`, never
trimmed: buys, sales (Auto's stock and your own items apart), deposits and cancel fees, posts
(price, hours, deposit), cancels, and items back by mail. The all-time totals on the Ledger tab
are added up from it, so they stay exact however old a trade is:

A **Yours now** row is a piece of gear Auto bought that left its books unsold: you kept,
equipped, banked or sold it yourself. Its cost leaves "Still in stock", and the All time block
says how many and what they cost.

| Total | What it is |
|---|---|
| Invested | Everything Auto paid buying |
| Returned | What Auto's stock brought: auction sales after the cut (deposit back), and vendor sales |
| Cost of what sold | What the sold units cost |
| Fees | Deposits paid and cancel costs |
| Profit made | Returned − cost of what sold − fees |
| Still in stock | What Auto holds, at what it cost |
| Cash so far | Returned − invested − fees: what trading has put into or taken out of your gold so far; the stock still held is the rest |
| Your own items | Sales of things Auto never bought, kept out of all of the above |

- **Gold.** The first, last, lowest and highest gold of each day, for 60 days. A 0 is believed
  only after ten seconds (a loading screen reads 0 for a moment).
- **Purchases.** What each purchase cost, the profit expected when it was made, and how sure
  it was.
- **Lots.** Each purchase lot's sales, cost and fees, and whether it made money.
- **Sales.** The money in each "Auction successful" mail when it reaches your gold, and the
  gold a vendor pays. Each sale is charged the average cost of what was bought, and shown
  beside what that stock was expected to make.
- **Fees.** Deposits (the drop in gold right after posting) and cancel costs. A deposit is
  returned inside the sale's money when the auction sells.
- **On offer.** The most profit the deal list held at any one look each day, bought or not.

## Safety

- **Posting.** Every post is checked by where each carried item sits, before and after the
  post. The item meant must leave its place, or shrink for part of a stack, and no other item
  may move. If a different item moves, posting stops until the scripts reload, and the window
  names the item that moved. Jambix AIO's vendor selling uses the same check.
- **Vendor selling.** Auto's vendor selling sells only stock Auto bought, never a stack merged
  with your own items. It waits while grey junk is still being sold (by you, or by Jambix AIO's
  "sell junk").
- **Your own items and auctions.** Auto posts only what it bought, and cancels only auctions
  it posted. Something you listed by hand is never touched, even if Auto holds the same item.
- **Gear.** Auto never posts, cancels or vendors gear it bought.
  - Gear has a holding of its own, so a vendor flip of the same item can never take its place.
  - At a merchant, a slot whose roll is Auto's gear, or cannot be read, is skipped.
  - It never buys a roll the search cannot confirm from the auction's link.
  - It never keeps more than two pieces waiting for you, counted piece by piece.
  - Only your auctions made after it bought the roll, and no more of them than it holds, are
    counted as its own.

## Seen on the live Forever client

The API recorder (`jcore.recorder.json`) traced the plugin's first live sessions on
2026-10-07:

- **Full scans.** `replicate_items` answers with a 0-based index (about 80,000 auctions).
  `REPLICATE_ITEM_LIST_UPDATE` fires on its own, thousands of times, so it is not used to
  judge a list (see "Scans").
- **Commodity purchases.** `start_commodities_purchase` gives `COMMODITY_PRICE_UPDATED`
  (unit price, total), and `confirm_commodities_purchase` gives
  `COMMODITY_PURCHASE_SUCCEEDED`.
- **Posting.** `post_commodity` returns `false` even when it works;
  `AUCTION_HOUSE_AUCTION_CREATED` carries the new auction's id. Every deposit was a flat 1s,
  whatever the item.
- **Scans name no sellers.** Every other seller's name is blank; only your own character's
  auctions carry a name.
- **Cancelling.** `AUCTION_CANCELED` carries the auction's id, and also fires for others'
  auctions that a purchase used up. A cancel counts only when its own id comes back. The
  cancelled items came straight back to the bags, and `get_cancel_cost` said 0 while the
  deposit was lost.
- **Mail.** Sales were read from "Auction successful" mail.

Seen since (2026-10-09):

- **Item links carry the roll.** Your own auctions and item searches give each auction's link,
  and a random suffix is a bonus id in it (`item:9779::::::::18:1485::1:1:12741:...`, Bandit
  Cloak).
- **No single item can be posted.** The test plugin found that every form of `post_item`
  returns `false` with nothing listed and no answer from the game (see "Gear").
- **Sale mails name the roll** ("Auction successful: Curved Dagger of Defense").
- **An item search groups identical auctions into one row** (2026-10-11): "75 Minor Wizard Oil,
  4s" is 75 auctions of one oil at 4s each, and a bid on the row buys one of them. Read as 75
  for 4s, 1.2.3 booked 1,353 oils for 92s; fixed in 1.2.4, with the books repaired once.
- **A single item is searched by its ITEM level** (2026-10-10). The full scan's `level` is the
  level to use the item (Edged Bastard Sword: 13, item level 18). A search by that level finds
  none of the item's auctions, which is why no gear was bought before 1.2.2. The commodity
  search ignores the level.
- **About one link in ten comes back blank** on first read (`get_replicate_item_link`). Asked
  again a moment later, the full scan read 100%.

Not yet seen: buying a non-commodity item (`place_bid`, which gear buying now uses, and which
stops itself if the game never answers), the replicate list's own links
(`get_replicate_item_link`), and selling vendor flips at a merchant. Whether `buyout_amount` on your own auctions is per unit or per auction is also
unconfirmed. Auctions posted here use the price they were posted at; for others, the reading
nearer the item's price is used. Any call that is missing or raises is logged once, by name.

## Files

| File | Holds |
|---|---|
| `scripts_data/jcore/jambix.market.<realm>.json` | Prices, sales estimates, item names and vendor prices |
| `scripts_data/jcore/jambix.market.<realm>.snap.json` | The last full scan, which the next scan is compared with (gear auctions with their roll) |
| `scripts_data/jcore/jambix.market.<realm>.gear.json` | Gear prices and sales by roll, and the rolls' names |
| `scripts_data/jcore/jambix.market.ledger.json` | Gold by day, stock held and its lots, profit on offer, the inbox's sale mails last seen |
| `scripts_data/jcore/jambix.market.journal.json` | Every trade, never trimmed |
| `scripts_data/jcore/jambix.market.posts.json` | Auctions posted here, by auction id |
| `scripts_data/jcore/jambix.market.policy.json` | The confidence bar, the success record, the learned auction house cut and deposits |
| `scripts_data/jcore/jambix.market.presence.json` | Which keep-alives failed, and which keep you active |
| `scripts_data/jcore/jambix.market.errands.json` | The ways learned to the mailbox, and the mail-run log |

## Tests

```
node tools/jtest/run.js market
```

- `market_test.lua` (63 tests) runs on the Forever client against a fake auction house. It
  covers:
  - pricing, risk and Kelly sizing; purchases counted, not units; deposits in the plan;
  - scans: three scans and the sales between them, a quick scan, a throttled scan, an old
    list with the event firing, a list that changes while read;
  - deals, commodity and item purchases, a moved quote, a quote over budget, a search nobody
    answers;
  - posting with the slot check, undercut detection, reposting, cancels matched by id, your
    own auctions left alone;
  - the money policy and the learned deposit, Auto (buy, post only what it bought, Auto OFF
    mid-purchase, vendor flips, lots), the mailbox and the money waiting in it, the all-time
    totals, the Vendor tab, every tab, and saving;
  - big money: Forever's deposits post by post, the least profit and the big-money line, two
    posts, the cut matched to the right post, the deposit rate learned, big money bought while
    the half line holds smaller deals back, the watch list, and what finished lots teach;
  - the 1.1.0 review: a deal flagged big at an older look, or one that shrinks at the buy
    search, is held to the half line; a slipped quote is planned at the price paid; "big once
    money is free"; no resale before an item's vendor price is known.
- `market_gear_test.lua` (22 tests) runs a fake auction house whose scans, searches, auctions and
  bags carry links the way Forever writes them. Bears and Monkeys of one sword sell at 10g and
  2g. It covers the following, and the six review findings it was hardened against (vendor
  flips beside gear, the cap piece by piece, a cancelled post, your own earlier auction, a
  piece you kept, a link that did not answer):
  - reading a roll from a link, and scans priced and sold roll by roll;
  - a cheap Bear as a gear deal (never priced against Monkeys), with no item-level resale of a
    single item;
  - never buying blind, two unanswered bids stopping gear buying, Auto buying exactly that roll,
    and two waiting holding it back;
  - the post list and its buyouts, and Auto never posting or vendoring gear;
  - your post joining the lot with its deposit, never cancelled;
  - the sale settling the lot by the roll's name;
  - cheap but not sure enough, and the Gear tab.
- `market_errands_test.lua` runs a fake world: you at an auctioneer, a mailbox 50 yards off
  (a wall between them in one test), a fake Sentinel that walks you, takes the route and never
  moves you, or is not connected, the client's own face-and-hold-forward movement, money mails
  and a COD parcel, and the Away messages. It covers a run by Sentinel, Sentinel dropped for a
  straight walk, a learned way around the wall, getting stuck, combat, and the keep-alives.
- `market_era_test.lua` checks that the plugin stays inert on Classic Era.
- `market_sim_test.lua` is the backtest above. It prints its tables, and fails if the 99% rule
  drops under 98% or stops beating the original formula, or if 1.1.0 makes less than 1.2× (15/h)
  and 1.3× (60/h) what 1.0 makes in the stream, or keeps under 98% of lots profitable.

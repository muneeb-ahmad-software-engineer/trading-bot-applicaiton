# GoldGrid Expert Advisor

An XAUUSD grid EA that takes its configuration from the GoldGrid platform and
reports its state back.

---

## ⚠️ Read this first

**This EA places real orders with your broker.**

It was written against [`doc/MT5_INTEGRATION.md`](../doc/MT5_INTEGRATION.md).

**It now compiles cleanly** — 0 errors, 0 warnings, against MetaTrader 5 build
under Wine (`bin/mt5_compile`). Getting there took two fixes: `ParseArray` and
`ParseObject` in `Json.mqh` needed an unreachable `return` after their
`while(true)` loops, and the globals in `GoldGrid.mq5` were renamed `g_*`
because eight parameters named `strategy`/`grid` were shadowing them.

**It has still never been run against a broker — not even a demo one.** Compiling
proves the syntax and types are sound. It proves nothing about whether the grid
logic, the risk gates or the reporting actually behave. You are still the first
person to run it.

**Test on a demo account.** Not "briefly on a live account with a small lot" —
a demo account, for long enough to see it open a basket, add levels, and close
one.

Grid strategies accumulate positions as price moves against them. Losses can
exceed what you expect.

### Where the risk limits actually live

The platform **stores** your limits. It cannot **enforce** them — it never talks
to your broker. Enforcement is in this EA, in `CGridEngine::MayOpen()`
(`Include/GoldGrid/Grid.mqh`). Every limit is checked there before each order:

| Limit | Enforced by |
|---|---|
| Maximum positions | `MayOpen` → `GATE_MAX_POSITIONS` |
| Maximum exposure (lots) | `MayOpen` → `GATE_MAX_EXPOSURE` |
| Drawdown protection | `MayOpen` → `GATE_DRAWDOWN` |
| Margin protection | `MayOpen` → `GATE_MARGIN_LEVEL` |
| Maximum spread | `MayOpen` → `GATE_SPREAD_TOO_WIDE` |
| Basket take profit / stop loss | `ShouldCloseBasket` |

If you edit that file, you are editing the only thing between a configuration
and your account.

---

## Installation

1. **Copy the files** into your MetaTrader 5 data folder
   (*File → Open Data Folder* in the terminal):

   ```
   MQL5/Experts/GoldGrid.mq5
   MQL5/Experts/Include/GoldGrid/Api.mqh
   MQL5/Experts/Include/GoldGrid/Grid.mqh
   MQL5/Experts/Include/GoldGrid/Json.mqh
   MQL5/Experts/Include/GoldGrid/Strategy.mqh
   ```

   Keep the `Include/GoldGrid/` folder next to `GoldGrid.mq5` — the includes are
   relative.

2. **Whitelist the platform URL.** *Tools → Options → Experts →
   "Allow WebRequest for listed URL"*, then add your platform URL exactly, e.g.
   `http://127.0.0.1:3000` or `https://your-domain`. Not `localhost` — the
   whitelist rejects a host name without a dot in it.

   Without this every request fails with error 4014/4060. The EA detects this
   case specifically and refuses to start with a message saying so.

   MetaTrader stores this list **encrypted**, in `config/common.ini`, and writes
   it only on a clean exit — so it cannot be scripted. For terminals the
   platform provisions, set it once on the template installation and every
   instance inherits that file; see
   [`doc/EXECUTION_ARCHITECTURE.md`](../doc/EXECUTION_ARCHITECTURE.md).

3. **Compile.** Either open it in MetaEditor and press F7, or from the repo:

   ```
   bin/mt5_compile          # installs the sources and compiles
   bin/mt5_compile --watch  # recompiles on every change
   ```

   The script copies `mt5/` into the terminal's `MQL5/` tree, so edit the files
   here in the repo, not the copies inside MetaTrader — those are overwritten.

4. **Create an API token** on the platform: *Settings → API tokens*. You'll need
   a verified email address and will be asked to confirm your password. The
   token is shown once.

5. **Create and start a strategy**, and note its id from the URL
   (`/strategies/7` → id `7`).

6. **Attach the EA** to an XAUUSD chart and fill in the inputs.

---

## Inputs

| Input | Meaning |
|---|---|
| `InpBaseUrl` | Platform URL, no trailing slash. Must be whitelisted. |
| `InpApiToken` | Token from *Settings → API tokens*. |
| `InpStrategyId` | Which strategy this terminal runs. |
| `InpReportSeconds` | State report interval (minimum 5, default 10). |
| `InpConfigSeconds` | Configuration refresh interval (default 30). |
| `InpMagicNumber` | Identifies this EA's orders. Change it if you run two instances. |
| `InpSlippagePoints` | Maximum price deviation on market orders. |
| `InpAllowTrading` | **Master switch. Off by default.** |
| `InpReentryCooldownSeconds` | Trailing / reversal only: seconds to wait after a position closes before any new entry (default 60). |

`InpAllowTrading` is off deliberately. Leave it off for the first run: the EA
will connect, fetch configuration and report state so you can confirm the
dashboard populates, without placing a single order.

---

## Behaviour you should understand before running

**When the strategy is stopped on the platform**
- No new positions or baskets open.
- Existing baskets **keep** their take-profit, stop-loss and trailing-stop
  management.
- Nothing is force-closed. Stopping is not "close everything".

Abandoning an open basket with no exit rules would be worse than continuing to
manage it, which is why stopping does not disable exits.

**When the platform is unreachable**
- The EA **fails closed**: once the cached configuration is older than 120
  seconds it opens nothing new.
- Existing baskets continue to be managed, so open risk is not left unattended.

**When the token is revoked (HTTP 401)**
- The EA halts new orders, raises an `Alert()` **once**, and keeps managing open
  positions.
- It keeps polling in the background so that pasting in a fresh token recovers
  it without a restart — but it does not keep alerting. Verified against a live
  demo terminal: an earlier version alerted on every retry, roughly every ten
  seconds, which made the terminal unusable.

**Removing the EA from the chart does not close positions.**

---

## The strategy categories

`category` on the strategy decides how positions are **opened** and how they
exit.

| Category | Opens | Exits with |
| --- | --- | --- |
| `grid` | A **ladder** of resting Buy Stop orders above the market and Sell Stop orders below it, one gap apart; rungs fill only when price reaches them | **One combined basket target**: when the floating P/L of every open position together reaches `basket_take_profit`, all positions close, the rest of the ladder is cancelled, and after `grid_cycle_pause_seconds` a new ladder is placed at the new price. Optional basket stop loss. No trailing stop |
| `trailing` | **One position in total**, at market, and nothing more until it closes | Its trailing stop (mandatory), plus the basket exits if set |
| `reversal` | **One position in total**. Flat, it brackets the market with a buy stop and a sell stop; after that it flips side each time the trailing opposite stop fills | One trailing exit price, held by the broker twice: the position's **stop loss** (closes it) and a **stop order for the opposite side** at the same price (opens the reversal). Both trigger on the same tick |

### Grid — a hedging account is required

A grid holds buy and sell positions side by side, so it **needs a hedging
account**. On a netting account a buy and a sell on one symbol cancel out; the
EA refuses to place the ladder and says so once in the log. The ceilings
(`max_positions`, `max_exposure_lots`, drawdown, margin) count every resting
rung as well as every open position: the limits are promises about the worst
case, and every rung can fill. Details in *How the grid works* below.

### One active position — trailing and reversal

A trailing or reversal strategy holds **zero or one** position, whatever the
direction setting. The one exception is a reversal's own fill: for the moment
between the opposite stop filling and the EA closing the old side, both are
open (see *The reversal* below). This is enforced in the EA on every entry
path:

1. **Reconciled before every entry.** The broker's actual positions (this
   magic number and symbol only) are counted immediately before an order is
   sent. If any is open, nothing is sent.
2. **Settling lock.** Once an order is sent or a fill is seen, new entries are
   refused for a few seconds, so a position that has not yet appeared in the
   terminal cannot be mistaken for "flat".
3. **One-cancels-the-other.** When one side of a reversal bracket fills, the
   other pending order is cancelled straight away from `OnTradeTransaction`.
   While a position is open, the only order that rests is its trailing
   opposite stop (reversal) — or nothing at all (trailing).
4. **Breach repair (RECOVERY).** If more than one position is ever found (a
   spike that fills both bracket sides at once, a restart into an old account
   state), the EA enters `RECOVERY`. It cancels all pending orders and closes
   every position except the newest. It only leaves `RECOVERY` once the
   broker's positions have looked consistent for 10 seconds.
5. **No immediate re-entry.** After any close, including a stop-loss, nothing
   new opens for `InpReentryCooldownSeconds`. Re-entering straight after each
   stop-out is what turned single losses into strings of them.

#### The initial bracket (reversal)

While flat, a reversal strategy rests **exactly one Buy Stop** the entry
distance above the ask and **one Sell Stop** the same distance below the bid.
The entry distance is set on the platform and falls back to the trailing
distance when left blank. Each order carries the **stop loss its position
opens with**, the trailing distance behind the price it would close at, so a
filled position is protected by the broker from its first tick, even with the
terminal offline.

- The first order to fill becomes the only position, and the other is cancelled
  immediately.
- Any duplicate order on the same side, or an order of any other type with
  this magic number, is deleted.
- Each order's comment records its strategy and distance
  (`GG:<id>:L1:D<points>`). If the distance, strategy or lot size changes, or an
  order has no stop loss (placed by an earlier build), both orders are
  withdrawn and placed again around the current price.
- An entry distance inside the broker's minimum stop level is widened to the
  nearest accepted distance, and the log says so.
- While flat, a resting order is never moved, because it may be filling at
  that moment.

#### Execution state

Each trailing or reversal EA runs a small state machine. It is saved in terminal
global variables (`GoldGrid.<magic>.<symbol>.*`) and every transition is logged
as `GoldGrid: state A -> B (reason)`.

| State | Meaning |
| --- | --- |
| `INITIALIZING` | Just started. The EA reads the broker's positions before doing anything. |
| `WAITING` | Flat. The only state an entry can be placed from. |
| `BUY_ACTIVE` / `SELL_ACTIVE` | Exactly one position open. |
| `REVERSING` | The opposite stop filled while the old position was still open (its stop loss could not be set in time); the EA is closing the old position. |
| `CLOSING` | The EA sent a close and is waiting for the broker to confirm it. A close only counts as confirmed when the position has left the open list **and** its closing deal is in the history. If that doesn't happen within 15 s, the state becomes `RECOVERY`. |
| `RECOVERY` | Something is unexpected or unconfirmed. Nothing is opened. A reversal position keeps its trailing exit. |

After a restart the EA always starts from `INITIALIZING` and decides from what
the broker actually holds. The time of the last close is saved in wall-clock
time, so the re-entry cooldown also holds across a restart.

#### The reversal (trailing exit)

A reversal position's exit is **one price, held by the broker twice**: as the
position's own **stop loss**, which closes it, and as a **stop order for the
opposite side** at the same price, which opens the reversal. A buy's stop loss
and a sell stop both trigger on the bid, and a sell's stop loss and a buy stop
both on the ask, so at the exit price the broker closes the old position and
opens the new one **on the same tick**. Gold at $2,000, a 300-point ($3)
distance:

1. **BUY opens at 2000**, already carrying a stop loss (attached to the order
   that opened it). The exit is set at 1997: stop loss 1997 and a **SELL STOP**
   at 1997.
2. **Price rises to 2010.** Both move up to 2007 (in steps of at least
   `step_points`). They never move down.
3. **Price falls to 2007.** The broker closes the BUY at its stop loss and
   fills the SELL STOP. Nothing waits for the EA: not a busy terminal, not a
   slow platform call, not a terminal that is offline.
4. **`SELL_ACTIVE`.** The SELL opened with its first stop loss attached. The EA
   sets its exit (stop loss + **BUY STOP**) 300 points above the ask and trails
   it down. When price reaches it, the cycle repeats.

The log shows each step: `the BUY reverses to SELL at X`,
`CLOSED BUY position … by stop loss`, `FILLED SELL …`,
`state BUY_ACTIVE -> SELL_ACTIVE (reversal — the broker closed #… at its stop loss)`.

**Why the stop loss.** An earlier build gave the position no stop loss and
relied on the EA to close it once it saw the opposite order fill. The close
then waited on the EA: seconds when the terminal was busy (the EA's calls to
the platform block it; a slow platform once delayed a close by 13 s), hours
when the terminal was offline (both orders of a bracket filled and were only
closed at the next start). With the stop loss, the close is the broker's.

- **The fill arrives after the close.** The two are separate broker events. For
  3 s after a close nothing is cancelled, so the opposite order can finish
  filling; a position that appears in that time is the reversal.
- **Both positions open at once** (a stop loss that could not be set in time,
  e.g. inside the broker's freeze distance). The old way applies:
  `REVERSING`, and the EA closes the old one at once, retrying every 2 s.
- **Reversing not allowed** (strategy stopped, `AllowTrading` off, EA halted,
  platform unreachable, risk halt): the stop order is withdrawn and the stop
  loss alone keeps trailing, so the position exits flat at the same price.
  Stopping a strategy therefore does not close its position. A reversal that
  fills during a spread spike is closed as soon as it is seen.
- **The old side cannot be closed within 15 s** (the `REVERSING` case). The
  state becomes `RECOVERY`, which closes every position except the newest.
- **Any other close** (take profit, manual close, stop-out, basket exit) is not
  a reversal: after the 3 s, the opposite stop is cancelled and the strategy
  goes back to `WAITING`, with the cooldown and then a new bracket.
- **A position without a stop loss from an earlier build** is given one at
  its exit on the next pass.
- A stop loss or stop order fills at the price available. In a gap it fills
  beyond its level.

#### The market guard (reversal)

Tested on the broker's real ticks, most of a week's loss came from the first
minutes after gold reopens each day. The spread is then $20–30 and quotes jump
$30–50 back and forth, and a resting stop order fills on every jump. The guard
keeps the strategy out of those minutes:

| Rule | Default | What happens |
| --- | --- | --- |
| Flat before the break | `InpFlatBeforeBreakMinutes` = 5 | This long before the daily or weekend break (from the broker's session table), the position is closed and nothing is left resting. Nothing is carried into the reopen or over a weekend gap. |
| Wait after the reopen | `InpWaitAfterOpenMinutes` = 15 | No new bracket until this long after the **first real price** following 10 minutes without one. The session table's opening time isn't used: this broker's table opens gold at 00:00, but the first price arrives at 01:00. |
| No stale prices | 5 min | Nothing is placed on a price older than this. |
| Spread limit | the strategy's *maximum spread*, or a third of the trailing distance (at least 50 points) | While the spread is wider, no bracket rests. If the opposite stop fills in a wide spread, the EA doesn't flip: it closes both sides and brackets again once the spread is back to normal. |

Setting a minutes input to 0 turns that rule off.

#### Trailing category, both directions

A `trailing` strategy with `direction: both` still holds one position at a
time. After a close, the next entry is the **opposite** side of the position
that just closed. The very first entry is a buy.

---

## Risk halts: emergency stop and daily loss

Every category has two limits that act on what is **already open**. The other
risk gates only refuse new entries; these close positions too:

| Halt | Set on the platform | What the EA does |
| --- | --- | --- |
| **Emergency stop** | The *Emergency stop* button on the strategy page (or `POST /api/v1/strategies/:id/emergency_stop`) | Cancels every pending order, closes every position of this strategy at market, and opens nothing. It stays in force until the strategy is **started** again. |
| **Maximum daily loss** | `max_daily_loss` in the strategy's risk controls (account currency; blank = none) | When today's result for this EA (closed deals since the start of the broker's trading day, plus the floating result of open positions, net of swap and commission) reaches −limit, it closes everything the same way and opens nothing until the broker's next trading day. |

- **What "today" counts.** Every deal closed since the broker's midnight,
  plus the full floating result of what is still open. A position carried
  over midnight therefore brings its result from the previous day with it. A
  position that was already near the limit at midnight can trip the halt soon
  after the new day starts. That is deliberately conservative, since the loss
  is real either way.
- While a halt is in force a reversal does **not** happen. The position and
  its opposite stop are closed, the strategy lands in `WAITING`, and the gate
  keeps it there.
- A single position is closed through `CLOSING`, so the broker confirms the
  close like any other. Failed closes are retried every 5 s.
- With `InpAllowTrading` off, a halt only reports. Nothing is sent, closes
  included.

**How fast an emergency stop arrives.** Every report response carries the
strategy's `config_version`. When it differs from the configuration the EA
holds, the EA re-fetches at once, so a stop, an emergency stop or an edit
normally reaches the terminal within one report interval (`InpReportSeconds`,
default 10 s).

### What the dashboard shows

Each report carries an `execution` block: the state-machine state and why it
was entered, the reversal level (the price of the opposite stop), today's P/L,
and any risk halt in force. The
strategy page shows these in a **Robot state** card. A grid reports `GRID`.

---

## How the trailing stop works (grid and trailing)

Worked through with a $2 loss margin — `trailing.stop_points` of 200, since a
point on XAUUSD is `0.01` — on a buy opened at $345:

| Price reaches | Stop |
| --- | --- |
| $355 | placed at $353 |
| $365 | moved to $363 |
| falls back to $360 | **stays** at $363 |

A sell is the mirror image: the stop sits above the market and only ever moves
down.

- **The stop is only ever moved in the favourable direction.** A trailing stop
  that can widen is not a trailing stop; it is a way to lose more than you
  agreed to.
- **Nothing is cached.** The stop level held by the broker *is* the record of
  the best price seen, so restarting the terminal or re-attaching the EA cannot
  reset a trail that has already ratcheted up.
- **It is per position, not per basket,** because an MT5 stop belongs to a
  position. On a grid every level trails on its own gain, so a level still under
  water simply never activates.
- `activation_points` holds the stop off until the position is that far in
  profit. Leave it unset to trail from the moment the position opens.
- `step_points` is the minimum improvement worth a round trip to the broker.
  Without it the EA would send a modify on nearly every tick and be throttled or
  rejected. The platform never sends a distance without one.
- Trailing runs **before** exits and entries on each pass, and runs regardless
  of `InpAllowTrading` and of whether the strategy is running. Refusing to
  tighten a stop on a position that is already open is not caution — it leaves
  you exposed to exactly the loss the stop was configured to prevent.

**What the broker can override.** A stop closer to the market than
`SYMBOL_TRADE_STOPS_LEVEL` is refused, so a distance tighter than the broker
allows is widened to the broker's minimum and the log says so once. Inside
`SYMBOL_TRADE_FREEZE_LEVEL` the modify is skipped entirely and retried on the
next tick. And a stop is filled at the price available: in a gap or over a
weekend you can be filled well below the level shown.

---

## How the grid works

The grid is a **ladder of pending stop orders closed together as one basket**,
run in cycles. The design and its history are in `grid-strategy-plan.md` at
the repo root; the code is `Include/GoldGrid/Cycle.mqh` (the cycle),
`Include/GoldGrid/Grid.mqh` (the ladder and the combined basket) and the grid
block of `GoldGrid.mq5`.

### The settings

| Platform field | EA | Meaning |
| --- | --- | --- |
| Gap between orders | `grid_spacing_points` | Distance between rungs, and from the market to the nearest rung. 200 points = $2.00 on XAUUSD |
| Buy Stop orders | `grid_buy_orders` | Rungs above the market per cycle (0 = sell-only ladder) |
| Sell Stop orders | `grid_sell_orders` | Rungs below the market per cycle (0 = buy-only ladder) |
| Basket take profit | `basket_take_profit` | Account currency. The combined floating P/L — profit + swap + commission over every open position, both sides — at which the cycle ends |
| Basket stop loss | `basket_stop_loss` | Optional, same measure, the loss at which the cycle ends |
| Pause between cycles | `grid_cycle_pause_seconds` | Wall-clock seconds between a confirmed flat and the next ladder |
| Lot size | `initial_lot` | Every rung, fixed |
| Maximum positions | `max_positions` | Must be ≥ buy + sell. Resting rungs count towards it |

### One cycle

1. **PLACING.** The ladder is measured from one bid/ask — the *anchor*, taken
   when the first rung is sent and fixed for the cycle. Buy Stop *n* rests at
   `anchor ask + n × gap`, Sell Stop *n* at `anchor bid − n × gap`; rung 1 is
   pushed just past the broker's minimum stop distance if the gap is inside
   it. Rungs are placed nearest-first, buy and sell alternating, at most 10
   requests per pass, so 60 orders take a few seconds and never flood the
   broker. Every rung carries the comment `GG:<strategy id>:C<cycle>:L<rung>`.
   A rung the market has already crossed is skipped and logged once; it is
   placed later if price comes back to its side while the cycle is still
   PLACING or ARMED, and never chased with a market order. A rung that has
   filled is never put back within the cycle.
2. **ARMED.** The ladder is complete. Nothing is placed; the basket is watched.
   A rung found missing (deleted by hand, say) sends the cycle back to PLACING.
3. **CLOSING.** The combined floating P/L reached the target (or the basket
   stop loss). The EA enters a **protected closing state**: from that moment
   the risk gate refuses every new order (`GATE_BASKET_CLOSING`), and the
   first close pass goes out before anything is logged or persisted. Each
   pass sends, all asynchronously and in this order:
   1. cancels for the **two nearest orders on each side** — price has to
      cross those before any other, so they are the only rungs that can fill
      while the closes execute;
   2. every close;
   3. cancels for every other order.

   The broker works through requests in arrival order, so this takes the
   reachable rungs away first without putting forty cancels ahead of the
   closes. Passes run on every tick, timer event and trade transaction, and
   the timer runs every 100 ms while closing. Each close and cancel is paced
   **per ticket**: one still executing is not sent again (resent after 1 s
   with no answer); one refused for a reason the next quote clears
   (requote, price changed, off quotes, frozen, timeout) is resent on the
   next pass, up to ten times, then once a second; any other refusal waits a
   second, so a broker that keeps refusing is not hammered. Rejections are
   logged as `REJECTED by the broker`, throttled to one line per 5 s with a
   count. The platform is not called for up to 15 s while closing (each
   WebRequest blocks the EA), and is reported to the moment the close ends.

   A rung that fills during the close (its cancel arrived too late) is
   closed the moment the fill is reported. The close ends when nothing of
   ours is open or resting, the broker's history confirms every close, and
   no ladder order was sent in the last 2 s (one sent just before the close
   may not be listed yet). A rung of the closed cycle that still fills
   during the pause is closed at once. If the broker sets the symbol to
   **close-only**, the basket is still closed at its target or on a risk
   halt; nothing new is placed until full trading returns. While the ladder
   is being placed, the basket is checked between sends, and again right
   after the placement pass, so a rung that fills mid-placement and takes
   the basket to its target is closed at once. One log line gives the
   realised result; the CLOSING line says how many microseconds the first
   pass took to send.
4. **COOLDOWN.** The cycle number goes up by one. The pause is wall clock and
   persisted, so a restart does not shorten it and a quiet market does not
   stretch it. Then PLACING again, anchored at the new market.

Fills are acted on at once (`OnTradeTransaction`), not on the next timer, so a
target reached in a fast move is not missed. The monitor runs in every state
but INITIALIZING and CLOSING — a basket at target closes from RECOVERY too.

### Restarts

The cycle number, anchor and pause deadline are persisted in terminal global
variables `GoldGrid.<magic>.<symbol>.cycle.*`. On every start the EA goes
through **INITIALIZING** and compares that record with the broker:

| Broker | Record | Result |
| --- | --- | --- |
| Our orders or positions, with readable ladder comments | any | The cycle is **adopted from the broker** (number and anchor from the comments and prices; the broker wins over a disagreeing record) and completed — same tickets, no second ladder |
| Ours, and the record says **CLOSING** | any | The close is resumed, not the ladder: the cycle's orders were already cancelled, part of its basket may be gone, and re-placing the ladder would run half a basket on indefinitely |
| Ours, comments unreadable | has an anchor | Continued from the record |
| Ours, comments unreadable | nothing | **RECOVERY**: orders of ours are withdrawn, positions are left to the monitor (closed at target), nothing is placed until nothing of ours remains |
| Nothing of ours | pause remaining | COOLDOWN for the remainder |
| Nothing of ours | a cycle was under way | It ended outside the EA (a risk halt, a manual close-all): the number is retired and the next cycle follows the pause |
| Nothing of ours | first run | Cycle 1 |

Duplicate protection: orders are sent from PLACING only, and the placing
routine only ever sends rungs that neither rest nor have filled — a pass
repeated in the same instant sends nothing twice. After a send nothing is
concluded from the broker's lists for 2 s (live, they lag a send by up to a
few hundred milliseconds). The rungs that have filled this cycle are kept as a
set, fed by the fill transactions and rebuilt from the deal history on a
restart, so a rung whose position was closed by hand is not placed again
either. The ladder's shape (gap, counts, rung 1's offset) is snapshotted when
the cycle anchors; a setting changed on the platform applies to the next
cycle.

### Gates and halts

- **Risk gate** (`MayOpen`) before every rung: configuration fresh, strategy
  running, Algo Trading and the session open, hedging account, maximum
  positions and exposure (resting rungs count), drawdown, margin level. The
  spread limit does not apply to resting orders — they fill later, at their
  price. While the gate refuses, the ladder already resting stays, and the
  rest is placed when it opens.
- **Stopped on the platform:** resting rungs are **withdrawn** (each is a
  future entry); the open basket keeps its target and is closed at it; no new
  cycle starts until the strategy is started again. Then the same cycle
  resumes if its basket is still open, or is retired and the next begins.
- **Emergency stop and daily loss:** the cycle goes to CLOSING through the
  same confirmed close, then waits in COOLDOWN until the halt clears (the next
  trading day for the daily loss), then places a new ladder.
- **Platform unreachable:** no new rungs; the resting ladder and the open
  basket are managed from the last configuration.
- **Market closed / daily break / weekend:** nothing is sent; orders and
  positions are held by the broker and the basket exit resumes at the open.
  The grid does not go flat before the break (`InpFlatBeforeBreakMinutes` is
  reversal-only).
- **Broker order limit** (`ACCOUNT_LIMIT_ORDERS`): a ladder larger than what
  the limit leaves after other orders on the account is cut, nearest rungs
  first, with one log line per cycle.

### What the dashboard shows

The report's `execution` block carries the state (`PLACING`, `ARMED`,
`CLOSING`, `COOLDOWN`, `RECOVERY`), its reason, the cycle number, rungs
resting and filled, the basket's floating P/L against its target, and the
pause left in COOLDOWN. Each order and position reports its rung as
`grid_level`.

---

## Automated backtests (Strategy Tester)

`bin/mt5_backtest` runs the EA through the MetaTrader 5 Strategy Tester,
headless, and checks the refactor's acceptance criteria while it trades:

```
bin/mt5_backtest --pause-app                         # all scenarios, 1–26 Sep
bin/mt5_backtest --pause-app chaos 2026.09.15 2026.09.19
bin/mt5_backtest --pause-app --monthly 2025.01 2026.09   # one month at a time
MT5_BACKTEST_MODEL=4 bin/mt5_backtest --pause-app baseline  # real broker ticks
```

It compiles the EA, syncs a **portable copy** of the local MetaTrader install
into `tmp/mt5-backtest/terminal` (so a terminal you have open is never
touched), writes the tester config, runs it, and parses the agent log. The
full log of each run is saved in `tmp/mt5-backtest/results/<scenario>.log`.
The script exits non-zero if any scenario reports a violation or produces no
summary.

| Scenario | What it runs |
| --- | --- |
| `baseline` | Reversal strategy, no interference |
| `chaos` | Reversal, with a failure injected every ~20 simulated minutes |
| `trailing` | Trailing category, both directions, with chaos |
| `dailyloss` | Reversal with a $15 daily loss limit |
| `spread` | Reversal with a 25-point spread limit (it gates the bracket's market checks, not the stop orders) |
| `grid` | Grid: 30 Buy Stops / 30 Sell Stops 200 points apart, $2 combined target, 10 s pause, no interference |
| `gridchaos` | The same ladder with a failure injected every ~20 minutes |
| `gridrestart` | The same ladder with an EA restart every ~10 minutes, so every cycle state is resumed from the persisted record |
| `gridlimit` | The same ladder with the broker pretending to allow 40 orders (`InpTestOrderLimit`) |
| `griddailyloss` | The same ladder with a $15 daily loss limit |

**Tester mode.** The tester can't reach the platform (`WebRequest` is
unavailable there), so the strategy is built from the *Strategy Tester only*
inputs (`InpTest*`). They are ignored live. All timers use
`Include/GoldGrid/Clock.mqh`: simulated time in the tester, monotonic time
live. Otherwise a 3-second lock would span hours of simulated market.

**The invariant monitor** (`Include/GoldGrid/Tester.mqh`) checks the
following on every tick and prints `INVARIANT VIOLATION` for each breach:
1. Never more than one position — except a reversal's own fill (one buy and
   one sell), which must be resolved within 3 s.
2. Trailing: no pending order beside an open position. Reversal: an open
   position always has exactly one stop order, on the opposite side, and none
   on its own side (5 s grace, trading session only).
3. At most one stop per side, and no other order types.
4. A stop never moves backwards: a position's stop loss, or a reversal
   position's opposite stop order. A reversal position always carries a stop
   loss (5 s grace, trading session only).
5. A manual close is never treated as a reversal.

For a **grid** run the single-position checks do not apply; instead:
1. No two orders of ours of the same type at the same price (5 s grace for a
   chaos-injected stray).
2. The cycle number only ever grows, and by one at a time.
3. Never more positions + resting orders than `max_positions` (60 s repair
   window for the chaos engine's injected position).
4. No resting order from another cycle for more than 5 s.
5. When CLOSING gives way to COOLDOWN, nothing of ours is open or resting.
6. COOLDOWN lasts at least the configured pause.
7. No rung — one side at one level; the buy and sell rungs of a level share
   a comment — fills twice in one cycle.

**The chaos engine** injects, on a seeded schedule:
- a manual close (the "unexpected close")
- an extra opposite position (a simultaneous trigger; RECOVERY must repair
  it within 60 s)
- a stray pending order
- a simulated EA restart (in-memory state dropped, persisted state reloaded)
- a tick storm (the same tick handled 25 times)

Each run ends with one line:
`TEST SUMMARY | violations=… | max_positions=… | reversals=… | reversals_flat=… | max_overlap_ms=… | recoveries=… | chaos=… | net_profit=… | profit_factor=… | win_rate=… | max_drawdown_pct=… | market_change_pct=… | market_range=… | cycle=… | cycle_state=… | cycles_closed=… | cycle_recoveries=… | ladder_max_orders=… | ladder_requests=… | ladder_closed_profit=… | resting_orders=… | open_positions=… | …`.
The `cycle*` and `ladder*` fields describe a grid run and read 0 / INITIALIZING
for the other categories.

**Month by month (`--monthly`).** This runs the reversal strategy separately
for each calendar month (the broker's XAUUSD history starts on 23 Dec 2024).
It prints one table row per month, showing what gold did (closing price,
change, high–low range) next to what the strategy did (trades, reversals,
profit, profit factor, win rate, max drawdown, violations). The table is also
saved as `tmp/mt5-backtest/results/monthly-<model>-<from>-<to>.csv`. Comparing trending, quiet and
volatile months shows how the logic behaves in each kind of market.

**Price data.** The default model (`0`) generates ticks from one-minute bars,
which is fast. `MT5_BACKTEST_MODEL=4` uses the broker's **real** recorded
ticks: slower, with a large first download, but spreads and price paths are as
they actually were. Use it before drawing conclusions from any single month.

**Port 3000.** The tester's local agent always listens on `127.0.0.1:3000`.
That port is fixed inside MetaTrader's encrypted `agents.dat`, and it is also
the platform's port. `--pause-app` stops the Docker `app` service for the run
and restarts it on exit. It **refuses while any strategy is running**, because
stopping the app also stops the managed terminals inside it. Without the flag
the script refuses to start while the port is taken.

**What a pass does and doesn't prove.** A pass shows the execution logic
keeps its invariants across thousands of reversals and injected failures, on
MetaQuotes' *generated* every-tick data. It says nothing about profitability,
and the tester can't reproduce a real broker's requotes, rejections or
partial fills. The demo checklist below still applies before any live use.

## Demo testing checklist

Verified on 2026-09-07 against a MetaQuotes-Demo account (login 112263910,
build 6182, Wine 11.1 on macOS). Six positions opened and closed; realised
result −$7.37 of simulated money, which measures nothing about profitability —
these were deliberately forced entries and exits, not a strategy run.

- [x] EA starts and the log says `platform reachable`
- [x] With `InpAllowTrading = false`, the dashboard shows **MT5 connected** and
      live bid/ask
- [x] Stop reporting → connection reads **stale** within 90s
- [x] Enable trading → level 1 opens; it appears on the dashboard
- [x] Price moves a full grid step → level 2 opens at the right distance
      *(L2→L3 measured 19 points against a configured 20)*
- [ ] Lot sizes match your configuration — **fixed mode only; multiplier mode is
      still untested**
- [x] `max_positions` actually stops new levels
- [x] `max_exposure_lots` actually stops new levels
- [x] `max_spread_points` blocks orders *(fired naturally on a 245-point spike)*
- [x] Basket take profit closes the whole basket
- [x] Basket stop loss closes the whole basket
- [x] Stopping the strategy on the platform stops new levels but keeps exits
- [x] Revoking the token produces an alert and stops new orders
      *(and a fresh token recovers it with no restart)*
- [x] Restarting the terminal mid-basket recovers without duplicating positions
      *(same four tickets before and after)*
- [ ] `max_drawdown_percent` — **untested**: could not be triggered without
      engineering a real loss
- [ ] Behaviour across a weekend close / rollover — untested

**Grid (ladder) checklist** — run 2026-10-06 on the MetaQuotes demo hedging
account from the Docker platform, a 3 + 3 ladder (200 points, 0.01 lots,
$0.30 target, 10 s pause) so a cycle completes in minutes:

- [x] Ladder appears at 200-point gaps, nearest at ≥ the broker's stop level (6 orders within 1.3 s of the start; platform listed the same six with their levels)
- [x] Only the rungs price reaches fill; the rest stay pending (sell rung 1 filled at exactly its price; the other five rested)
- [x] Basket P/L on the platform equals the terminal's combined floating P/L (−1.23 on both)
- [x] Target reached → all positions close, all orders cancel, the log shows the counts ("1 position(s) closed for 0.40, 5 order(s) cancelled")
- [x] 10 s later a new ladder appears at the new market price, cycle + 1
- [x] Terminal restart mid-cycle: same tickets after as before, no new orders ("cycle 1 adopted from the broker — 5 order(s) resting, 1 position(s) open, 1 rung(s) filled so far")
- [x] Stopping the strategy: resting rungs withdrawn, no new cycle ("withdrew 6 resting ladder order(s)", 8 s after the stop)
- [x] Emergency stop: the halt engages within seconds (nothing was open at the time)
- [x] Broker order limit below 60 handled with one warning, not a rejection storm (`gridlimit` backtest: capacity 40 every cycle; not reproducible on the demo account, whose limit is above 60)
- [ ] A week unattended with no invariant violation in the log

Found during that run: a new strategy on a terminal inherits the day's
realised result of the strategy that ran there before it (the magic number
is the terminal's, not the strategy's), so the grid started under the
reversal's daily-loss halt until its own limit was raised; and a filled stop
order was shown as "cancelled" in the platform's order history (fixed — a
vanished order whose ticket is now a position is "filled").

### Found during that run, and fixed

* **Alert storm on a revoked token.** `Alert()` fired on every retry — a modal
  popup with sound every ten seconds, indefinitely. Now fires once per incident;
  polling continues so a fresh token still recovers it.
* **The trade gate blamed the wrong thing.** One message, "Market closed or
  trading disabled", covered four unrelated causes. It now names which, and
  immediately identified MetaTrader's Algo Trading switch as the real blocker.
* **Successful opens were never logged** — only refusals were, so the log
  recorded every moment nothing happened and nothing about money moving.
* **Closes did not record why.** See the spread note below.
* **The EA stopped reporting when the market closed.** Every interval — report,
  config refresh, staleness, open cooldown — was measured against
  `TimeCurrent()`, which is the timestamp of the last quote received, not the
  time. With the market shut no quotes arrive, so it freezes, and every
  interval measured against it stops elapsing. Observed on a Sunday: the EA
  connected, sent exactly one report, then went silent for hours while the
  platform correctly showed the terminal as stale. Nothing had crashed; its
  clock had stopped. Scheduling now uses `GetTickCount64()`, which counts
  milliseconds since the terminal started and is unaffected by quotes, market
  hours, DST or the user changing the system clock. Broker server time is still
  used for anything describing *when a trade happened*.
* **`localhost` could never be whitelisted.** The EA defaulted to
  `http://localhost:3000` and, on failure, told the user to add exactly that to
  MetaTrader's WebRequest list — which silently refuses any host name without a
  dot in it. The instruction could not be followed, so it sent people round the
  same loop. The default is now `http://127.0.0.1:3000`, and the error names the
  substitution when `localhost` is what was tried.

### A real risk worth understanding

A basket is valued at the price it could be closed at, so it carries the **full
spread**. When the spread widens — rollover, news, thin liquidity — a basket can
cross its stop loss without the market having moved against it.

Observed here: the EA measured a basket at **−1.55** and stopped out while the
spread was **245 points**; the actual fill was **−0.23**. Nothing was wrong with
the position — the quote was wide.

The close log now records the spread so this is recognisable after the fact. The
behaviour is **unchanged and undecided**: suppressing a stop loss during a wide
spread would also suppress it during a genuine crash, which is exactly when it
matters most. That trade-off is a trading decision, not a code cleanup.

---

## Known limitations

- **Stop orders fill where the broker fills them.** A grid rung or a reversal
  bracket is a resting stop order: in a gap it fills at the first available
  price past its level, which can be worse than the level. The combined basket
  target is measured on the real fills, so the cycle is unaffected, but a
  single rung can open further from the anchor than its gap.
- **The grid's cycle record lives in the terminal** (global variables
  `GoldGrid.<magic>.<symbol>.cycle.*`). Deleting them is safe — the next start
  rebuilds the cycle from the orders and positions on the broker — but a
  pause in progress is then forgotten.
- **Drawdown is measured from peak equity, not from an all-time high.** The peak
  is stored in a terminal global variable (`GoldGrid.peak.<magic>.<symbol>`) so
  it survives removing and re-attaching the EA. After a deposit or withdrawal
  you may want to re-baseline it — delete that global variable, or call
  `ResetPeakEquity()`.
- **One symbol per instance.** Attach to an XAUUSD chart; the EA refuses to run
  if the strategy's symbol does not match the chart.
- **Not tested.** Repeating this because it matters more than anything else on
  this page.

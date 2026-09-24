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

## The two strategy categories

`category` on the strategy decides how positions are **opened**. It does not
decide how they exit — either category can carry a trailing stop.

| Category | Opens | Exits with |
| --- | --- | --- |
| `grid` | A level at a time, as price moves against the basket | Basket take profit / stop loss, and optionally a trailing stop per position |
| `trailing` | One position per direction, and nothing more until it closes | Its trailing stop (mandatory), plus the basket exits if set |

### Both directions, continuously

With `direction: both`, the buy side and the sell side are run **independently
and continuously**. Each one:

1. opens at market when that direction is flat,
2. is managed on its own — its own exits, its own trailing stop,
3. **opens again on the next pass once it is closed.**

A buy being stopped out does not disturb a sell that is still running, and
neither side ever needs restarting between trades. The open cooldown that stops
a fill being double-counted is held per direction, so both sides can open on the
same pass rather than three seconds apart.

The ceilings still apply across both sides together: `max_positions`,
`max_exposure_lots`, drawdown and margin protection are account-wide, not
per-direction.

> **This needs a hedging account.** On a netting account MT5 holds one position
> per symbol, so sending a sell while a buy is open reduces or reverses it
> rather than adding a second position — a both-directions strategy would spend
> the session cancelling itself out. The EA detects this at startup, says so in
> the log, and refuses the opposing side with
> *"This is a netting account, and the opposite direction is already open"*.
> Set the strategy to buy only or sell only, or move to a hedging account.

---

## How the trailing stop works

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

- Level 1 opens at market when a basket is empty.
- Each subsequent level opens only once price has moved a full
  `grid_spacing_points` beyond the furthest existing entry in that direction.
- Lot size per level is `initial_lot` (fixed mode) or
  `initial_lot × multiplier^(level−1)` (multiplier mode), normalised to the
  broker's volume step.
- `direction: both` runs a buy basket and a sell basket independently. Each
  closes on its own P/L; they do not net against each other. Position and
  exposure ceilings apply across **both**.
- Basket take profit / stop loss are in **account currency**, not points.

---

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

- **No pending orders.** Levels open at market when price reaches them, so the
  `orders` array is always empty. Resting limit orders would fill during gaps
  where this EA will not. This is a deliberate design choice, not an oversight.
- **Drawdown is measured from peak equity, not from an all-time high.** The peak
  is stored in a terminal global variable (`GoldGrid.peak.<magic>.<symbol>`) so
  it survives removing and re-attaching the EA. After a deposit or withdrawal
  you may want to re-baseline it — delete that global variable, or call
  `ResetPeakEquity()`.
- **One symbol per instance.** Attach to an XAUUSD chart; the EA refuses to run
  if the strategy's symbol does not match the chart.
- **Not tested.** Repeating this because it matters more than anything else on
  this page.

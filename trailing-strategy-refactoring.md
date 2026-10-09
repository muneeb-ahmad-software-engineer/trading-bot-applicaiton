# Refactoring Progress Tracker

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Root-cause analysis and target design (no code) | ✅ Done (2026-09-28) |
| 2 | Hard one-position safety net (guards on every open path, reconcile before entry, no uncontrolled re-entry) | ✅ Done (2026-09-28): compiles, not yet demo-tested |
| 3 | State machine + restart persistence + `OnTradeTransaction` confirmation | ✅ Done (2026-09-28): compiles, not yet demo-tested |
| 4 | Initial bracket (Buy Stop + Sell Stop) with OCO behaviour | ✅ Done (2026-09-28): compiles, not yet demo-tested |
| 5 | Trailing opposite entry + confirmed-close reversal (BUY⇄SELL) | ✅ Done (2026-09-28): compiles, not yet demo-tested |
| 6 | Risk controls: max daily loss, emergency stop, spread gate on reversal; platform (Rails) fields | ✅ Done (2026-09-28): compiles, Rails green, not yet demo-tested |
| 7 | Logging pass + test plan (Strategy Tester scenarios, demo run) | ✅ Done (2026-09-29): 5/5 scenarios pass, 21/21 months 0 violations, real-tick check done; pending: demo run (user) |
| 8 | Real trailing opposite stop, no stop loss (replaces Option A) | ✅ Done (2026-09-30): 5/5 scenarios pass, 0 violations |
| 9 | Market guard (flat before the break, wait after the real reopen, spread limit) + distance choice on real ticks | ✅ Done (2026-09-30): bad week −$3,242 → −$678 at $3; $15 distance +$287 over 9 real-tick weeks, 7 of 9 up |
| 10 | Broker-side exit: the reversal position's stop loss at the same price as its opposite stop, so the close no longer waits for the EA | 🟡 Code done (2026-09-30): compiles 0/0; backtests not yet re-run, not deployed |

## Phase 1 — Root-cause analysis (done)

Code analysed: `mt5/GoldGrid.mq5`, `mt5/Include/GoldGrid/Grid.mqh`, `mt5/Include/GoldGrid/Strategy.mqh`, `app/models/strategy.rb`.

**RC1: the `trailing` category is built to hold BUY and SELL at the same time.**
`ManageDirection()` runs separately for BUY and SELL. With direction = `both`, it opens a market BUY *and* a market SELL, each with its own stop at the trailing distance. When either stop is hit, that side re-opens at market after a 3-second cooldown (`OPEN_COOLDOWN_SECONDS`). The Rails model allows this on purpose (`concurrent_directions = 2`). In a choppy market both stops keep getting hit and re-opened, which matches the reported symptom: "both positions open, SL keeps triggering, more trades open, losses add up".

**RC2: a `reversal` relies on two broker events that are not linked.**
The position's SL and the opposite Stop order sit at the same price. When price gets there, the broker handles them as two separate requests. The Stop order can fill first, or the SL can slip or be rejected, so for a moment (or for good) the account holds both BUY and SELL. The `held > 1` branch in `ManageReversal()` only deletes pending orders and waits. It never closes the extra position.

**RC3: the flat bracket is not OCO.**
The Buy Stop and Sell Stop both rest at the broker. A spike or gap that crosses both fills both before the EA reacts (it runs on a 1-second timer or on ticks). The EA has no `OnTradeTransaction` handler to cancel the opposite order the moment one fills. Result: two positions, each closed by its own SL (a double loss), then the EA is flat again and re-brackets, and the cycle repeats.

**RC4: the SL and the reversal order are moved in separate requests and can drift apart.**
`ApplyTrailingStops()` moves the SL first, and `PlacePendingStop()` moves the order later. If the order modify is rejected (freeze level, stops level, requote), the two drift apart:
- The SL fires with no reversal order at that price. The EA is flat and immediately re-brackets, which is an uncontrolled re-entry.
- Or the order fills before the SL fires, and both sides are open.

**RC5: the EA has no state, no lock, and no confirmation.**
Every pass rebuilds its decision from a snapshot of positions and orders. There is no "closing / opening in progress" lock, no persisted state across restarts, and no check that a close actually executed. The EA also can't tell a planned reversal from an unexpected SL, so it re-enters after both the same way.

**RC6: the risk gate lets two positions through.**
The reversal order calls `MayOpen(..., replacing_positions = 1)`. That tells the gate the current position "doesn't count", so `max_positions = 1` never blocks the opposite side from opening while a position is still live.

### Key design conflict (decision D1, needed before Phase 5)

The spec asks for a real **Sell Stop** trailing below a BUY, and also for: when it triggers, "close BUY → confirm closed → activate SELL". A real broker Stop order that triggers **is already an open SELL**, so the BUY is still open at that moment. With a pending order you can't fully guarantee "never simultaneous". Options:

- **A (recommended): virtual trailing entry plus a broker-side SL at the same level.**
  - The EA trails the reversal *level* internally. It persists the level and reports it to the platform as the trailing entry.
  - The live position's broker SL sits at that level, so the broker still closes it if the terminal goes offline.
  - When the SL closes the position (confirmed through `OnTradeTransaction` / `DEAL_REASON_SL` and a check that zero positions remain), the EA opens the opposite side at market.
  - Result: two positions can never be open. Offline, the worst case is ending up flat.
- **B: real pending Stop order, and close the old position as soon as the order fills.** This matches the spec's wording, but there is a short overlap on every reversal (and a longer one if the close fails). It also needs a hedging account.
- **C: netting-account atomic reversal.** One Stop order of double the lot size flips the position in a single broker deal. This only works on netting accounts.

**Decision (2026-09-28): Option A. ⚠️ Replaced by Option B on 2026-09-30 — see Phase 8.** The virtual trailing entry level plus a broker-side SL at that level. The opposite side opens at market only after the close is confirmed and zero positions remain. The only real pending orders are the initial bracket (Phase 4), used while flat.

## Phase 2: one-position safety net (done)

**Fixes RC1, RC2, RC3, RC6.** It also partly covers RC5 through the settling lock and close tracking; Phase 3 finishes RC5.

Changes:
- **`mt5/GoldGrid.mq5`**
  - `EntryAllowed()`: a single gate for every trailing/reversal entry. It counts broker positions (magic + symbol) right before sending, and refuses if any exist, if a fill is still settling (`entry_lock_until`), or if the re-entry cooldown is running.
  - `EnforceSinglePosition()`: runs on every pass. If more than 1 position is found, it cancels all pending orders, closes everything except the newest, and logs `ONE-POSITION RULE BREACHED`. With `InpAllowTrading` off it only reports the breach and closes nothing.
  - `OnTradeTransaction()`: new.
    - On a fill, it cancels the opposite bracket order right away (OCO) and locks entries.
    - On a close, it logs the side, price, reason (SL / TP / manual / stop-out) and P/L, then starts the re-entry cooldown.
  - `TrackPositionCount()`: a backup close detector, so the cooldown still applies if a transaction event is missed.
  - New input `InpReentryCooldownSeconds` (default 60): no automatic re-entry straight after an SL.
  - **`trailing` category**: now one position in total. It used to be one per direction, which is what opened BUY and SELL together.
  - **`reversal` category**: the opposite pending order parked at the SL is removed (the source of the overlap). No pending order rests while a position is open. The bracket is only placed when flat and after `EntryAllowed()`.
- **`mt5/Include/GoldGrid/Grid.mqh`**: `CloseAllButNewest()`. It only counts a close as successful on `TRADE_RETCODE_DONE`.
- **`app/models/strategy.rb`**: `concurrent_directions` is now 2 only for a both-directions grid, so exposure maths treats trailing/reversal as one position. The test in `test/models/strategy_test.rb` was updated to match.
- **`mt5/README.md`**: the categories section is rewritten to document the one-position rule.

Known interim behaviour (fixed in later phases):
- **Reversal no longer reverses.** A position exits through its trailing SL, then the strategy re-brackets after the cooldown. Phase 5 adds the confirmed-close reversal (Option A).
- A `trailing` strategy with direction "both" always re-enters as BUY, because the BUY side is evaluated first. Phase 5 will pick the direction properly.
- The lock, cooldown and state reset on a terminal restart. Phase 3 adds persistence.

Verification:
- MetaEditor compile: 0 errors, 0 warnings.
- Rails suite: 591 runs, 1 failure. The failure is `local_runtime_test.rb:286` and it fails the same way with these changes stashed (unrelated).
- Not yet run on a demo account or in the Strategy Tester (planned for Phase 7).

## Phase 3: state machine, persistence, broker confirmation (done)

**Completes RC5.**

Changes:
- **New `mt5/Include/GoldGrid/State.mqh`**: `CExecutionState` holds the spec's states:
  - `INITIALIZING`, `WAITING`, `BUY_ACTIVE`, `SELL_ACTIVE`, `REVERSAL_PENDING`, `CLOSING`, `OPENING_REVERSE`, `RECOVERY`.
  - Saved in terminal global variables `GoldGrid.<magic>.<symbol>.{state,ticket,last_close,trail}`, and flushed to disk on every change so a crash doesn't lose it.
  - Every transition is logged as `state A -> B (reason)`.
  - The last-close time is wall-clock (`TimeGMT`), so the re-entry cooldown survives a restart.
  - A `trail` slot is reserved for Phase 5's virtual reversal level.
- **`mt5/GoldGrid.mq5`**
  - `StepState()` reconciles the state with the broker's actual positions on every pass and on every trade transaction:
    - `INITIALIZING` → `WAITING` (flat) or `*_ACTIVE` (position found). A restart always resumes from what the broker actually holds.
    - `WAITING` → `*_ACTIVE` when a fill appears.
    - `*_ACTIVE` → `WAITING` when the broker closes the position (SL / TP / manual). That starts the cooldown and is **not** treated as a re-entry signal.
    - `CLOSING` → `WAITING` only after `PositionConfirmedClosed()`, or → `RECOVERY` after 15 s without confirmation.
    - Two or more positions from any state → `RECOVERY`.
  - `Recover()` cancels pending orders and closes everything except the newest (paced every 5 s, and nothing is sent while `InpAllowTrading` is off). It leaves `RECOVERY` only after the broker picture has been consistent for 10 s, and then applies the cooldown.
  - `EntryAllowed()` now also requires state `WAITING`, on top of the live broker count, settling lock and cooldown. Nothing is decided while the state is `CLOSING` or `RECOVERY` (trailing stops still move).
  - `BeginClose()`: a single-position basket exit now goes through `CLOSING` and waits for confirmation, instead of firing and forgetting.
  - `OnTradeTransaction()` feeds fills and closes straight into `StepState()`.
  - `OnInit()` loads the saved state and logs what the previous session was doing.
  - Removed the Phase 2 stopgaps `EnforceSinglePosition()` and `TrackPositionCount()`, which the state machine replaces.
- **`mt5/Include/GoldGrid/Grid.mqh`**: `OurPosition()`, `PositionConfirmedClosed()` (position gone from the open list **and** its closing deal in the history), and `ClosePosition()`, which only succeeds on `TRADE_RETCODE_DONE`.
- **`mt5/README.md`**: new "Execution state" table.

Not done yet:
- The EA's state isn't sent to the dashboard. The report endpoint whitelists its fields, so this needs the Rails change planned for Phase 6.
- `REVERSAL_PENDING` / `OPENING_REVERSE` exist but aren't reachable until Phase 5.

Verification:
- MetaEditor compile: 0 errors, 0 warnings. No Rails code changed in this phase.
- Not yet run on a demo account or in the Strategy Tester (Phase 7).

## Phase 4: initial bracket (done)

Changes:
- **Configurable entry distance** (new strategy field `entry_distance_points`, reversal only; blank = trailing distance):
  - Migration `db/migrate/20260928120000_add_entry_distance_to_strategies.rb`.
  - Model: validation (1–100 000), plus `effective_entry_distance_points` and `entry_distance_price`.
  - Serializer: new `entry.distance_points` key, carrying the effective value.
  - The field is added to the strategy form (shown only for reversal, via `strategy_category_controller.js`), the show page and the help text. The web controller now accepts it.
  - The JSON API (`api/v1/strategies_controller.rb`) still doesn't accept category or trailing fields, and this one follows the same rule.
- **`Strategy.mqh`** parses `entry.distance_points`. It falls back to the trailing distance for an older platform that doesn't send it.
- **`GoldGrid.mq5`**: new `PlaceBracket()` for the flat reversal state.
  - Exactly one Buy Stop at ask + distance and one Sell Stop at bid − distance.
  - `DeleteStrayOrders()` removes same-side duplicates and any of our orders of another type.
  - A stale bracket is withdrawn whole and placed again around the current price. Stale means a different strategy or distance in the comment (`GG:<id>:L1:D<points>`), or a volume that isn't the current lot size.
  - Comments we can't read are left alone, so the EA can't get stuck re-placing every pass.
  - A distance inside the broker's stop level is widened, with one log line.
  - A resting side is never moved while flat.
- **Carried over from Phases 2–3**:
  - OCO: the other side is cancelled in `OnTradeTransaction` on fill.
  - If both sides fill at once, the state goes to `RECOVERY` and the older position is closed.
  - The bracket is only placed from `WAITING`, after the cooldown.
- **Tests**:
  - Model tests for the entry distance (default, category scoping, boundaries).
  - The EA contract test now pins `entry.distance_points`, plus a test that sends the effective value.

Verification:
- MetaEditor compile: 0 errors, 0 warnings.
- Rails suite: 595 runs, 1 failure. It's the same unrelated `local_runtime_test.rb:286` failure as before.
- Not yet run on a demo account or in the Strategy Tester (Phase 7).

~~Found but not fixed: the serializer sends a hard-coded `max_spread_points: 50`.~~ **Retracted after checking:** this was a misreading of combined command output. `max_spread_points: 50` is only the new-strategy form default in `StrategiesController#defaults`. The serializer sends each strategy's own value correctly, so there is no bug.

## Phase 5: confirmed-close reversal, Option A (done)

This covers spec sections 3 and 4 ("BUY active: trail SELL entry" and its mirror) and all six reversal steps.

How it maps to the spec:

| Spec step | Implementation |
|---|---|
| Exactly one opposite Sell Stop, trailed up, never backward | The **virtual** level is the open position's broker SL. `ApplyTrailingStops` ratchets it forward only, once per `trailing_step_points`, so it isn't modified on every tick. `TrackReversalLevel()` persists it and logs `reversal level — SELL opens if price reaches X` on every move. |
| Triggers → 1. lock entries | The broker closes the BUY at its SL (this works offline too). `StepState` sees the SL close through `ClosingDeal()` → `REVERSAL_PENDING`. Nothing can open outside `WAITING`, and the settling lock is set. |
| 2–3. close BUY, confirm fully closed | The broker SL has already closed it. `PositionConfirmedClosed()` requires the position to be gone from the open list **and** its closing deal to be in the history. Otherwise the state becomes `RECOVERY` after 15 s. |
| 4. verify zero positions | Checked in `REVERSAL_PENDING` and again inside `ExecuteReversal()`. Any position appearing → `RECOVERY`. |
| 5. activate SELL | `OPENING_REVERSE`: `ExecuteReversal()` opens at market with its SL attached, after the full `MayOpen` gate (spread included, since it's a market order). |
| 6. trail exactly one Buy Stop above | On fill → `SELL_ACTIVE`. A new position's level starts from its own SL, never its predecessor's. |

Safeguards:
- **Only an SL close reverses.** TP, manual close, stop-out, basket exit, a stopped strategy or `AllowTrading` off all go to `WAITING` with the cooldown, so there's no uncontrolled re-entry. The closing deal must be read from the history, not guessed. A position that leaves the open list with no closing deal for 15 s → `RECOVERY`.
- **One open request per reversal.**
  - Accepted but no fill within 10 s → `RECOVERY` (never re-sent).
  - Rejected → retried every 2 s, up to 3 attempts, then abandoned.
  - Gate still closed after 30 s (for example a wide spread) → abandoned rather than sent late.
- **Restart mid-reversal:** the EA reconciles from `INITIALIZING`. If flat, it waits out the cooldown, then places a new bracket. It never reverses late.
- **Slippage** between the level and the actual SL fill is logged in points on every reversal.
- **`trailing` category with both directions:** after a close, the next entry is the opposite side of the one that closed (the first ever is BUY). This replaces Phase 2's "always BUY". The last closed side is persisted.

Files:
- `mt5/GoldGrid.mq5`: `IsReversalClose`, `TrackReversalLevel`, `ExecuteReversal`, `AbandonReversal`, plus the reversal states in `StepState`, `ManageReversal` wiring and the trailing-category alternation.
- `mt5/Include/GoldGrid/Grid.mqh`: `ClosingDeal()`.
- `mt5/Include/GoldGrid/State.mqh`: persisted `last_side`; `SetTrailLevel` now reports whether the level moved.
- `mt5/README.md`: reversal walkthrough and the cases where it doesn't reverse.

Accepted limitations:
- The reversal opens at market *after* the SL fill, so every flip pays the spread and the SL's slippage, and possibly the new order's slippage too. That's the cost of never holding both sides.
- A user who drags the SL by hand moves the reversal level with it, since the SL *is* the level.
- Reversal still needs a hedging account: `MayOpen` refuses the reversal category on netting accounts. Option A would technically work on netting, but it's untested, so the restriction stays.

Verification:
- MetaEditor compile: 0 errors, 0 warnings. No Rails code changed in this phase.
- **Not yet run on a demo account or in the Strategy Tester.** Phase 7 covers both reversal directions, simultaneous triggers, repeated ticks, unexpected SL closes and restart recovery.

## Phase 6: risk controls and platform fields (done)

### Rails
- **Migration** `20260928130000_add_risk_halts_and_execution_state.rb`:
  - `strategies.max_daily_loss` (decimal, blank = none).
  - `strategies.emergency_stopped_at`.
  - `terminal_connections.execution_state / execution_reason / reversal_level / daily_profit / risk_halt`.
- **Strategy model**:
  - `max_daily_loss` validation.
  - `emergency_stop!`: stops the strategy and flags it. It works on an already stopped strategy and keeps that strategy's original stop time.
  - `start!` clears the emergency flag.
  - `emergency_stopped?` and `config_version` (microsecond `updated_at`).
- **`Strategies::EmergencyStop` service**, with no preconditions, like Stop. It records a `strategy.emergency_stopped` audit event.
- **Routes and actions** `POST /strategies/:id/emergency_stop` (web) and `POST /api/v1/strategies/:id/emergency_stop` (API, for mobile).
- **Serializer**: `risk.max_daily_loss`, `risk.emergency_stop`, top-level `config_version`.
- **Report endpoint**:
  - Now accepts an `execution` block and stores it on the connection. An EA without the block still reports, and the state is cleared.
  - The reply carries `config_version`.
- **UI**:
  - An *Emergency stop* button (with a confirmation), shown whenever the strategy is running or has open positions or orders.
  - A red banner while the emergency stop is active.
  - A new **Robot state** card: state in plain words, reason, "Sells/Buys if price reaches X", today's P/L against the limit, and a risk-halt alert.
  - A *Maximum daily loss* field on the form and the strategy page, with help text.
- **Tests**:
  - Model: daily loss boundaries, emergency stop lifecycle, original stop time kept.
  - Web and API emergency stop.
  - EA contract: new keys, `execution` stored, config_version changes after an emergency stop, older EA without `execution`.
  - Robot-state card rendering.

### EA
- **`Strategy.mqh`** parses `max_daily_loss`, `emergency_stop` and `config_version`. It rejects a daily loss ≤ 0. A missing emergency flag (older platform) means no emergency.
- **`Grid.mqh`**:
  - `TodayProfit()`: closed deals since the broker's trading-day start, plus floating profit and swap, net of commission without double-counting it. Cached for 500 ms.
  - `DailyLossBreached()` and `CloseAllPositions()`.
  - New gates `GATE_EMERGENCY_STOP` and `GATE_DAILY_LOSS`, checked right after config freshness in `MayOpen`.
- **`GoldGrid.mq5`**:
  - `EnforceRiskHalts()` runs every pass in every state, `RECOVERY` included. It cancels pending orders, then closes positions: a single position through `CLOSING` (broker-confirmed), everything else via `CloseAllPositions`, retried every 5 s. With `InpAllowTrading` off it only reports.
  - `IsReversalClose()` refuses to reverse under a halt.
  - `SendReport()` re-fetches the configuration as soon as the reply's `config_version` differs. The emergency stop reaches the EA in about one report interval (10 s by default) instead of the 30 s refresh.
  - The report gains the `execution` block. A grid reports `GRID`.
- **Spread gate on reversal**: already in place since Phase 5. The reversal is a market order, so it goes through the full `MayOpen` gate including `max_spread_points`. If it's still blocked after 30 s, it's abandoned.
- **`mt5/README.md`**: new "Risk halts" and "What the dashboard shows" sections.

### Verification
- MetaEditor: 0 errors, 0 warnings.
- Rails: 603 runs, 0 failures.
- RuboCop: no offenses on the changed files.
- **Not yet run on a demo account or in the Strategy Tester** (Phase 7).

### Limitations
- The trading day is the broker's server day (`TimeCurrent()` midnight). Brokers whose "day" rolls over at another hour will reset at server midnight.
- The daily loss counts only this EA's magic number and symbol, not the whole account.

## Phase 7: automated testing in the MT5 Strategy Tester (done)

### What was built
- **`bin/mt5_backtest`** runs the EA in the MetaTrader 5 Strategy Tester, headless, on XAUUSD M1. It uses a portable copy of the local MT5 install (`tmp/mt5-backtest/terminal`), so a terminal already running on the Mac is never touched. The script exits non-zero if any run has an invariant violation or no summary.
  - `--pause-app`: the tester's local agent is hard-wired to `127.0.0.1:3000`, the platform's port. The flag stops the Docker `app` service for the run and always restarts it afterwards. It **refuses if any strategy is running**, because stopping the app would kill that strategy's terminal.
  - `--monthly FROM TO`: runs the reversal strategy one calendar month at a time and prints/saves a table (`tmp/mt5-backtest/results/monthly.csv`).
  - `MT5_BACKTEST_MODEL=4`: real broker ticks instead of ticks generated from M1 bars.
- **EA tester mode** (`mt5/Include/GoldGrid/Tester.mqh`, with `InpTest*` inputs that are ignored live). The tester can't call the platform, so the strategy is built from inputs.
- **`mt5/Include/GoldGrid/Clock.mqh`**: every timer and timeout now runs on simulated time in the tester and monotonic time live. Before this, a 3 s lock would have spanned hours of simulated market.
- **Invariant monitor** (checked on every tick):
  - never more than 1 position
  - no pending order beside an open position (after a 5 s grace)
  - at most one stop per side and no other order types
  - a stop never moves backwards
  - a manual close is never treated as a reversal
- **Chaos engine** (seeded) injects: manual close, extra opposite position, stray order, simulated EA restart, and a tick storm (the same tick handled 25 times).
- **Logging pass:** in the tester only, CTrade's per-request echo and the per-move trailing lines are silenced, so a month of testing produces a readable log. Fills, closes, state transitions and errors are always logged. Live logging is unchanged.

### Bug found by the tests, and fixed
- **Trailing category: a stray pending order was never removed while a position was open.** Only the reversal path cleaned up orders. The `trailing` scenario reported 11,984 violations. Fix: a trailing strategy never places pending orders, so any resting order with its magic number is deleted immediately (`ManageBaskets`). After the fix: 0 violations.
- Two bugs in the test tool itself, also fixed:
  - It counted violations from earlier runs of the same day, because MT5 appends all of a day's runs to one agent log. It now reads only the bytes the current run added.
  - The first launch piped its output through `grep`, which hid the script's exit code.

### Results: 1–26 Sep 2026, XAUUSD M1, every tick (generated from M1)

Settings: lot 0.01, trailing 300 points, step 20, entry distance = trailing, cooldown 60 s.

| Scenario | Violations | Max positions | Trades | Reversals | Notes |
|---|---|---|---|---|---|
| baseline | **0** | 1 | 5,368 | 5,366 | Every reversal went through close → confirm → open |
| chaos | **0** | 2* | 5,482 | 4,955 | 1,265 injected failures; 254 double positions seen, 254 repaired by RECOVERY; 260 manual closes, none reversed |
| trailing | **0** | 2* | 4,321 | – | 207 double positions seen, 207 repaired; strays removed (was 11,984 violations before the fix) |
| dailyloss ($15/day) | **0** | 1 | 2,757 | 2,745 | The daily limit closed the position 7 times and blocked trading until the next day |
| spread (≤ 25 pts) | **0** | 1 | 5,010 | 4,779 | 229 reversals correctly abandoned while the spread was too wide |

\* Only immediately after the chaos engine deliberately injected an extra position. Never otherwise.

The Docker MT5 template was also recompiled with this build (`GoldGrid.ex5`). The pre-refactor build is kept as `GoldGrid.ex5.pre-refactor`.

### Results: month by month on old data, Jan 2025 – Sep 2026

`bin/mt5_backtest --monthly`. Reversal strategy, same settings as above, M1 every-tick **generated from one-minute bars**.

| Month | Gold (end) | Gold change | Gold range | Trades | Net profit (0.01 lot) | Profit factor | Violations |
|---|---|---|---|---|---|---|---|
| 2025.01 | 2,798 | +6.6% | $203 | 937 | -371 | 0.70 | 0 |
| 2025.02 | 2,859 | +2.0% | $184 | 1,292 | -27 | 0.98 | 0 |
| 2025.03 | 3,124 | +9.3% | $270 | 1,210 | -69 | 0.95 | 0 |
| 2025.04 | 3,288 | +5.3% | $544 | 4,584 | +1,142 | 1.21 | 0 |
| 2025.05 | 3,289 | +0.0% | $317 | 3,609 | -55 | 0.99 | 0 |
| 2025.06 | 3,303 | +0.1% | $203 | 2,232 | -181 | 0.94 | 0 |
| 2025.07 | 3,291 | -0.4% | $171 | 1,497 | -429 | 0.78 | 0 |
| 2025.08 | 3,448 | +4.8% | $172 | 1,224 | -142 | 0.91 | 0 |
| 2025.09 | 3,858 | +12.0% | $435 | 2,144 | +351 | 1.14 | 0 |
| 2025.10 | 4,002 | +3.7% | $562 | 8,030 | +4,374 | 1.50 | 0 |
| 2025.11 | 4,219 | +5.8% | $316 | 5,016 | -347 | 0.94 | 0 |
| 2025.12 | 4,319 | +2.3% | $386 | 4,785 | +1,122 | 1.21 | 0 |
| 2026.01 | 4,894 | +13.3% | $1,288 | 9,661 | +20,928 | 3.50 | 0 |
| 2026.02 | 5,279 | +10.6% | $879 | 13,499 | +30,483 | 3.91 | 0 |
| 2026.03 | 4,683 | -12.7% | $1,321 | 15,774 | +25,442 | 2.92 | 0 |
| 2026.04 | 4,617 | -1.1% | $380 | 8,519 | +5,579 | 1.65 | 0 |
| 2026.05 | 4,546 | -1.6% | $407 | 6,448 | +3,032 | 1.45 | 0 |
| 2026.06 | 4,016 | -11.4% | $604 | 7,880 | +3,692 | 1.44 | 0 |
| 2026.07 | 4,051 | +1.3% | $243 | 5,526 | +1,634 | 1.25 | 0 |
| 2026.08 | 4,454 | +9.3% | $680 | 6,024 | +2,975 | 1.44 | 0 |
| 2026.09 | 4,291 | -3.0% | $276 | 5,368 | +1,992 | 1.32 | 0 |

**All 21 months: 0 violations. Never more than one position.**

How to read it:
- **Calm or steadily trending months** (gold range under about $300, e.g. Jan–Mar and Jun–Aug 2025) mostly **lost a little** (−$27 to −$429). Price rarely turns by the full $3 trailing distance, so each flip pays the spread and gets stopped out again.
- **Volatile months** (range $400+) made money in the test.
- **Jan–Mar 2026 (range $880–$1,320) show implausibly large profits (+$20k–$30k on 0.01 lot). Treat them as a testing artefact, not a result.** In the generated-tick model the tester invents the price path inside each minute from that minute's high and low, and in extreme volatility that invented path is far smoother and kinder to a trailing stop than real ticks.
### Real ticks vs generated ticks: same weeks, same settings (2026-09-29)

To check the monthly numbers, one quiet week and one wild week were re-run on the broker's **real recorded ticks** (`MT5_BACKTEST_MODEL=4`):

| Week | Gold | Generated ticks | **Real ticks** |
|---|---|---|---|
| 7–12 Jul 2025 (quiet, $86 range) | +0.6% | 343 trades, −$99, PF 0.78 | **351 trades, −$150, PF 0.68** |
| 19–24 Jan 2026 (wild, $369 range) | +7.9% | 1,724 trades, **+$1,219**, PF 1.70 | **2,100 trades, −$320, PF 0.89** |

Both had 0 violations and never more than 1 position.

**Conclusion:**
- The execution logic is sound on real ticks too.
- **The large profits in volatile months were an artefact of generated ticks.** On real prices, with these settings (0.01 lot, 300-point trailing, 20-point step), **the strategy lost money in both the quiet and the wild week.**
- Each reversal pays the spread plus the slippage of a stop fill. Real ticks whipsaw around a $3 level far more than generated paths do.
- **Do not expect this configuration to be profitable.** Any change to trailing distance, entry distance or cooldown should be judged on real ticks (`MT5_BACKTEST_MODEL=4`), never on generated ones.

### More issues found by the tests, and fixed
- **The EA re-sent orders every second while the market was closed** (weekends, gold's daily break), and every one was rejected with "Market closed". Fix: `TradingGate()` now checks the broker's trading-session hours (`TradeSessionOpen()`, via `SymbolInfoSessionTrade`), and while the session is closed `ManageBaskets` sends nothing at all (no entries, cancels or closes). The state machine still reconciles, and resting orders and stops stay with the broker.
- **Test tool:** MT5 cuts back its agent log once it grows large, which made two months come back empty. Each run is now found by its own start line in the log, and the script waits for the tester agent to exit before reading.

### Trailing-distance comparison on REAL ticks, 9 weeks (2026-09-29)

`MT5_BACKTEST_MODEL=4 bin/mt5_backtest --pause-app --sweep`: reversal strategy, 0.01 lot, entry distance = trailing, step = 5 % of the trailing distance. Weeks cover quiet, choppy, trending-up, trending-down and violent markets (Jul 2025 – Sep 2026). Full table: `tmp/mt5-backtest/results/sweep-realticks-20260929-0843.csv`.

| Trailing distance | Total (9 weeks) | Trades | Winning weeks | Violations |
|---|---|---|---|---|
| $3 (current) | **−$3,217** | 13,805 | 0 of 9 | 0 |
| $5 | −$2,014 | 5,492 | 0 of 9 | 0 |
| **$10** | **−$240** | 1,406 | 4 of 9 | 0 |
| $15 | −$570 | 675 | 5 of 9 | 0 |
| $20 | −$636 | 403 | 3 of 9 | 0 |

What it shows:
- **No trailing distance is profitable overall.** A wider distance cuts the number of flips (and so the spread paid) dramatically: $3 → $10 reduces the loss by over 90 %.
- **$10 is the least bad**, but it still loses, and 9 weeks is too few to call it an edge. Picking the best of 5 settings on the same 9 weeks invites over-fitting.
- **At $15–$20 a few bad choppy weeks dominate.** Each losing flip costs more, and the most recent week (14–19 Sep 2026) lost at *every* distance.
- **Conclusion:** stop-and-reverse on a trailing stop has no edge on its own in XAUUSD. Changing the distance reduces losses but does not create profit. The ideas worth testing next are filters on *when* to reverse (trading hours, max flips per day, volatility-based distance, a pause after each flip), each judged on real ticks and on weeks **not** used to choose it.

### What these tests do NOT prove
- **Profitability.** The profit figures come from ticks MetaQuotes *generated* from one-minute bars, on 0.01 lots, with no real requotes, rejections or partial fills. They say nothing about future results.
- Real broker behaviour. A demo-account run of strategy #4 is still the final check.

## Phase 8: real trailing opposite stop, no stop loss (done, 2026-09-30)

**Why.** Option A showed the user a position with a stop loss and no opposite order, which is not the requested behaviour. Strategy #5 (category `trailing`, 1000 points) also put a $10 stop loss on every 0.01-lot trade and never placed an opposite order, because that category was never built to. The user asked for the spec as written: no stop loss, a real SELL STOP trailing a BUY (and a BUY STOP trailing a SELL), and on its fill close the old side. That is Option B.

**How it works now (reversal category).**
1. Flat: a Buy Stop and a Sell Stop bracket the market at the entry distance. Neither carries a stop loss. The first fill cancels the other.
2. BUY open: a SELL STOP rests the trailing distance below the bid and moves only up, in steps of at least `trailing_step_points`. Mirror image for a SELL.
3. The opposite stop fills: `OnTradeTransaction` runs a full pass at once. `StepState` sees one BUY and one SELL, enters `REVERSING`, and closes the old position. Close requests are retried every 2 s, with `RECOVERY` after 15 s.
4. The old side is gone: the new position is `*_ACTIVE` and gets its own trailing opposite stop in the same pass.
5. If reversing isn't allowed when the stop fills (strategy stopped, AllowTrading off, halted, platform unreachable, risk halt), both positions are closed and the strategy goes to `WAITING`. The order still acted as the exit, so stopping a strategy no longer leaves its position unprotected or force-closes it.

**Changes.**
- `mt5/Include/GoldGrid/Grid.mqh`
  - New `TrailOppositeStop()`, which ratchets towards the market only, respects the stops/freeze levels and replaces the order on a lot change.
  - Also new: `RemoveStopLoss()` (takes the SL off positions opened by older builds), `NewestPosition()`, `PendingStopPrice()` and `PendingStopHasStopLoss()`.
  - `PlacePendingStop()` no longer attaches a stop loss.
  - `ApplyTrailingStops()` skips the reversal category.
  - Removed: `ClosingDeal()`, `PositionStop()`, and `MayOpen`'s `replacing_positions`/`replacing_volume` (the RC6 loophole).
- `mt5/Include/GoldGrid/State.mqh`: `REVERSAL_PENDING` and `OPENING_REVERSE` are replaced by `REVERSING`. The virtual `trail` level is removed.
- `mt5/GoldGrid.mq5`
  - Removed: `IsReversalClose`, `TrackReversalLevel`, `ExecuteReversal`, `AbandonReversal`, their retry/abandon timers, and the closing-deal wait in `*_ACTIVE`.
  - Added: `KeepOppositeStop`, `IsReversalFill`, `BeginReversal`, `ContinueReversal`.
  - Behaviour changes:
    - `BeginClose` cancels the opposite stop first.
    - `RECOVERY` keeps a lone reversal position's opposite stop, its only exit.
    - A stale bracket also means one carrying a stop loss.
    - The report's `reversal_level` is now the opposite stop's price.
    - The tester's configuration never counts as stale.
  - EA version is now 1.10.
- `mt5/Include/GoldGrid/Tester.mqh`, invariant monitor:
  - Allows a reversal's own buy+sell overlap for up to 3 s.
  - Requires exactly one opposite stop beside a reversal position, and none on its own side.
  - Checks that the opposite stop never moves backwards and that no reversal position has a stop loss.
  - The summary adds `reversals_flat` and `max_overlap_ms`.
- Rails: execution-state labels (`REVERSING`), form hint, help text and the strategy page's "Trailing opposite stop" card.
- `mt5/README.md`: rewritten reversal section.
- The Docker terminal template was recompiled with the new EA. The previous build is kept as `GoldGrid.ex5.pre-opposite-stop`.

**Verification.**
- MetaEditor: 0 errors, 0 warnings. Rails: 605 runs, 0 failures.
- `bin/mt5_backtest`, 1–26 Sep 2026, generated ticks: all 5 scenarios pass with 0 violations.

| Scenario | Trades | Reversals | Ended flat | Violations | Net |
|---|---|---|---|---|---|
| baseline | 5,336 | 5,334 | 0 | 0 | +$2,110 |
| chaos (1,265 injected failures) | 5,465 | 5,194 | 2 (chaos closed the new side by hand mid-reversal) | 0 | +$1,958 |
| trailing (category unchanged) | 4,322 | — | — | 0 | −$245 |
| dailyloss | 2,467 | 2,452 | 2 | 0 | +$1,247 |
| spread | 5,336 | 5,334 | 0 | 0 | +$2,110 |

**⚠️ Real ticks, 14–19 Sep 2026, 300 points, 0.01 lot: −$3,242 (1,768 trades, max drawdown 32%). The old design lost −$786 in the same week.**
- 91 trades (5%) lost more than $10 each and made up −$2,450 of it. Almost all of them fell in the **first 10 minutes after the daily reopen (01:00 server time)**, and Monday's reopen alone cost −$1,931.
- At the reopen the spread is $20–30 and quotes jump $30–50 back and forth. Resting stop orders fill on every flicker. The old design only reacted once per EA pass, which throttled it by accident.
- Outside those minutes the week lost −$790, about the same as the old design.
- Fixed in Phase 9.

The generated-tick model is far too kind here. Judge profit only on real ticks.

## Phase 9: market guard and trailing distance (done, 2026-09-30)

The user asked for minimal loss and maximum profit, within the same requirements: no stop loss, a trailing opposite stop, one position.

**The guard** (`GoldGrid.mq5`, reversal only; see "The market guard" in `mt5/README.md`):
- **Flat before the break.** `InpFlatBeforeBreakMinutes` (5) before the session table's close, the position is closed through `CLOSING` and nothing rests. Nothing is carried into the reopen or over a weekend.
- **Wait after the real reopen.** No bracket for `InpWaitAfterOpenMinutes` (15) after the **first real price following 10 min without one** (`TrackQuotes`). The session table can't be used for this: this broker's table opens gold at 00:00, but prices start at 01:00. A first version trusted the table, rested a bracket on stale prices at 00:15, and was filled in the 01:00 chaos.
- **No orders on a price older than 5 min.**
- **Spread limit.** The strategy's max spread, or a third of the trailing distance (at least 50 points). Above it, no bracket rests, and a filled opposite stop closes both sides instead of flipping.
- New helper: `CGridEngine::SecondsToSessionClose()`.

**Effect on the bad week, real ticks, 14–19 Sep, $3 distance:**
- Without the guard: −$3,242, max drawdown 32%.
- With the session-table version of the guard: −$1,024.
- With the final version: **−$678, max drawdown 6.8%**, 0 recoveries.

**Trailing distance, real ticks, 0.01 lot, with the guard** (`--sweep`; CSVs `sweep-reversal-realticks-20260930-*.csv`):

| Distance | Weeks A (5) | Weeks B (4, out of sample) | 9-week total | Winning weeks |
|---|---|---|---|---|
| $3 | −$1,446 | — | — | 0 of 5 |
| $5 | −$1,266 | — | — | 0 of 5 |
| $7.50 | — | −$378 | — | 0 of 4 |
| $10 | +$405 | +$0 | +$406 | 5 of 9 |
| **$15** | **+$118** | **+$169** | **+$287** | **7 of 9** |
| $20 | +$204 | — | — | 3 of 5 |

- Weeks A: 2025.08.18, 2025.10.20, 2026.01.19, 2026.06.15, 2026.09.14. Weeks B: 2025.07.07, 2025.09.22, 2025.12.08, 2026.03.09.
- **Recommendation: 1500 points ($15).** It wins most weeks and has the smallest bad weeks (worst −$115). Short distances lose every week: gold's normal noise and spread are too big for a $3–7 trail.
- The edge is small (about $30 a week per 0.01 lot) and nine weeks is not proof. Run it on demo before any real money.

## Phase 10: broker-side exit (code done, 2026-09-30)

**Report.** "Sometimes, when a buy trade reaches its sell stop/trailing stop, the trade does not close immediately. The system detects the issue later, after the price has moved further."

**Root cause.** Since Phase 8 a reversal position had no stop loss. The broker filled the opposite stop order, but closing the old position was the EA's job, done only when it saw the fill. Everything that delays the EA delayed the close:
- The EA's platform calls (`WebRequest`) are synchronous and block its thread. On 2026-09-30 15:26, with the platform answering HTTP 1003, a `BUY_ACTIVE -> REVERSING` took 13 s to complete, and trade events were logged up to 48 s late.
- With the terminal offline (Docker stopped, 04:52–14:48), both bracket orders filled and nothing was closed for ten hours (−$20.96).
- Hedged, the pair's loss is frozen, but the old position is then closed far beyond its level, and the new position had no exit of its own until the old one was gone.

**Fix.** The exit is one price, held by the broker twice: the position's stop loss (closes it) and the opposite stop order (opens the reversal). A buy's stop loss and a sell stop both trigger on the bid (a sell's stop loss and a buy stop on the ask), so both happen on the same tick, without the EA.
- `Grid.mqh`: `TrailReversalExit()` replaces `TrailOppositeStop()` + `RemoveStopLoss()`. It ratchets from the tighter of the current stop loss and the resting order, sets the stop loss first, then the order. `reverse = false` withdraws the order and keeps the stop loss only.
- Every stop order (bracket and reversal) carries the stop loss its position opens with (`EntryStopLoss()`: distance + spread behind the entry), so a new position is protected from its first tick. `PlacePendingStop()` / `ModifyPendingStop()` take a stop loss. A bracket order without one is stale.
- `GoldGrid.mq5`: `StepState()` recognises the new reversal (old position closed at its stop loss, new one open) and closes it if reversing is blocked. After a close, nothing is cancelled for 3 s (`EXIT_SETTLE_MS`) so the opposite fill can arrive. While reversing is not allowed (strategy stopped, halt, platform stale) only the stop loss trails. The `REVERSING` path stays as the fallback.
- `Tester.mqh`: a reversal position must carry a stop loss (it used to be a violation); position stop losses are ratchet-checked under their own key (a position shares its ticket with its order).

**Note.** This puts a stop loss back on the position, which Phase 8 removed. The opposite stop order is still there, so the Phase 8 behaviour is unchanged. The difference is that the close no longer waits for the EA.

**Pending.** `bin/mt5_backtest --pause-app` (all 5 scenarios) was not run: it stops the Docker app, and that needs the user's go-ahead. The code is not deployed to the container.

## Independent code review (2026-09-29)

A separate reviewer read every change (EA + Rails) looking only for correctness bugs.

**Confirmed clean:**
- No path opens two positions or sends an entry outside `WAITING`, except the intended reversal from `OPENING_REVERSE`.
- A reversal fires once per close, and only on a stop-loss close.
- Deal-history selections are never overwritten while still in use.
- The EA ⇄ Rails contract (`config_version`, `execution` block) matches on both sides.
- Emergency stop is scoped to the user's own strategies.

**Findings, verified and fixed:**

| # | Problem | Fix |
|---|---|---|
| 1 | RECOVERY sent deletes and closes while the market was closed (it runs inside `StepState`, before the market-closed return), so every one was rejected | `Recover()` only sends when `TradingAllowed()`; its checks still run |
| 2 | Close lookups used the position **ticket**, but the deal history is keyed by `POSITION_IDENTIFIER`, and some brokers change a position's ticket (e.g. swap by re-opening). The close would never be found and RECOVERY would never end | `State.mqh` stores the identifier (captured while the position is open, and persisted); `PositionConfirmedClosed`/`ClosingDeal` look it up. A RECOVERY still unresolved after 5 min prints a clear warning. It stays in RECOVERY, as the spec requires |
| 3 | **Stop and Emergency stop ran every model validation.** A strategy saved under older rules could make the stop fail, leaving the EA trading. (The web Stop action even said "stopped" regardless) | `Strategy#stop!`/`#emergency_stop!` write their columns directly via `halt!` (no validations; `updated_at` included, so `config_version` changes). New test |
| 4 | A basket exit sent a market close with `InpAllowTrading` off | `ExitBasketIfDue` honours the master switch; the position keeps its broker-side stop |
| 5 | The last closed side (used to alternate `trailing` re-entries) was only recorded on one kind of close | Also recorded in `OnTradeTransaction` for every close |
| 6 | The 15 s "deal not yet in history" grace timer could carry over from one position to the next | Reset whenever the state isn't ACTIVE |
| 7 | A backwards PC-clock correction made "seconds since the last close" negative and blocked entries | Clamped: a negative elapsed time counts as elapsed |
| 8 | Daily loss includes the previous day's result of a position held over midnight | Semantic choice, kept (conservative) and documented in `mt5/README.md` |
| 9 | `bin/mt5_backtest` could exit silently if the "is a strategy running?" check itself failed | Now says why and stops |

## Bug fix: timezone-dependent diagnostics test (done, 2026-09-28)

`test/services/mt5/local_runtime_test.rb:286` failed on any machine not set to UTC (for example the dev Mac on PKT, +05:00). It passed in Docker/CI.

- **Cause:** MetaTrader writes log timestamps with no zone, in the local time of the machine it runs on. `Mt5::Runtime::Local#parse_log_line` reads them that way, which is correct because the terminal runs on the same machine as Rails. The test built `started_at` with `Time.utc(...)`. On a +05:00 machine the log lines looked 5 hours older than the run and were filtered out.
- **Fix:**
  - The test now builds `started_at` in local time (`Time.new(...)`), the same zone the parser uses.
  - A comment on `parse_log_line` documents the local-time assumption.
  - No production behaviour changed.
- **Verified:** the file passes under `TZ=Asia/Karachi` (the machine default), `TZ=UTC` and `TZ=America/New_York`.

---

Here is the revised medium-length prompt with your most important requirement explicitly enforced: ONLY ONE active trade at any time — never BUY and SELL simultaneously.

Act as a senior MQL5 developer and algorithmic trading engineer.

Analyze my existing MT5 trading bot and refactor its execution logic according to the following strategy. First identify the root causes of the current bugs, then implement the necessary fixes while preserving existing working functionality.

1. Absolute Rule: One Active Trade Only

At any moment, there must be exactly ZERO or ONE active market position for this strategy. BUY and SELL positions must NEVER be active simultaneously.

This rule is mandatory during initial execution, reversals, stop-loss events, recovery, and terminal restarts.

Before opening any trade, verify that the previous position is fully closed. If execution status is uncertain, do not open another position.

2. Initial Pending Orders

When the bot starts:

* Place one Buy Stop above the current market price.
* Place one Sell Stop below the current market price.
* Use configurable entry distances.
* Whichever order triggers first becomes the only active position.
* Immediately cancel or invalidate the opposite pending order.
* Prevent duplicate orders and simultaneous triggers.

3. BUY Active — Trail SELL Entry

When BUY becomes active:

* Maintain only one BUY position.
* Place exactly one Sell Stop below the market.
* Trail the Sell Stop upward as the market rises.
* Never move the trailing level backward.
* If the market retraces, keep the previous trailing level unchanged.
* Do not create new orders on every tick.

When the trailing Sell Stop triggers:

1. Lock new entries.
2. Close the existing BUY.
3. Confirm BUY is fully closed.
4. Verify zero active positions.
5. Activate SELL.
6. Begin trailing exactly one Buy Stop above the market.

4. SELL Active — Trail BUY Entry

When SELL becomes active:

* Maintain only one SELL position.
* Place exactly one Buy Stop above the market.
* Trail the Buy Stop downward as the market falls.
* Never move the trailing level backward.
* If the market retraces, keep the previous trailing level unchanged.

When the trailing Buy Stop triggers:

1. Lock new entries.
2. Close the existing SELL.
3. Confirm SELL is fully closed.
4. Verify zero active positions.
5. Activate BUY.
6. Begin trailing exactly one Sell Stop below the market.

5. Fix Existing Trading Bugs

Currently, the bot opens both BUY and SELL positions simultaneously, repeatedly triggers SL, and opens additional trades, resulting in cumulative losses.

Implement strict safeguards:

* Maximum active positions = 1.
* Never open a new position while another is closing.
* Prevent duplicate entries and reversal signals.
* Handle unexpected SL closures without automatic uncontrolled re-entry.
* Remove stale pending orders.
* Use Magic Number and symbol-based order tracking.
* Never interfere with unrelated trades.
* Reconcile actual broker positions before every new entry.

6. State Management and Execution

Implement a reliable state machine:

INITIALIZING → WAITING → BUY_ACTIVE / SELL_ACTIVE → REVERSAL_PENDING → CLOSING → OPENING_REVERSE → RECOVERY

Use MQL5 trade transaction handling and verify actual broker execution before changing states.

Handle rejected orders, partial fills, spread, slippage, invalid stop levels, reconnections, and terminal restarts.

If the previous position cannot be confirmed closed, stop execution and enter RECOVERY rather than opening another trade.

7. Risk Management and Testing

Keep lot size, entry distance, trailing distance, maximum spread, maximum daily loss, and emergency stop configurable.

Add detailed logs for every order placement, modification, cancellation, trade execution, reversal, SL event, and error.

Test both reversal directions, simultaneous triggers, repeated ticks, unexpected SL closures, and restart recovery.

Final acceptance criteria:

* Never more than ONE active position.
* Never simultaneous BUY and SELL positions.
* Exactly one opposite-side trailing pending order while a position is active.
* No uncontrolled re-entry or duplicate orders.
* Every reversal must follow confirmed position closure.
* Trailing levels must never move backward.

After implementation, summarize the root cause, changes made, and test results. Do not claim profitability without proper backtesting.
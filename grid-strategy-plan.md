# Grid Strategy Plan — pending-order ladder with a combined basket target

This replaces the current `grid` category (average into a move, one market order
per level) with the strategy described below: a ladder of resting Buy Stop and
Sell Stop orders, a single profit target for the whole basket, and a timed
restart. The old grid code is removed, not kept beside the new one.

| Phase | Scope | Depends on | Status |
|-------|-------|-----------|--------|
| 1 | Remove the old grid from the EA; the category compiles but places nothing | — | ✅ Done (2026-10-06): the five single-position scenarios (`baseline`, `chaos`, `trailing`, `dailyloss`, `spread`) pass with 0 violations on the rebuilt EA |
| 2 | New configuration contract on both ends (DB, model, serializer, form, `Strategy.mqh`, tester inputs) | 1 | ✅ Done (2026-10-03): Rails 600/600 green, EA compiles 0/0; migration not yet run on the Docker app |
| 3 | Ladder placement: anchored, idempotent, incremental, broker limits respected | 2 | ✅ Done (2026-10-06): `grid` and `gridlimit` pass with 0 violations; the ladder is cut to the 40-order limit every cycle |
| 4 | Combined basket monitor, close-all, cancel-all, confirmed flat | 3 | ✅ Done (2026-10-06): 653 cycles closed at target in `grid`, every one confirmed flat before the pause |
| 5 | Cycle state machine, persistence, restart reconciliation, cooldown | 4 | ✅ Done (2026-10-06): `gridrestart` (2 501 restarts, every state) reproduces `grid` trade for trade with 0 violations |
| 6 | Risk and market gates wired into the cycle | 5 | ✅ Done (2026-10-06): `griddailyloss` passes — 18 halts, each closes the basket and the next day's cycle resumes |
| 7 | Reporting and platform UI for the cycle | 5 | ✅ Done (2026-10-05): Rails 605/605 green, EA compiles 0/0; both migrations applied on the Docker app (2026-10-05); report ingestion and the strategy page checked end to end with `bin/simulate_terminal` (2026-10-05) |
| 8 | Strategy Tester scenarios, invariant monitor, backtests, docs, template recompile | 6, 7 | ✅ Done (2026-10-06): all ten scenarios pass (§3c); template recompiled, previous build kept |
| 9 | Demo run and acceptance sign-off | 8 | 🟡 Demo run done (2026-10-06): 9 of 10 checklist items pass on the demo account; the week-unattended item is the user's |

---

## 1. The strategy, as specified

Configurable inputs (platform fields, not hard-coded):

| Input | Example | Notes |
|---|---|---|
| Gap between pending orders | 200 points | Also the distance of the first order from the market |
| Buy Stop orders per cycle | 30 | Placed above the market |
| Sell Stop orders per cycle | 30 | Placed below the market |
| Maximum trades | 60 | A ceiling, not a target. `buy + sell ≤ maximum` |
| Basket profit target | $2 | Account currency. Combined floating P/L of all open positions |
| Reactivation delay | 10 s | Pause between a basket close and the next cycle |
| Lot per order | 0.01 | Fixed. Every order in the ladder has the same lot |

One cycle:

1. **Place** up to N Buy Stops above the market and M Sell Stops below it, each
   one gap further out than the last.
2. **Wait.** Orders fill only when price reaches them. Nothing is opened at
   market. If price triggers 16 of 60, there are 16 positions and 44 resting
   orders. 0, 1 or all 60 are all valid outcomes.
3. **Monitor** the combined floating profit of the open positions (swap and
   commission included). The target is never checked per position, and never
   waits for all orders to fill.
4. **Close** every open position the moment the combined profit reaches the
   target, then cancel every resting order of the cycle.
5. **Pause** for the reactivation delay once the account is confirmed flat.
6. **Repeat** from step 1 at the current market price.

Non-negotiable rules:

- Never place a second ladder while one is live (no duplicate cycles, no
  duplicate orders at the same level).
- The maximum-trades setting caps positions + resting orders. It never causes
  anything to open.
- The basket target only counts open positions, not pending orders.
- A restart of the terminal resumes the running cycle; it does not place a new
  one on top.

### Ambiguities in the spec, and the decisions taken

- **D1 — Stop or Limit orders? Confirmed 2026-10-03: Stop orders.** The
  inputs say *Buy Stop / Sell Stop* (§1, §2); §5 and §7 say *Buy Limit / Sell
  Limit*. The user confirmed the Limit wording is to be ignored. Buy Stops rest
  above the ask, Sell Stops below the bid, through the existing
  `PlacePendingStop` plumbing.
- **D2 — Hedging account required.** Buy and sell positions must coexist. On a
  netting account a sell fill would close a buy. The EA already detects this
  (`AccountIsHedging()`); the grid will refuse to place a ladder on a netting
  account and say why. This matches the current grid's "both directions"
  requirement.
- **D3 — No loss exit in the spec.** If price runs through one whole side and
  reverses, up to 60 positions sit open until the target is met. The spec says
  nothing about this. **Decision: keep `basket_stop_loss` as an optional
  safety net** (combined loss in account currency closes the basket and
  restarts the cycle like a win would), and keep the account-level limits
  (daily loss, drawdown, emergency stop). Leaving it blank gives the spec's
  behaviour exactly.
- **D4 — Fixed lots only.** The spec has one lot for every order. `lot_mode` and
  `lot_multiplier` are removed from the grid (they were grid-only fields).
- **D5 — The ladder is anchored once per cycle.** The anchor is the bid/ask at
  the moment the FIRST RUNG IS SENT, persisted. Orders are placed relative to
  that anchor even if placement spans several passes, so the ladder never
  drifts with the market during placement. A level the market has already
  passed by the time the EA reaches it is skipped and logged; it is not chased
  with a market order (the spec says nothing opens at market).
  *Refined in Phase 3:* until the first rung is actually sent nothing is
  committed, so the anchor follows the market. Otherwise a strategy started
  during a closed gate (spread, session, stale configuration) would place its
  ladder around a price from an hour earlier when the gate opened.
  *Refined in Phase 5:* a skipped rung stays at its anchored price. If the
  market later moves back to the right side of it while the cycle is still
  PLACING or ARMED, the rung is placed then (as a resting stop, never at
  market). A rung that FILLED is never re-placed in the cycle (D6).
- **D6 — Levels that fill are not re-placed inside the same cycle.** The spec
  describes a ladder consumed once per cycle.
- **D7 — Direction field.** The new grid is defined by its two counts
  (`buy = 0` gives a sell-only ladder). The `direction` field stays for
  trailing/reversal and is hidden for the grid.
- **D8 — A stopped strategy withdraws its resting rungs (2026-10-05).** A
  resting stop order is nothing but a future entry, and "stopped" means no new
  entries. The open basket is not touched: it keeps its target and is closed
  at it. When the strategy is started again the same cycle resumes if its
  basket is still open (missing rungs re-placed at the same anchor); with
  nothing left, the cycle is retired and the next one begins. A *stale
  configuration* (platform unreachable) is different: rungs already resting
  were approved under a fresh configuration and stay; only new rungs wait.
- **D9 — The grid holds through the market break (2026-10-05).** Resting
  orders and positions are held by the broker over the daily break and the
  weekend, and the basket exit resumes at the open. `InpFlatBeforeBreakMinutes`
  stays reversal-only.

### Broker and MQL5 facts the design has to respect

- `ACCOUNT_LIMIT_ORDERS` caps the number of resting orders per account. Some
  brokers set it below 60. The EA must read it and cap the ladder, with a
  clear log line, rather than get 40 rejections per pass.
- `SYMBOL_TRADE_STOPS_LEVEL`: a stop order inside this distance from the
  market is rejected. The first level is widened to it, as `PlaceBracket`
  already does.
- Order comments can be rewritten by some brokers. Level identity is encoded
  in the comment (`GG:<id>:C<cycle>:L<n>`), with the order type and price as the
  fallback for recognising a level.
- Sending 60 requests in one pass can trip "too many requests". Placement is
  spread across passes, nearest level first on each side, and is idempotent.
- `OnTradeTransaction` is the fastest signal that an order filled; the timer
  pass (1 s) is the fallback. Both paths must lead to the same decisions.
- The combined profit uses `POSITION_PROFIT + POSITION_SWAP + commission`, as
  `Basket()` already does, so the basket is valued at what it would close for.

---

## 2. What exists today, and what goes

### EA (`mt5/`)

| Today | Fate |
|---|---|
| `ManageDirection()` grid branch: level 1 at market, next level when price is a step beyond `worst_price` (`GoldGrid.mq5` ~1063–1180) | Removed. Replaced by the cycle manager |
| `SGridStrategy::grid_levels`, `lot_mode`, `lot_multiplier`, `LevelsPerDirection()`, `GridLotForLevel()` multiplier branch (`Strategy.mqh`) | Removed. New fields added (Phase 2) |
| `ExitBasketIfDue()` per direction, `CGridEngine::Basket(type)`, `ShouldCloseBasket()`, `CloseBasket(type)` | Replaced by a combined-basket equivalent; the per-direction versions go once nothing calls them |
| `PlacePendingStop`, `FindPendingStop` (one per side), `DeletePendingStops`, `DeleteAllPendingStops`, `DeleteStrayOrders` | Kept. `FindPendingStop` assumes one order per side; the ladder needs "find by level" (Phase 3) |
| `InpTestGridSpacingPoints`, `InpTestGridLevels`, `BuildTesterStrategy` grid branch, `TEST_GRID` | Replaced by the new tester inputs (Phase 2) |
| Report: `state_name = "GRID"`, `grid_level` from `LevelFromComment` | Replaced by cycle states and the new comment format (Phase 7) |
| Trailing stop per grid position (`ApplyTrailingStops` for `CATEGORY_GRID`) | Removed for the grid. The spec has one exit: the basket target |

### Platform (`app/`, `db/`, `test/`)

| Today | Fate |
|---|---|
| `strategies.grid_spacing_points` | Kept, as the gap |
| `strategies.grid_levels` | Dropped |
| `strategies.lot_mode`, `lot_multiplier` | Dropped (grid-only) |
| `strategies.basket_take_profit` | Kept, required for the grid |
| `strategies.basket_stop_loss` | Kept, optional (D3) |
| `strategies.max_positions` | Kept, as the maximum-trades ceiling |
| Check constraint `grid_strategies_have_a_grid` | Rewritten for the new columns |
| `Strategy#maximum_theoretical_lots` geometric branch, `concurrent_directions`, `grid_levels_within_max_positions` | Replaced by `initial_lot × (buy + sell)` and `buy + sell ≤ max_positions` |
| `StrategySerializer` `grid: { spacing_points, levels, initial_lot, lot_mode, lot_multiplier }` | Becomes `grid: { spacing_points, buy_stop_orders, sell_stop_orders, initial_lot, cycle_pause_seconds }` |
| Form grid card, `strategy_category_controller.js` grid targets, help text | Rewritten for the new fields |
| `strategies_helper.rb` `"GRID"` execution state | Replaced by the cycle states |
| Tests listed in §4 of the survey (model, serializer, EA contract, integration) | Updated in the same phase as the code they pin |

New columns: `grid_buy_orders` (int), `grid_sell_orders` (int),
`grid_cycle_pause_seconds` (int, default 10).

---

## 3. Phases

Each phase ends compiled (`bin/mt5_compile`, 0 errors 0 warnings), with the
Rails suite green where Rails changed, and with the trailing and reversal
backtests unchanged (`bin/mt5_backtest --pause-app`). Nothing is deployed to
the Docker template until Phase 8.

### Phase 1 — Remove the old grid from the EA

**Goal:** a clean base. `CATEGORY_GRID` still parses and compiles, but the EA
places nothing for it and logs once that the grid is being rebuilt. Trailing
and reversal are untouched.

Files: `mt5/GoldGrid.mq5`, `mt5/Include/GoldGrid/Grid.mqh`,
`mt5/Include/GoldGrid/Strategy.mqh`, `mt5/Include/GoldGrid/Tester.mqh`.

Changes:
- `ManageBaskets()`: route `CATEGORY_GRID` to a new `ManageGridCycle()` stub
  that returns after one log line. `ManageDirection()` keeps only what
  trailing needs; every `category == CATEGORY_GRID` branch inside it, in
  `ExitBasketIfDue()` and in `ApplyTrailingStops()` goes.
- `Strategy.mqh`: delete `LevelsPerDirection()`, `lot_mode`, `lot_multiplier`,
  `grid_levels` and the multiplier branch of `GridLotForLevel()` (rename to
  `EntryLot()` since there is no level any more). Parse/validate code for the
  removed keys goes too.
- `Grid.mqh`: delete `Basket(type)`, `ShouldCloseBasket()`, `CloseBasket()`
  if nothing else uses them (check `SBasket` users first; the report uses
  `basket.profit` and that moves to the combined basket in Phase 4, so leave a
  minimal `BasketProfit()` if the report needs it in the meantime).
- `Tester.mqh` / inputs: remove `InpTestGridLevels`; keep
  `InpTestGridSpacingPoints` (it becomes the gap).
- Platform: nothing yet. The serializer still emits `levels`, `lot_mode`,
  `lot_multiplier`; the parser just ignores unknown keys.

Done when: compiles 0/0; `bin/mt5_backtest --pause-app` baseline, chaos,
trailing, dailyloss, spread all pass with the same summaries as before;
`grep -n "grid_levels\|lot_multiplier\|LevelsPerDirection" mt5/` is empty.

Progress 2026-10-03:
- Done: `ManageBaskets` routes `CATEGORY_GRID` to a `ManageGridCycle()` stub
  (logs once, places nothing). `ManageDirection` is trailing-only (one
  position, market entry with its stop attached); the level-stepping block,
  `LevelsPerDirection`, `grid_levels`, `lot_mode`, `lot_multiplier`,
  `GridLotForLevel` (now `EntryLot`), `SBasket.worst_price/highest_level`
  and `CloseBasket` are gone. `ApplyTrailingStops` runs for trailing only.
  `InpTestGridLevels` removed; `BuildTesterStrategy` takes the gap only.
  `SBasket`, `Basket()`, `ShouldCloseBasket()` and `ExitBasketIfDue()` stay:
  trailing and reversal use them for the single position's basket exits.
- Compiles 0 errors / 0 warnings.
- Not done: the five regression scenarios. `bin/mt5_backtest --pause-app`
  refused because strategy #6 (reversal) is running on the platform and the
  tester's agent needs port 3000. Run them once that strategy is stopped or
  port 3000 is free, and compare against the 2026-09-30 summaries (saved in
  the session scratchpad as `before.txt`; also still in
  `tmp/mt5-backtest/results/*.log` until the next run overwrites them).
- Note: the working tree also carries the uncommitted Phase 10 trailing work,
  whose backtests were never re-run either, so a summary change is not
  automatically Phase 1's doing.

### Phase 2 — New configuration contract on both ends

**Goal:** the platform stores and serves the new inputs; the EA parses them;
the tester can build them from inputs. No trading logic yet.

Files: `db/migrate/*`, `db/schema.rb`, `app/models/strategy.rb`,
`app/serializers/strategy_serializer.rb`,
`app/controllers/strategies_controller.rb`,
`app/controllers/api/v1/strategies_controller.rb`,
`app/views/strategies/_form.html.erb`, `show.html.erb`, `index.html.erb`,
`app/javascript/controllers/strategy_category_controller.js`,
`config/locales/strategy_help.en.yml`, `mt5/Include/GoldGrid/Strategy.mqh`,
`mt5/Include/GoldGrid/Tester.mqh`, `mt5/GoldGrid.mq5` inputs, tests.

Changes:
- Migration: add `grid_buy_orders`, `grid_sell_orders`,
  `grid_cycle_pause_seconds` (default 10); drop `grid_levels`, `lot_mode`,
  `lot_multiplier`; replace the check constraint with
  `category <> 'grid' OR (grid_spacing_points IS NOT NULL AND grid_buy_orders IS NOT NULL AND grid_sell_orders IS NOT NULL)`.
  Existing grid rows: back-fill `grid_buy_orders = grid_sell_orders = grid_levels`
  so nothing is left invalid.
- Model, grid only: spacing > 0; buy ≥ 0, sell ≥ 0, buy + sell ≥ 1;
  buy + sell ≤ `max_positions`; `basket_take_profit` required;
  pause ≥ 1 s. `maximum_theoretical_lots = initial_lot × (buy + sell)` for
  the grid. Remove `concurrent_directions`, `lot_mode_multiplier?` and the
  geometric branch. Rewrite `exposure_can_accommodate_the_strategy`'s grid
  message.
- Serializer: the new `grid` block (see §2). `basket.take_profit` unchanged.
- Form / JS / show / index / help text / controller defaults and permitted
  params (both HTML and API): new fields in, old fields out. Default a new
  grid to 200 / 30 / 30 / 60 / $2 / 10 s / 0.01.
- `Strategy.mqh`: `grid_buy_orders`, `grid_sell_orders`,
  `grid_cycle_pause_seconds`; `ParseStrategy` fails on a grid missing any of
  them or missing `basket_take_profit`; a `LadderSize()` helper returns
  buy + sell.
- Tester inputs: `InpTestGridBuyOrders`, `InpTestGridSellOrders`,
  `InpTestGridTargetMoney`, `InpTestGridPauseSeconds`; `BuildTesterStrategy`
  sets `max_positions = buy + sell`, `basket_take_profit = target`.
- Tests: `test/models/strategy_test.rb` (replace the levels / multiplier /
  geometric tests with the new validations and exposure maths),
  `test/integration/ea_contract_test.rb` (pin the new keys),
  `test/serializers/serializer_test.rb`, `api_v1_strategies_test.rb`,
  `strategies_test.rb`, `audit_trail_test.rb`, `strategies_service_test.rb`
  (metadata: `grid_levels` → the two counts).
- `doc/MT5_INTEGRATION.md`: the grid block and formula.

Done when: Rails suite green; the EA contract test lists exactly the keys
`ParseStrategy` reads; compiles 0/0; a grid strategy created through the form
is served by `GET /api/v1/strategies/:id` with the new block.

Progress 2026-10-03 — done:
- Migration `20261003120000_rebuild_the_grid_as_a_ladder`: adds
  `grid_buy_orders`, `grid_sell_orders`, `grid_cycle_pause_seconds`
  (default 10); back-fills existing grids with the old level count on each
  side; rewrites the `grid_strategies_have_a_grid` check; drops `grid_levels`,
  `lot_mode`, `lot_multiplier`. Reversible. **Run it on the Docker app before
  deploying the EA from Phase 8** (`docker compose exec app bin/rails db:migrate`).
- Model: grid-only validations (spacing, counts 0..500, pause 1..3600 s,
  basket take profit required, ladder ≥ 1 order, ladder ≤ max_positions);
  `ladder_size`; `maximum_theoretical_lots = initial_lot × ladder` for a grid.
  A grid clears trailing settings, the entry distance and a one-way direction
  before validation (`drop_settings_a_grid_ignores`) — the form hides those
  fields for a grid, so refusing them would be an error nobody can see.
  `concurrent_directions` and the geometric branch are gone.
- Serializer `grid` block: `spacing_points, buy_stop_orders, sell_stop_orders,
  cycle_pause_seconds, initial_lot`. Nulls for trailing/reversal.
- Form: grid card has gap, buy orders, sell orders, pause; direction and the
  trailing card are hidden for a grid (`singlePosition` target); basket take
  profit is browser-required for a grid (`gridRequired`). Defaults 200 / 30 /
  30 / 10 s / 0.01 / $2 / 60 positions / 0.6 lots. Show and index pages,
  help text, API and HTML permitted params, start-event metadata updated.
- `Strategy.mqh`: `grid_buy_orders`, `grid_sell_orders`,
  `grid_cycle_pause_seconds`, `LadderSize()`. A grid is refused without a
  basket take profit, with an empty or negative ladder, with a ladder larger
  than `max_positions`, or with a pause under 1 s; its trailing fields are
  zeroed on parse. Tester inputs `InpTestGridBuyOrders`,
  `InpTestGridSellOrders`, `InpTestGridTargetMoney`, `InpTestGridPauseSeconds`.
- `doc/MT5_INTEGRATION.md`: grid block, three categories, the stale "409
  while running" claim fixed.
- Trailing and reversal: no validation, serializer key or EA code path they
  use was changed. Their model tests were moved from the grid builder to the
  trailing builder where they test trailing fields, and pass unchanged.

### Phase 3 — Ladder placement

**Goal:** given a flat account and a running grid, the EA places the ladder
once, correctly, and never twice.

Files: `mt5/Include/GoldGrid/Grid.mqh` (new ladder helpers), new
`mt5/Include/GoldGrid/Ladder.mqh` if `Grid.mqh` grows past comfort,
`mt5/GoldGrid.mq5` (`ManageGridCycle`).

Changes:
- Comment format `GG:<id>:C<cycle>:L<n>` (fits 31 chars for realistic ids).
  `n` is 1..buy for Buy Stops, 1..sell for Sell Stops; the order type tells
  the side. `LevelFromComment` updated; `CycleFromComment` added.
- `FindLadderOrder(side, n)`: by magic + symbol + type + comment, fallback by
  price within half a point of the expected level.
- `LadderPrice(side, n, anchor)`: buy `anchor_ask + n×gap`, sell
  `anchor_bid − n×gap`; level 1 widened to `stops_level + 1` if inside it
  (same pattern as `PlaceBracket`).
- `PlaceLadder(anchor, cycle)`: cap `buy + sell` at
  `min(max_positions, ACCOUNT_LIMIT_ORDERS − other resting orders)` with a
  one-time log; walk levels nearest-first, alternating sides; place only
  missing ones; stop after K requests per pass (K ≈ 10) and continue next
  pass; skip (and log once) a level the market has already crossed; return
  whether the ladder is complete.
- The anchor and cycle number are supplied by the caller; this phase stores
  them in static globals, Phase 5 persists them.
- Every placement goes through `MayOpen(..., resting_order = true)` extended
  to count resting orders + positions against `max_positions`, and resting
  volume + open volume against `max_exposure_lots`.

Done when: in the tester with 30/30/200, a flat start produces exactly 60
orders at the right prices across a few passes, and the next 1000 passes place
nothing more; stopping with 20 placed and restarting the EA (Tester
`SimulateRestart`) completes the same ladder, not a new one; a broker order
limit of 40 yields 40 orders and one warning.

Progress 2026-10-03 — code done, tester runs pending:
- `Grid.mqh`: comment helpers `LadderComment` (`GG:<id>:C<cycle>:L<n>`),
  `LevelFromComment` (moved here from the EA; still reads the reversal's
  `GG:<id>:L1:D<n>`), `CycleFromComment`, `StrategyIdFromComment`;
  `SLadderReport`. New ladder section in `CGridEngine`: `OurOrders`,
  `ForeignOrders`, `RestingVolume`, `LadderCapacity` (ladder ∧ max_positions ∧
  `ACCOUNT_LIMIT_ORDERS − foreign orders`, cut logged once per cycle),
  `LadderOffset`/`LadderPrice` (rung 1 pushed past the broker's stop level, the
  rest keep one gap from there), `FindLadderOrder` (comment, then price within
  half a point), `LadderRungHeld` (position comment, then same side within half
  a gap for brokers that rewrite comments), `RecoverLadder` (cycle and anchor
  rebuilt from resting rungs, else from filled rungs), `DeleteLadderStrays`
  (anything of ours that is not a rung of this cycle, duplicates included),
  `PlaceLadder` (nearest-first, alternating sides, at most 10 requests per
  pass, skipped rungs logged once, every send through `MayOpen`).
- `MayOpen`: for a grid only, resting orders count against `max_positions` and
  resting volume against `max_exposure_lots` (`CommittedOrders/Volume`); a
  reversal bracket is exempt because only one of its two orders can fill. A
  grid on a netting account is refused (`GATE_NETTING_OPPOSITE`, D2). The
  trailing and reversal paths through the gate are unchanged.
- `GoldGrid.mq5`: `ManageGridCycle` holds the cycle in memory for now
  (`g_ladder_*`), recovers it from the broker on the first pass after a
  restart, re-anchors each pass until the first rung is sent, cleans strays,
  places, and re-checks a complete ladder only when the order/position picture
  changes. `SimulateRestart` wipes that memory so the tester exercises
  recovery. Tester input `InpTestOrderLimit` fakes a broker order limit; the
  TEST SUMMARY line gains `ladder_cycle`, `ladder_max_orders`,
  `ladder_requests`, `resting_orders`. For a grid, `TesterTick` injects only
  restarts and tick storms and tracks the market; the single-position
  invariants do not run for it (grid invariants come in Phase 8).
- `bin/mt5_backtest`: scenarios `grid` (30/30/200, $2, chaos restarts and
  storms every ~20 min) and `gridlimit` (`InpTestOrderLimit=40`), selectable
  by name, not yet in the default set.
- Compiles 0 errors / 0 warnings. Not run: the "done when" tester checks and
  the five regression scenarios — `bin/mt5_backtest --pause-app` still refuses
  while strategy #6 runs on the platform.
- Known limit, for Phase 5: the in-memory anchor is lost on a restart that
  finds NOTHING of ours on the broker (ladder cancelled by a risk halt, say);
  the next pass then starts cycle 1 again. Persistence fixes the numbering.

### Phase 4 — Combined basket monitor and the close

**Goal:** when the combined floating P/L of our open positions reaches the
target, everything closes and every order is cancelled, and the EA knows when
it is truly flat.

Files: `Grid.mqh`, `GoldGrid.mq5`.

Changes:
- `CombinedBasket()`: count, volume, profit (profit + swap + commission) over
  all our positions, both sides.
- `TargetReached(strategy, basket)`: `profit ≥ take_profit`, or
  `profit ≤ −stop_loss` when a stop loss is set (D3). Returns the reason.
- Close path: `CloseAllPositions(why)` (exists) then `DeleteAllPendingStops()`
  + `DeleteStrayOrders()`. Order matters: positions first, so a fill arriving
  mid-close is still caught by the close loop on the next pass.
- `ConfirmedFlat()`: zero positions and zero orders with our magic, and the
  last close deal visible in history (same standard as
  `PositionConfirmedClosed`). Partial failures are retried every pass with the
  existing `Complain` rate-limiting; nothing new is placed until flat.
- Log line per close: positions closed, orders cancelled, basket P/L, spread,
  reason (the spread note from `ExitBasketIfDue` carries over).
- ~~Remove `ExitBasketIfDue()` and the per-direction basket code left from
  Phase 1.~~ Kept: trailing and reversal use `Basket()`, `ShouldCloseBasket()`
  and `ExitBasketIfDue()` for the single position's basket take profit and
  stop loss. The grid never reaches them.

Progress 2026-10-03 — code done, tester runs pending:
- `Grid.mqh`, new "combined basket" section: `CombinedBasket()` (count, lots,
  profit + swap + commission over every position of ours, both sides);
  `BasketExitReason(strategy, basket)` ("" / target reached / basket stop loss
  reached, D3); `DeleteAllOrders()` (every order of ours, any type — the
  bracket-shaped `DeleteStrayOrders` keeps one per side and is not used for
  the grid); `BeginBasketClose()` / `NoteOpenPositions()` keep the list of
  positions the close is accountable for, including rungs that fill
  mid-close; `CloseBasketPass(why, cancelled)` closes positions first, then
  cancels orders; `BasketConfirmedFlat()` = no positions, no orders, and each
  noted position `PositionConfirmedClosed` in the deal history;
  `ClosedBasketProfit()` sums the noted positions' deals from history for the
  log.
- `GoldGrid.mq5` `ManageGridCycle`: the monitor runs first, in every state.
  Target reached → one CLOSING log line (reason, positions, lots, resting
  orders, spread) → `CloseLadderCycle()` every pass, paced at one close pass
  per 2 s while anything remains, then confirmation; stuck confirmation is
  reported every 5 min. On FLAT: one log line (positions closed, realised
  P/L from history, orders cancelled, reason, pause), cycle number +1, anchor
  released, `pause_until = TimeGMT() + grid_cycle_pause_seconds` (wall clock;
  in the tester TimeGMT follows the simulated server time). Placing resumes
  after the pause. With AllowTrading off a basket at target is reported, not
  closed, like the single-position exits.
- `OnTradeTransaction`: for a grid, a fill or a close runs `ManageBaskets()`
  at once, so a target reached between timer events is acted on without
  waiting (the Phase 5 plan item, done early because the monitor exists now).
- TEST SUMMARY gains `ladder_cycles_closed`, `ladder_closed_profit`,
  `open_positions`.
- Compiles 0 errors / 0 warnings. Not run: `grid`/`gridlimit` and the five
  regression scenarios — port 3000 still held by strategy #6.
- Known limits, for Phase 5: the closing flag and the pause live in memory. A
  restart mid-close recovers the cycle from whatever is still open and the
  monitor closes it again if the target still holds; a restart mid-pause
  starts the next cycle without the rest of the pause; a restart that finds
  nothing of ours starts at cycle 1. A risk halt (emergency stop, daily loss)
  closes and cancels through `EnforceRiskHalts` as before; when it clears, the
  same cycle resumes at its old anchor (Phase 6 decides what a halt does to
  the cycle).

Done when: tester run where 16 of 60 fill and the target hits closes 16 and
cancels 44 within two passes; a run where close requests are injected to fail
(chaos) keeps retrying and never places anything until flat.

### Phase 5 — Cycle state machine, persistence, restart

**Goal:** the cycle loop runs forever, survives a restart, and cannot double
up.

Files: new `mt5/Include/GoldGrid/Cycle.mqh` (`CCycleState`), `GoldGrid.mq5`.

States and transitions:

```
INITIALIZING ─reconcile─▶ PLACING ─ladder complete─▶ ARMED
     │                      ▲                          │ target reached
     │                      │ pause elapsed            ▼
     │                   COOLDOWN ◀─confirmed flat─ CLOSING
     └─unexplained broker state─────────────────────▶ RECOVERY
```

- `INITIALIZING`: compare the broker with the persisted state. Our orders or
  positions present → adopt them as the running cycle (restore cycle number
  and anchor from the persisted values or, failing that, from the order
  comments and prices) and go to `PLACING` if the ladder is incomplete or
  `ARMED` if complete. Nothing of ours present → `COOLDOWN` with the
  remaining pause (or `PLACING` if none).
- `PLACING`: Phase 3's `PlaceLadder`. Fills may already occur here; the
  monitor runs in `PLACING` and `ARMED` alike.
- `ARMED`: nothing to place; monitor only.
- `CLOSING`: Phase 4's close path until `ConfirmedFlat()`. A fill during
  `CLOSING` is closed by the same loop.
- `COOLDOWN`: `pause_until` is wall-clock (`TimeGMT`), persisted, so a
  restart does not skip it. Then increment the cycle number, take a fresh
  anchor, `PLACING`.
- `RECOVERY`: positions or orders exist that carry our magic but no cycle
  can be reconstructed, or the close has not confirmed after a timeout.
  Nothing new is placed; the monitor still closes the basket on target.
- Persisted in terminal globals `GoldGrid.<magic>.<symbol>.cycle.{state,number,anchor_bid,anchor_ask,pause_until}`,
  flushed on change (the pattern in `State.mqh`).
- `OnTradeTransaction`: on a `DEAL_ENTRY_IN` for our magic, run the monitor
  immediately rather than waiting for the timer; on `DEAL_ENTRY_OUT`, advance
  `CLOSING`.
- Duplicate protection: a ladder is placed only from `PLACING`; `PLACING` is
  entered only from `COOLDOWN` after `ConfirmedFlat()` or from
  `INITIALIZING` with an existing partial ladder. `SinglePositionMode()`
  stays false for the grid so the trailing/reversal state machine never runs.

Done when: a tester run of a full week cycles continuously; the cycle counter
only ever increases by one; `SimulateRestart` in each state resumes without a
duplicate order (the invariant monitor checks "no two orders of ours at the
same price and type"); the pause is honoured across a restart.

Progress 2026-10-03 — code done, tester runs pending:
- New `mt5/Include/GoldGrid/Cycle.mqh`: `ENUM_CYCLE_STATE`
  (INITIALIZING, PLACING, ARMED, CLOSING, COOLDOWN, RECOVERY),
  `CycleStateName`, `CCycleState` with `number`, `anchor_bid/ask`,
  `pause_until` persisted in `GoldGrid.<magic>.<symbol>.cycle.*` and flushed
  on every change (tester excepted, as in `State.mqh`). `Load()` restores the
  record and always restarts at INITIALIZING; `Set()` logs every transition
  with its reason; `Anchor`, `Adopt` (the broker's cycle wins outright),
  `Begin` (cycle 1), `NextCycle(pause)` (+1, anchor cleared, pause set, closed
  counter), `EndPause`, `PauseRemaining(configured)` (a pause longer than it
  was ever configured for means the PC clock stepped back, and is over).
- `GoldGrid.mq5`: the Phase 3/4 in-memory `g_ladder_*` cycle is gone;
  `g_cycle` drives `ManageGridCycle()`:
  - the monitor runs first in every state but INITIALIZING and CLOSING, so a
    basket at target closes from RECOVERY and COOLDOWN too;
  - `ReconcileCycle()` (INITIALIZING): ours on the broker → adopt the cycle
    from the order comments (`RecoverLadder`), else continue from the record
    if it has an anchor, else RECOVERY; nothing of ours → COOLDOWN with the
    remaining pause, or cycle 1, or (a cycle was under way) retire its number
    and COOLDOWN — a risk halt or a manual close-all ended it outside the EA;
  - `PlaceCycle()` (PLACING, ARMED): hygiene, the "ended outside the EA"
    check (10 s settle after a send), anchor follows the market until the
    first send, `PlaceLadder` with a budget of 10 in PLACING and 0 in ARMED —
    ARMED only looks, and a missing rung sends it back to PLACING. The gate
    is re-asked once a second while it refuses, not per tick;
  - `BeginCycleClose` / `CloseCycle()` (CLOSING): Phase 4's close, then
    `NextCycle` + COOLDOWN; `CooldownCycle()` → PLACING when the pause is
    over; `RecoverCycle()`: withdraws orders that belong to no cycle, leaves
    positions to the monitor, and resumes with a new cycle once nothing of
    ours remains. `ReportIfStuck` says so every 5 min in CLOSING/RECOVERY.
  - `OnInit` (live and tester) configures and loads `g_cycle` and logs the
    record found; `SimulateRestart` reloads it, so the tester's restarts
    exercise INITIALIZING in every state.
- `Tester.mqh`: `CInvariantMonitor::CheckGrid(cycle, placing)` — no two
  orders of ours of one type at one price for more than 5 s (a chaos stray is
  given that long to be cleaned up); the cycle number never goes backwards or
  jumps by more than one; tracks peak positions. Called from the grid branch
  of `TesterTick`. TEST SUMMARY: `cycle`, `cycle_state`, `cycles_closed`,
  `cycle_recoveries`, `ladder_max_orders`, `ladder_requests`,
  `ladder_closed_profit`, `resting_orders`, `open_positions`.
- Compiles 0 errors / 0 warnings. Not run: the "done when" checks — port
  3000 still held by strategy #6.
- For Phase 6: a strategy stopped on the platform, a stale configuration,
  spread and the risk halts are still only the `MayOpen` refusal (the
  ladder stays resting) or `EnforceRiskHalts` (which closes and cancels, after
  which `PlaceCycle` sees nothing left and retires the cycle). Phase 6
  decides what each gate does to a resting ladder and an open basket.

### Phase 6 — Risk and market gates

**Goal:** the account-level protections apply to the cycle the way they apply
to the other categories, and the market calendar is respected.

Files: `GoldGrid.mq5`, `Grid.mqh`.

- `EnforceRiskHalts()` (daily loss, emergency stop) already closes positions
  and cancels orders. The cycle must observe it: a halt forces `CLOSING`, and
  after the halt clears the cycle restarts from `COOLDOWN`.
- `MayOpen` gates on ladder placement: config stale, not running, market
  closed, netting account (D2), max positions, max exposure, drawdown,
  margin. The spread gate does not apply to resting orders (the comment in
  `MayOpen` explains why) but does apply to nothing else here since the grid
  never sends a market order.
- Strategy stopped on the platform: no new cycle (`PLACING` and `COOLDOWN`
  wait), but a live basket keeps its target and close path, consistent with
  the header's "stopping is not close everything".
- Market closed: no requests; `TradingGate()` already covers it.
- `InpFlatBeforeBreakMinutes`: decide whether the grid goes flat before the
  daily break like the reversal does. Default: **no**; resting stop orders
  and open positions are held by the broker and the basket exit resumes at
  the open. Document the choice.
- Margin: 60 × 0.01 lots on gold is small, but `MarginTooLow` runs on each
  placement so a larger lot is caught before the ladder is complete.

Done when: tester `dailyloss` variant for the grid closes everything, waits
for the next day and cycles again; stopping the strategy mid-cycle leaves
the ladder and basket managed and places nothing new; a netting account
refuses with one clear log line.

Progress 2026-10-05 — code done, tester runs pending:
- `EnforceRiskHalts`: for a grid the halt no longer cancels and closes
  directly. It begins the cycle's own CLOSING (reason "risk halt — …") and
  drives `CloseCycle()` each pass, so the close is confirmed with the broker
  and the cycle retired; INITIALIZING still reconciles under a halt.
  `CooldownCycle` will not start PLACING while a halt is in force or the
  strategy is stopped (one log line per reason), so the ladder is not anchored
  and refused every pass.
- `PlaceCycle`: a stopped strategy withdraws resting rungs (paced, one log
  line with the counts) and leaves the basket to the monitor (D8). This check
  runs before the "ended outside the EA" check, so a stop does not retire the
  cycle by itself.
- Netting account: refused in `MayOpen` (`GATE_NETTING_OPPOSITE`) and in
  `PlaceCycle` with one log line. Stale configuration: `GATE_CONFIG_STALE`
  from `MayOpen`; resting rungs stay (D8). Market closed: `ManageBaskets`
  returns before the cycle runs, as for every category. Margin: `MarginTooLow`
  in `MayOpen` per rung. Break: D9, documented in the EA header.
- Compiles 0 errors / 0 warnings. Not run: `griddailyloss`.

### Phase 7 — Reporting and platform UI

**Goal:** the platform shows what the cycle is doing.

Files: `GoldGrid.mq5` (`BuildReportJson`), `app/helpers/strategies_helper.rb`,
`app/views/strategies/_execution_state.html.erb`, `show.html.erb`,
`app/controllers/api/v1/trading/reports_controller.rb`,
`app/services/trading/ingest_report.rb`, `test/integration/ea_contract_test.rb`.

- `execution.state` sends `PLACING | ARMED | CLOSING | COOLDOWN | RECOVERY`
  with `reason` as today. Add `cycle` (number), `resting_orders`,
  `filled_orders` to the block; the platform permits and stores them (new
  `TerminalConnection` columns or a JSON column, whichever the existing
  pattern prefers).
- `grid_level` on positions and orders uses the new comment parser.
- Helper `EXECUTION_STATES` maps the new names to indicators; the Robot state
  card shows cycle number, filled/resting counts, basket P/L vs target, and
  pause remaining in `COOLDOWN`. Remove the "GRID" row and the stale comment
  in `_execution_state.html.erb`.
- Contract test pins the new `execution` keys.

Done when: Rails green; the strategy page shows the cycle changing state in a
demo run or with `bin/simulate_terminal`.

Progress 2026-10-05 — done:
- EA `BuildReportJson`: `execution.state`/`reason` come from `g_cycle` for a
  grid (`g_state` for the others); new keys `cycle`, `resting_orders`,
  `filled_orders`, `basket_profit` (string, combined floating P/L),
  `pause_seconds_left` (0 outside COOLDOWN), all `null` for trailing and
  reversal. Orders carry `grid_level` (the rung, 0 for a non-ladder order).
- Migration `20261005120000_add_grid_cycle_to_terminal_connections`:
  `cycle_number`, `resting_orders`, `filled_orders`, `basket_profit`
  (decimal 15,2), `pause_seconds_left`. Migrated locally. **Run it on the
  Docker app together with `20261003120000` before deploying the EA.**
- `reports_controller` permits the keys; `Trading::IngestReport` stores them
  (`whole_number` tolerates nulls and junk); `StrategiesHelper::EXECUTION_STATES`
  drops `GRID` and adds `PLACING` (running, "Placing the ladder"), `ARMED`
  (live, "Ladder in place — watching the basket"), `COOLDOWN` (running, "Flat —
  pausing before the next cycle"). `_execution_state.html.erb` shows Cycle,
  Ladder (filled · resting), Basket P/L against the take profit, and "Next
  cycle in N seconds" in COOLDOWN; the reversal rows and today's P/L are
  unchanged.
- Tests: `ea_contract_test` pins the new execution keys (null for a reversal
  report, stored for a grid report, cleared when absent) and a ladder order's
  `grid_level`; `strategy_live_view_test` covers an ARMED grid and a COOLDOWN
  grid. `bin/simulate_terminal`'s default scenario now reports a grid cycle
  (`execution` block, buy/sell stop ladder).
- Rails: 605 runs, 0 failures; RuboCop clean.

### Phase 8 — Tester scenarios, invariants, backtests, docs, template

**Goal:** evidence, then deployment artefacts.

Files: `mt5/Include/GoldGrid/Tester.mqh`, `bin/mt5_backtest`, `mt5/README.md`,
`doc/MT5_INTEGRATION.md`, `doc/TESTING.md`, `docker/mt5-worker/prepare-template.sh`.

- Invariant monitor, grid mode: never more than `max_positions` positions +
  orders; never two of our orders at the same type and price; never an order
  from a cycle other than the current one; after `CLOSING` confirms, zero
  positions and orders; the cycle number strictly increases; the pause is
  never shorter than configured.
- Scenarios in `bin/mt5_backtest`: `grid` (30/30/200/$2, no chaos),
  `gridchaos` (rejected closes and placements injected), `gridrestart`
  (restart in every state), `gridlimit` (order limit below the ladder size
  via a tester input), `griddailyloss`.
- `--monthly` sweep over the real-tick months for a sanity read of
  behaviour (not a profitability claim).
- Docs: `mt5/README.md` "How the grid works" and the checklist rewritten;
  `doc/MT5_INTEGRATION.md` grid block, execution block, and the stale 409
  claim fixed while there; `doc/TESTING.md` grid section.
- `docker/mt5-worker/prepare-template.sh` recompiles the template; keep the
  previous build as `GoldGrid.ex5.pre-ladder`.

Done when: all grid scenarios pass with 0 violations alongside the existing
five; docs match the code; template rebuilt.

Progress 2026-10-05 — code and docs done, runs pending:
- `CInvariantMonitor::CheckGrid(cycle, state, placing, max_allowed, pause,
  strategy_id)`: duplicates (5 s grace), cycle number monotone by one,
  positions + resting orders ≤ max_positions (60 s repair window for the
  chaos engine's injected position), no order from another cycle or strategy
  id (5 s grace), CLOSING→COOLDOWN with nothing left, COOLDOWN ≥ configured
  pause. `CChaosEngine` gains `restart_only` (`InpChaosRestartOnly`).
- `bin/mt5_backtest`: `grid`, `gridchaos`, `gridrestart`, `gridlimit`,
  `griddailyloss` share one input block and are in the default set with the
  five existing scenarios. `--monthly` stays reversal-only for now.
- Docs: `mt5/README.md` (categories table, hedging note, "How the grid
  works" rewritten around the cycle, restart table, gates, backtest table,
  grid invariants, summary fields, grid demo checklist, limitations);
  `doc/MT5_INTEGRATION.md` (execution block documented, grid example);
  `doc/TESTING.md` (grid stage 3, simulator note).
- `docker/mt5-worker/prepare-template.sh` keeps the build it replaces as
  `GoldGrid.ex5.previous`.
- Backtests run 2026-10-05/06 (§3c): all ten scenarios pass with 0
  violations after one fix. Both migrations are applied on the Docker app.
- **Not done:** the template recompile (`docker compose stop app &&
  docker compose run --rm app docker/mt5-worker/prepare-template.sh &&
  docker compose start app`). It replaces the EA every terminal is started
  from, so it is left to be run by hand; the build it replaces is kept as
  `GoldGrid.ex5.previous`.

### Phase 9 — Demo run and sign-off

Checklist on a demo hedging account, `InpAllowTrading` on. Run 2026-10-06
from the Docker platform on the MetaQuotes demo account (strategy #8, a
3 + 3 ladder, 200 points, 0.01 lots, $0.30 target, 10 s pause, so a cycle
completes in minutes; strategy #6 was stopped meanwhile because the platform
allows one running strategy per symbol):

- [x] Ladder appears at 200-point gaps, nearest at ≥ stops level — 6 orders in 1.3 s, platform lists the same six with levels
- [x] Only the levels price reaches fill; the rest stay pending — sell rung 1 filled at its price, five rested
- [x] Basket P/L on the platform equals the terminal's combined floating P/L — −1.23 both
- [x] Target reached → all positions close, all orders cancel, log shows counts — "1 position(s) closed for 0.40, 5 order(s) cancelled"
- [x] 10 s later a new ladder appears at the new market price, cycle + 1
- [x] Terminal restart mid-cycle: same tickets after as before, no new orders — "cycle 1 adopted from the broker — 5 order(s) resting, 1 position(s) open, 1 rung(s) filled so far"
- [x] Stopping the strategy: rungs withdrawn, no new cycle — "withdrew 6 resting ladder order(s)" 8 s after the stop
- [x] Emergency stop: the halt engages within seconds (nothing open at the time)
- [x] Broker order limit below 60 — proven by the `gridlimit` backtest; the demo account's limit is above 60
- [ ] A week unattended with no invariant violation in the log — the user's run

Found during the run:
1. **A fresh strategy inherits the terminal's day.** The magic number belongs
   to the user's terminal (`Mt5Instance#magic_number`), not to the strategy,
   so `TodayProfit()` summed the reversal's −50.31 and the grid (limit $20)
   started under a daily-loss halt; raising its limit cleared it at once.
   The same sharing means a position left open by a stopped strategy is
   "ours" to the next one: a grid would sit in RECOVERY ("no cycle can be
   reconstructed") until that position closes. Documented in `mt5/README.md`;
   whether `Strategies::Start` should refuse while the terminal still holds
   another strategy's position is a product decision left open.
2. **A filled stop order read "cancelled"** in the platform's order history
   (the ingest marked every vanished order cancelled). Fixed: a vanished order
   whose ticket is now a position of the strategy is "filled" (MT5 keeps the
   ticket). Test added; Rails 606 runs / 0 failures.
3. The report's execution reason now carries the placement gate while one
   applies ("the strategy is stopped", "AllowTrading is OFF"), instead of the
   last transition's text, which read "ladder complete — 6 resting" after the
   rungs had been withdrawn.

Template recompiled with the tested build (2026-10-06); the build it replaced
is `GoldGrid.ex5.previous`.

---

## 3b. Review of Phases 3–5 (2026-10-05)

A read-only review of the ladder code found four bugs and a dozen points to
harden. All are fixed in the same day's build; the tester runs that would
show them are still pending (port 3000).

Confirmed bugs, fixed:
1. **Duplicate rung from list lag after a send (live only).** The broker's
   order list can lag `OrderSend` by hundreds of ms and ticks can arrive
   faster; a second pass could re-send a rung not yet listed. Now nothing is
   sent and nothing concluded from the lists for `LADDER_SEND_SETTLE_MS`
   (2 s) after any request.
2. **D6 violated after a manual close.** A filled rung whose position was
   closed by hand (or by the chaos engine) was re-placed. The engine keeps a
   per-cycle *filled set* (`NoteFillDeal` from the fill transaction,
   `RebuildFilled` from the deal history since the anchor on a restart) and
   `PlaceLadder` treats a rung in it as held.
3. **Restart mid-CLOSING resurrected the ladder.** `CCycleState::Load` kept
   the previous state only for the log; INITIALIZING adopted the positions
   and re-placed every cancelled rung. `Previous()` is now acted on: CLOSING
   → the close is resumed; RECOVERY → stays RECOVERY.
4. **Deterministic broker rejection → one request per tick.** A rejected
   rung now sets `report.refused` (so the once-a-second pacing applies) and
   the crossed test uses `<=`.

Hardened:
- `halted` (revoked token, wrong symbol) stops placing at once, not after the
  120 s config-stale window.
- "Nothing of ours" is only believed with the terminal connected and 5 s
  after start (`CYCLE_SETTLE_AFTER_START_MS`), live.
- `RecoverLadder` derives each side of the anchor from its own lowest rung
  and only infers a side with nothing resting from the other plus the spread;
  rung 1's offset (`first`) is persisted with the cycle so a stop level the
  broker changes mid-cycle does not move the ladder.
- The ladder's shape (gap, buy, sell, first) is snapshotted at the anchor
  (`LadderShape()`); a setting changed on the platform applies to the next
  cycle (D8 corollary).
- ARMED re-checks once a second while a rung is skipped, so D5's "placed
  when the market comes back" actually happens without waiting for a fill.
- Commission per position is cached (`CachedCommission`); hygiene runs behind
  the pacing, not on every tick.
- The tester's `SimulateRestart` now drops the engine's run state too
  (`ForgetRunState`), so a chaos restart in CLOSING loses what a real one
  loses.
- The cycle record is touched hourly (`Touch`); terminal globals untouched
  for four weeks are deleted.
- A basket closed under a cycle that never anchored (a position injected
  during COOLDOWN) keeps its number (`RestartPause`).
- Invariant 3 is measured on rungs (positions carrying this cycle's comment)
  plus resting orders, since the chaos engine's injected position legitimately
  stays in the basket until the target; invariant 7 added: no rung fills
  twice in a cycle (`NoteGridFill` from the fill transaction).

Known and accepted: a broker that strips order comments defeats the filled
set and the comment-based recovery (price fallbacks remain); `PauseRemaining`
uses the current configured pause, so shortening it mid-cooldown ends the
pause at once.

### Second review (2026-10-05, whole diff)

An independent pass over the full working tree. Confirmed bugs, all fixed:
1. **The strategy form's HTML was unbalanced.** The trailing-stop card's new
   header had been inserted in front of the old one instead of replacing it,
   so with JavaScript on, every later card (basket exits, risk controls, the
   submit button) sat inside the hidden-for-grid section and a grid could not
   be created or edited from the form. The integration tests do not run
   JavaScript, which is why they passed. Fixed; the file's tags balance again.
2. **A cycle could run as cycle 0.** Positions found in RECOVERY before any
   cycle existed, closed at target, led to COOLDOWN and then PLACING with
   number 0 — whose comments `C0` the filled set ignores and the recovery
   cannot read. `CloseCycle` and `CooldownCycle` now raise the number to 1
   before continuing.
3. "2 filleds" on the Robot state card. Fixed.
4. **Retiring a cycle on a transient empty list (live).** `PlaceCycle` now
   requires the empty picture to hold for 5 s with the terminal connected
   (`g_ladder_empty_since`), as INITIALIZING already did.

Hardened:
- INITIALIZING no longer adopts rungs of a cycle LOWER than the record's: they
  are leftovers of a retired cycle (orders → COOLDOWN withdraws them;
  positions → RECOVERY), so the number never rolls back.
- Recovery reads the broker with the record's snapshotted shape and keeps that
  shape in `Adopt` when the cycle matches; the live configuration is used only
  for a cycle the record did not know.
- The lot is part of the snapshot too (`cycle.lot`); a lot changed on the
  platform applies to the next cycle.
- ARMED re-checks once a minute while the ladder is cut by the broker's order
  limit, so freed room is used.
- `LadderRungHeld`'s price fallback applies only to a position with an EMPTY
  comment (a comment-stripping broker), not to any position lacking `:C`.
- Invariant 7 is keyed by order ticket, so a partial fill is one fill.
- The report's `filled_orders` counts open rungs of the current cycle, not
  every position.
- Migration `20261003120000` back-fills each side as
  `LEAST(grid_levels, GREATEST(max_positions / 2, 1))` so an existing grid's
  ladder fits its own ceiling. An existing grid without a basket take profit
  must be given one before it can run — the new grid has no other exit.
- Tester checks 5 and 6 compare against what the cycle recorded (the closed
  cycle's rung comments, the pause deadline) rather than when the monitor
  happened to look, so a transition seen late cannot fire falsely; COOLDOWN
  withdraws any order of ours that appears during the pause.

Rails after the fixes: 605 runs, 0 failures; RuboCop clean. EA: 0 errors,
0 warnings. Still not run: the ten backtests (by instruction — the server
is stopped and nothing is to be started).

## 3c. Backtest round (2026-10-05 → 2026-10-06)

`bin/mt5_backtest --pause-app`, all ten scenarios, XAUUSD M1, 1–26 Sep 2026,
every tick generated from M1. Strategy #6 (reversal, flat) was stopped for
the run and started again afterwards.

**Found and fixed — the only defect:** the Buy Stop and the Sell Stop of one
level share a comment (`GG:<id>:C<cycle>:L<level>`), and two places matched
on the comment alone:
1. `CGridEngine::LadderRungHeld` returned true for a sell rung when the *buy*
   rung of the same level was the open position (and vice versa). A missing
   sell rung — skipped because the market had crossed it, or rejected — would
   not have been placed again while its buy twin was open. Now a position
   counts only when its type is the rung's side, for the comment match and
   the empty-comment price fallback alike.
2. Tester invariant 7 keyed fills by comment, so a buy rung 1 and a sell
   rung 1 filling in one cycle read as "filled twice" — all 425 violations in
   `grid` and 280 in `gridchaos` were this. `NoteGridFill` now takes the
   deal's side.

Both reruns produced the same trades as before the fix (the EA had never
actually placed a rung twice: checked from the logs, no `(cycle, side, rung)`
was sent more than once in either run), so the fix changed the check and a
latent live path, not the behaviour under test.

| Scenario | Violations | Trades | Cycles closed | Restarts | Peak positions + orders | Net |
| --- | --- | --- | --- | --- | --- | --- |
| `baseline` | 0 | 5 214 | — | 0 | 1 | +1 807 |
| `chaos` | 0 | 5 402 | — | 250 | 2 | +1 716 |
| `trailing` | 0 | 4 322 | — | 255 | 2 | −245 |
| `dailyloss` | 0 | 1 770 | — | 0 | 1 | +806 |
| `spread` | 0 | 5 203 | — | 0 | 1 | +1 748 |
| `grid` | 0 | 2 643 | 653 | 0 | 46 | +862 |
| `gridchaos` | 0 | 1 840 | 395 | 234 | 78 (chaos injections, repaired in time) | −1 855 |
| `gridrestart` | 0 | 2 643 | 653 | 2 501 | 46 | +862 |
| `gridlimit` | 0 | 1 054 | 251 | 0 | 40 (= the pretended limit) | −371 |
| `griddailyloss` | 0 | 1 204 | 339 | 0 | 25 | −226 |

Profit figures are not the point (§5); what the table shows:
- `gridrestart` equals `grid` trade for trade with a restart every ten
  simulated minutes (2 479 from ARMED, 7 from PLACING, 10 from COOLDOWN,
  5 from CLOSING): the record plus the broker's lists reconstruct the cycle
  exactly. A restart inside CLOSING (the close completes within the tick in
  the tester) resumes as "cycle ended outside the EA": number +1, pause
  applied, nothing re-placed.
- `gridchaos`: every chaos manual close left the rung unplaced for the rest
  of the cycle; every stray order was deleted as "not a rung of ladder cycle
  N"; the 233 restarts adopted the cycle from the broker.
- `gridlimit`: capacity 40 in all 488 ARMED transitions; `ladder_max_orders`
  40.
- `griddailyloss`: 18 daily-loss halts, each `ARMED -> CLOSING (risk halt …)`,
  basket closed and cancelled, `risk halt cleared` at the next trading day.

Also exercised against the platform (local server, `bin/simulate_terminal
--once` with the grid scenario): the report is stored (`cycle_number`,
`resting_orders`, `filled_orders`, `basket_profit`), orders carry
`grid_level`, and the strategy page shows "Ladder in place — watching the
basket", "Cycle 1", "4 filled · 6 resting", "Basket P/L +90.64 of 2.00
target"; strategies list, new/edit form and dashboard render without error.
Rails 605 runs / 0 failures, RuboCop clean, EA 0 errors / 0 warnings.

Left for the user: the template recompile (Phase 8) and the demo checklist
(Phase 9).

## 4. Order of work and why the chain holds

1. **Phase 1 before everything:** the new cycle manager takes the place the old
   grid branch occupies in `ManageBaskets`/`ManageDirection`. Removing first
   keeps every later diff small and makes the trailing/reversal regression
   check meaningful.
2. **Phase 2 before 3:** placement needs the counts, gap, pause and target as
   struct fields, and the tester needs to build them from inputs so Phases
   3–6 can be driven headless without the platform.
3. **Phase 3 before 4:** there is no basket to monitor until orders can fill.
4. **Phase 4 before 5:** the state machine's `CLOSING → COOLDOWN` edge depends
   on a reliable `ConfirmedFlat()`.
5. **Phase 5 before 6 and 7:** gates and reports both act on cycle states that
   do not exist earlier.
6. **Phase 8 after 6 and 7:** the invariants and scenarios exercise the full
   behaviour, and the docs describe the finished contract.
7. **Phase 9 last:** real broker, real clock, real spreads.

## 5. Out of scope

- Profitability. The plan proves the mechanics, not the edge.
- Changes to the trailing and reversal categories beyond keeping them green.
- Per-position stops or trailing on grid positions (the spec has one exit).

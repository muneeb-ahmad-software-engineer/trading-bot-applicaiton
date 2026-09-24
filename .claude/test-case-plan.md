# Test Case Plan

A gap analysis of the whole codebase against the existing test suite, plus an
exhaustive edge-case sheet for the part we cover first.

**Framework:** Minitest (Rails default). 35 test files, ~3,700 lines, run by CI
via `bin/rails db:test:prepare test test:system`. This plan adds to that suite;
it does not propose replacing it.

**Legend**
- ✅ **Covered** — a dedicated test asserts this behaviour.
- 🟡 **Partial** — exercised incidentally through an integration test, but no
  test names the behaviour, so a regression could pass silently or fail with a
  confusing message.
- ❌ **None** — no test touches it.
- 💤 **Skip** — deliberately not worth a test (rationale given in §5).

---

## 0. Work completed

**Bugs found and fixed** (both were live defects, confirmed by probe against the
test database, and both are now pinned by a test that fails if the fix is reverted):

1. **`Strategy#start!` on an already-running strategy silently moved `started_at`
   forward.** The partial unique index cannot catch this — a row does not
   conflict with itself — so the model had no guard and only
   `Strategies::Start`'s precondition stood between a double-start and a lost
   go-live timestamp. That timestamp is what the audit trail and every
   since-start P/L figure are read against. `start!` now raises
   `Strategy::AlreadyRunning`. No user-visible message changed: the service's
   guard clause still answers first.
2. **A compounding grid produced an unreadable validation message.** 200 levels
   at a 2.0 multiplier yields a 59-digit lot total, which was interpolated into
   the error verbatim — a 168-character wall of numerals where the user needed a
   quantity. Totals above `DISPLAY_LOT_CEILING` (1,000,000) now read "more than
   1,000,000 lots"; ordinary totals print exactly, with separators.

3. **`PushSubscription.active` and `#expired?` disagreed about which devices are
   retired.** The scope read `failed_at IS NULL OR failure_count < 5`, so a row
   with a high count and no timestamp was "active" while `expired?` called it
   dead. That state is reachable: `record_failure!` writes the counter and the
   timestamp separately, so a process dying between the two leaves exactly it.
   Latent rather than user-visible — the sender self-heals on the next failure —
   but two definitions of one predicate is how drift starts. The scope is now
   the exact complement of `expired?`.

**Tests written**

| File | Tests |
|---|---|
| `test/models/strategy_test.rb` | 14 → 53 |
| `test/models/push_subscription_test.rb` | new, 16 (3 moved out of `notifications_delivery_test.rb`, where they were misfiled as service tests) |
| `test/services/push_sender_test.rb` | new, 23 |
| `test/jobs/deliver_push_notification_job_test.rb` | new, 8 |

Suite total 321 → 409 runs / 1,607 assertions, all green, rubocop clean.

**Test infrastructure added:** `stubbing(receiver, method, replacement) { ... }`
in `test_helper.rb`. Minitest 6 dropped `minitest/mock`, and this project
carries no mocking gem, so there was no way to stand in for a push service that
is slow, gone, or refusing an endpoint — and those responses *are* the
behaviour under test. Deliberately small, and for external seams only.

**Verified as correct, not bugs** (probed and left alone): `lot_multiplier == 1`
does not divide by zero (the `> 1` guard holds); `initial_lot: 0.001` is
rejected rather than rounded to zero; the controller `defaults` hash validates;
`params.expect` drops injected `status`/`user_id`; the partial unique index
holds against `update_column`; enum `validate: true` returns errors rather than
raising; `only_integer` rejects `150.5` despite the column casting it to `150`.

---

## 0b. Execution manager (added later)

New subsystem, built with tests alongside it rather than after: `WorkerNode`,
`Mt5Instance` (state machine), `Mt5InstanceEvent`, `BrokerCredential`, the
`Mt5::Runtime` adapters and the `Mt5::*` lifecycle services. 75 tests across
`test/models/mt5_instance_test.rb` and
`test/services/mt5/execution_manager_test.rb`. Architecture is documented in
`doc/EXECUTION_ARCHITECTURE.md`.

Two defects were found by those tests during construction and fixed: `failed →
stopping` was not a permitted transition (so a crashed terminal could never be
cleaned up), and account deletion had no path to tear down a live terminal.

---

## 1. Coverage map by layer

### 1.1 Models — `app/models/`

| File | Status | What is missing |
|---|---|---|
| `strategy.rb` | ✅ | **Done.** Expanded 14 → 53 tests covering every validation boundary, both lot-arithmetic branches, the full lifecycle and the `dependent:` behaviour. Two bugs found and fixed — see §0. |
| `user.rb` | ✅ | Solid across `user_test.rb` + `two_factor_test.rb`. |
| `api_token.rb` | ✅ | Good. Missing only: `PREFIX` shape of a generated token, `expires_at` exactly at boundary. |
| `event.rb` | ✅ | Missing: `#description` — every branch of that case statement is unasserted, and it is user-visible on `/activity`. |
| `terminal_connection.rb` | ✅ | Missing: `#status` returning `:never_connected` vs `:stale` vs `:live` as a value (tests assert `live?` only); `spread_points_or_derived` when only one of bid/ask is present. |
| `recovery_code.rb` | 🟡 | Tested through `two_factor_test.rb`. No direct test of `normalize` against odd input, or the concurrent-consume guarantee (`update_all` returning 0 for the second caller) that the comment claims. |
| `position.rb` | ❌ | `net_profit` with nil swap/commission, `open?`, the `open`/`closed`/`recent_first` scopes, ticket uniqueness **scoped to strategy** (two strategies may legitimately share a ticket number), `volume`/`open_price` > 0. |
| `order.rb` | ❌ | Same shape as Position: `TYPES`/`STATUSES` inclusion, ticket uniqueness scope, `pending` scope. |
| `account_snapshot.rb` | ❌ | `balance`/`equity` numericality, `latest_first` ordering, `strategy` optional (survives strategy deletion via `dependent: :nullify`). |
| `notification.rb` | 🟡 | `mark_read!`/`resolve!` idempotence, `open_for` scoping to user, `alert_type` inclusion against the live `AlertType.keys` lambda. |
| `notification_preferences.rb` | 🟡 | Covered via `notification_settings_test.rb`. No direct test of `enabled?` returning false for an unknown alert type or unknown channel, or of `update` dropping keys not in the catalogue. |
| `push_subscription.rb` | ✅ | **Done.** 16 tests in a dedicated file: subscribe/re-subscribe (keys refreshed, failures revived, endpoint re-pointed to another account), the expiry boundary, and scope/`expired?` agreement. One bug fixed — see §0. |
| `alert_type.rb` | ❌ | `default_preferences` shape, `mandatory?`/`severity`/`title` fallbacks for an unknown key. |
| `session.rb`, `current.rb`, `application_record.rb` | 💤 | No logic. |

### 1.2 Services — `app/services/`

| File | Status | What is missing |
|---|---|---|
| `strategies/start.rb` | 🟡 | 8 tests. Missing the two distinct `already_running` paths (same strategy vs a sibling), and that a failed audit write does not fail the start. **See §4.6.** |
| `strategies/stop.rb` | 🟡 | Stopping a **draft** (never started) strategy; stopping twice. |
| `trading/ingest_report.rb` | 🟡 | Heavily exercised by `api_v1_trading_test.rb` and `ea_contract_test.rb` but has **no unit test**. Untested: partial-failure rollback (an invalid position aborts the whole transaction — is the connection upsert rolled back too?), `first_report` event firing exactly once, `symbol` defaulting, an empty `orders: []` cancelling pendings, a ticket arriving as integer vs string. |
| `notifications/deliver.rb` | ✅ | Good. |
| `notifications/resolve.rb` | ✅ | Covered via `alerts_test.rb`. |
| `notifications/push_sender.rb` | ✅ | **Done.** 23 tests: VAPID-absent, payload shape and tag, urgency mapping, 410/404 → immediate removal, transient-failure escalation to the limit, recovery, per-device failure isolation, and user scoping. |
| `alerts/monitor_terminals.rb` | ✅ | Strong (13 tests). |
| `application_service.rb` | 🟡 | `Result#success?`/`failure?` are asserted everywhere implicitly; a two-line direct test would be cheap. |

### 1.3 Controllers — web

| File | Status | What is missing |
|---|---|---|
| `strategies_controller.rb` | 🟡 | See §4.7 — mass-assignment of `status`, the `defaults` hash actually validating, `previous_changes` metadata. |
| `sessions`, `registrations`, `passwords`, `two_factor_*`, `reauthentications`, `recovery_codes`, `email_verifications` | ✅ | Well covered by the auth/2FA/verification integration tests. |
| `api_tokens_controller.rb` | 🟡 | Issue/revoke covered; not covered: the plaintext shown exactly once and never again on reload, `name` blank → error. |
| `dashboard_controller.rb` | 🟡 | Covered through `realtime_dashboard_test.rb`. |
| `trading_history_controller.rb` | ✅ | 9 tests including filters and pagination. |
| `notification_settings`, `notifications`, `push_subscriptions` | ✅ | Covered. |
| `activity_controller.rb` | 🟡 | Scoping tested; pagination and the rendering of every `Event#description` branch are not. |
| `profiles`, `settings` | 🟡 | Reachability only (`route_skeleton_test.rb`). No assertion on what they display. |
| `errors_controller.rb`, `pwa_controller.rb`, `pages_controller.rb` | ✅ | Covered. |
| `design_system_controller.rb` | ✅ | Covered, incl. not routed in production. |
| `concerns/authentication.rb` | 🟡 | Sudo mode, pending-auth window and `no-store` are covered. **Not** covered: `return_to_after_authenticating` for a **HEAD** request (the code explicitly handles it), `resume_session` with a signed cookie pointing at a deleted Session row. |
| `concerns/api_authentication.rb` | ✅ | Good. |

### 1.4 Controllers — API `/api/v1`

| File | Status | What is missing |
|---|---|---|
| `strategies_controller.rb` | 🟡 | 11 tests. Missing: `ParameterMissing` → 400, the exact `status_for` mapping per code, no `destroy` route existing. **See §4.8.** |
| `auth_controller.rb` | ✅ | Covered incl. 2FA over API. |
| `trading/reports_controller.rb` | ✅ | Strong. |
| `trading/account|positions|orders|history` | ✅ | Covered. |
| `status_controller.rb`, `profiles_controller.rb` | ✅ | Covered. |
| `base_controller.rb` | ✅ | Covered by `error_handling_test.rb`. |

### 1.5 Serializers

| File | Status | What is missing |
|---|---|---|
| `application_serializer.rb` | ✅ | Good — fixed-scale strings pinned. |
| `strategy_serializer.rb` | 🟡 | EA contract pinned. Missing: `lot_multiplier` null in fixed mode, `started_at` null on a draft. |
| `position|order|account_snapshot|terminal_connection|user` | ✅ | Covered by `serializer_test.rb`. |

### 1.6 Jobs, mailers, channels, queries, helpers

| File | Status | What is missing |
|---|---|---|
| `jobs/deliver_push_notification_job.rb` | ✅ | **Done.** 8 tests including `discard_on RecordNotFound`, `pushed_at` only on real delivery, the nil-payload failure Result, and one end-to-end pass from `Deliver` through to the device. |
| `jobs/monitor_terminals_job.rb` | ❌ | No test that the job enqueues/runs the service. |
| `mailers/*` | ❌ | **No mailer tests at all** (`test/mailers/` holds only a preview). Missing: `AlertMailer` subject prefix `[Action needed]` for critical only, `full_url` joining a relative path, recipient correctness, and that `EmailVerificationMailer` embeds a working token. |
| `channels/application_cable/connection.rb` | 🟡 | Rejection path covered by `realtime_dashboard_test.rb`; no direct connection test. |
| `queries/dashboard_snapshot.rb` | 🟡 | Asserted indirectly. Missing: `running` when **no** strategy runs, `positions` returning `[]` for a draft, `basket_profit` with nil components, `last_report_iso` nil-safety. |
| `helpers/trading_helper.rb` | ✅ | 8 tests, good. |
| `helpers/navigation_helper.rb` | 🟡 | Behaviour asserted through `app_navigation_test.rb`, not unit-tested. |
| `helpers/application_helper.rb` | ❌ | Unreviewed for logic. |

### 1.7 System tests

`test/system/` is **empty**, yet CI runs `bin/rails test:system` and
`application_system_test_case.rb` + Capybara/Selenium are installed. Either add
browser tests for the flows that only exist in JS (Stimulus controllers, the
mobile "more" sheet, the staleness timer on the dashboard) or the system-test
step is dead weight in CI.

---

## 2. Priority order

1. **Strategy — exhaustive** (§4). It is the product's core, it holds the most
   arithmetic, and a wrong number here is a real-money bug.
2. `Notifications::PushSender` + `DeliverPushNotificationJob` — a whole delivery
   path with zero tests, and it is the mechanism that tells a user their bot died.
3. Mailers — same argument; the alert email is the primary channel.
4. `Trading::IngestReport` unit tests — transaction/rollback semantics that
   integration tests cannot isolate.
5. `Position` / `Order` / `AccountSnapshot` model tests.
6. `Event#description` branches (user-visible strings).
7. `DashboardSnapshot` empty-state unit tests.
8. System tests, or drop `test:system` from CI.

---

## 3. Supporting work needed first

- **Fixtures are thin**: only `users.yml`. Everything else is built inline per
  test. Before writing §4, add a `strategies.yml` (or a `build_strategy` helper
  in `test_helper.rb`) with a known-valid baseline, so each edge-case test
  changes exactly one attribute from a valid record. Without it every test
  re-declares 12 attributes and the assertion gets lost in the setup.
- Consider a `assert_invalid(record, :attribute)` helper — §4 uses it ~40 times.

---

## 4. Deep dive: Strategy — every point and edge case

This is the "one thing" to cover first. Existing tests are marked ✅; everything
else is to be written. Items marked **⚠** are ones where the current code has a
plausible failure the suite would not catch today.

### 4.1 Attribute validations — boundaries

`name`
- ✅ presence
- 80 characters accepted; 81 rejected
- whitespace-only rejected (presence catches it)

`symbol`
- only `"XAUUSD"` accepted; `"EURUSD"` rejected; `nil` rejected
- ⚠ `"xauusd"` (lower case) — inclusion is case-sensitive, so this is rejected.
  Pin it, because the DB default masks it in every test that omits the field.

`status` / `direction` / `lot_mode` (all `validate: true` enums)
- an unknown value adds a validation error rather than raising `ArgumentError`
- ✅ a new record defaults to `draft`

`grid_spacing_points`
- `0` and `-1` rejected; `1` accepted
- `100_000` accepted; `100_001` rejected
- `150.5` rejected (`only_integer`)
- `nil` rejected

`grid_levels`
- `0`, `-1` rejected; `1` accepted
- `200` accepted; `201` rejected
- non-integer rejected

`initial_lot`
- `0` and negative rejected; `100` accepted; `100.01` rejected
- ⚠ `0.001` — the column is `decimal(10,2)`, so the value casts to `0.0` and
  fails `greater_than: 0`. Assert the **error**, not a rounded save; a user
  typing a micro-lot must be told, not silently given `0.00`.

`lot_multiplier`
- validated **only** when `lot_mode` is `multiplier`
- `1` accepted (boundary), `0.99` rejected, `10` accepted, `10.01` rejected
- ⚠ present-but-nonsense while `lot_mode` is `fixed` → **no** error (the `if:`
  guard skips it). Pin this so nobody "fixes" it into an unconditional validation.

`max_positions` — `0` rejected, `1` accepted, `500` accepted, `501` rejected, integer only
`max_exposure_lots` — `0` rejected, `1_000` accepted, `1_000.01` rejected
`basket_take_profit` / `basket_stop_loss` — `nil` accepted, `0` rejected, negative rejected
`max_drawdown_percent` — `nil` accepted, `0` rejected, `100` accepted, `100.01` rejected
`min_margin_level_percent` — `nil` accepted, `0` rejected, no upper bound (e.g. `10_000` accepted)
`max_spread_points` — `nil` accepted, `0` rejected, integer only

### 4.2 `grid_levels_within_max_positions`

- ✅ levels > max_positions rejected
- levels **equal to** max_positions accepted (boundary — the grid exactly fits)
- both blank → validator adds nothing (no duplicate/confusing error alongside
  the presence errors)
- one blank → validator adds nothing
- the error message names the actual `max_positions` value

### 4.3 `exposure_can_accommodate_the_grid`

- ✅ a grid exceeding the ceiling is rejected
- **exactly equal** accepted (`0.01 × 5 = 0.05` with ceiling `0.05`)
- fixed mode: linear sum used
- multiplier mode with `lot_multiplier` **nil** → validator returns early. ⚠ Pin
  this: it exists so an invalid multiplier reports one error, not two.
- ⚠ multiplier mode with `lot_multiplier == 1` → falls to the **linear** branch
  of `maximum_theoretical_lots`. Without this, the geometric formula divides by
  `r - 1 == 0`. This is the single most important arithmetic test on the model.
- multiplier `2.0`, 5 levels, `initial_lot 0.01` → `0.31` required; ceiling
  `0.30` rejected, `0.31` accepted
- a 200-level × 2.0 grid produces an astronomically large figure and is always
  rejected (the ceiling maxes at 1,000) — assert it fails cleanly rather than
  overflowing or timing out
- rounding: a configuration whose true total is `0.3149` rounds to `0.31` and is
  accepted against a `0.31` ceiling
- the error message contains the computed lot figure and the remediation text

### 4.4 `maximum_theoretical_lots`

- ✅ linear in fixed mode
- ✅ compounds in multiplier mode
- ⚠ `lot_multiplier == 1` → linear, **no `ZeroDivisionError`**
- ⚠ `lot_mode == "multiplier"` with `lot_multiplier` nil → `nil.to_d == 0`, so
  the linear branch runs and it does not raise
- `lot_mode == "fixed"` with a multiplier set → multiplier ignored
- ✅ BigDecimal arithmetic, not Float (assert exact equality on a value a Float
  would drift on)
- result is rounded to 2 decimal places
- `grid_levels == 1` → equals `initial_lot` in both modes

### 4.5 Lifecycle — `editable?`, `start!`, `stop!`

- ✅ a new strategy is a draft and not running
- `editable?` → true for `draft`, true for `stopped`, false for `running`
- ✅ `start!` raises `NotVerified` for an unverified user
- `start!` sets `status: running`, sets `started_at`, and **clears a previous
  `stopped_at`** (restart case — start, stop, start again)
- ⚠ `start!` on a strategy that is **already running** — the partial unique
  index does not conflict with the row's own value, so this **succeeds** and
  overwrites `started_at`, losing the original start time. The service guards
  it; the model does not. Pin the model's actual behaviour so the guard is
  never removed as "redundant".
- ✅ a second strategy cannot start while one runs (`AlreadyRunning` from the
  partial unique index)
- ✅ two different users may each run their own
- concurrency: two threads calling `start!` on two different strategies for the
  same user — exactly one wins, the other raises `AlreadyRunning`
- since `SYMBOLS` holds only `XAUUSD`, "one running per symbol" is in practice
  "one running strategy per user" — assert that explicitly, because it is a
  product rule readers will look for
- `stop!` sets `status: stopped` and `stopped_at`
- ⚠ `stop!` on a **draft** that never ran → succeeds, `started_at` stays nil.
  Assert it: a "stopped but never started" row must not break the dashboard or
  the serializer.
- `stop!` twice → succeeds, `stopped_at` moves forward
- `stop!` never checks `may_trade?` (unverified user can always halt)

### 4.6 `Strategies::Start` / `Strategies::Stop`

- ✅ success records `strategy.started` with the live configuration
- ✅ unverified → `email_unverified`, no event written
- ⚠ **two distinct `already_running` paths with different messages**: the guard
  clause (`strategy.running?` → "This strategy is already running.") and the
  rescue (`Strategy::AlreadyRunning` → "Another strategy is already running for
  XAUUSD."). Both return the same code. Assert each message from its own path.
- ✅ source `web` vs `api` recorded
- `ip_address` recorded on the event
- event metadata emits decimals as **strings** (`initial_lot`, `max_exposure_lots`,
  `maximum_theoretical_lots`) — a client parsing these must not get a float
- ⚠ an `Event.record` failure does not fail the start (Event swallows and logs);
  assert the strategy is still running afterwards
- `Result#payload` is the strategy itself
- `Stop`: succeeds for a draft, for an unverified user, and records
  `strategy.stopped` with name and symbol

### 4.7 `StrategiesController` (web)

- ✅ index scoped to `current_user`
- `show` assigns open positions, pending orders ordered by price, basket profit,
  latest connection, closed count
- ⚠ `new` — assert the `defaults` hash **is itself valid** (`0.01 × 5 = 0.05 ≤
  0.5` ✓, `5 ≤ 10` ✓). If someone tweaks a default, the new-strategy form must
  not arrive pre-broken.
- `create` valid → draft, event, redirect; invalid → 422 + `:new`
- ⚠ **mass assignment**: posting `strategy[status]=running` or
  `strategy[user_id]=<other>` must be ignored — the record stays a draft owned
  by `current_user`. `params.expect` should drop them; pin it.
- `edit` and `update` on a running strategy → redirect with the stop-first alert,
  and the record is **unchanged**
- `update` event metadata `changed` excludes `updated_at`
- an update that changes nothing still redirects with a notice
- `destroy` blocked while running; when allowed, cascades positions/orders and
  records `strategy.deleted` carrying the name (subject is gone by then)
- `start` maps a failure result onto `alert:`, success onto `notice:`
- ✅ another user's strategy → 404, not 403
- unauthenticated → redirect to login for every action

### 4.8 `Api::V1::StrategiesController`

- ✅ 401 without a token; ✅ scoped to the token owner; ✅ 404 for another account
- ⚠ `status_for` mapping, one test per code: `already_running` → **409**,
  `email_unverified` → **403**, anything else → **422**
- ✅ update on a running strategy → 409 `strategy_running`
- ⚠ `POST /api/v1/strategies` with no `strategy` key → `ParameterMissing` → **400**
  `bad_request` (not 422). This is the `rescue_from` in `BaseController`.
- validation errors carry `details` keyed per field, not just a sentence
- `start`/`stop` `reload` before serialising, so the returned `status` is the
  new one
- ⚠ there is **no `destroy` route** on the API (web has one). Assert
  `DELETE /api/v1/strategies/:id` does not delete — an intentional asymmetry
  worth pinning.
- ✅ a revoked token loses access immediately

### 4.9 `StrategySerializer`

- ✅ every key the EA parses is present (`ea_contract_test.rb`)
- `lot_multiplier` is `null` in fixed mode, a 2-dp string in multiplier mode
- `started_at`/`stopped_at` are `null` on a draft
- nil optional risk fields serialise as `null`, never `"0.00"`
- `risk.maximum_theoretical_lots` matches the model method
- `status`, `direction`, `lot_mode` are the raw enum strings the EA branches on

### 4.10 Database-level guarantees

- the partial unique index `index_strategies_one_running_per_symbol` rejects a
  second running row at the DB level even when validations are bypassed
  (`update_column`)
- `NOT NULL` columns raise on a direct insert bypassing validations
- `positions`/`orders` are destroyed with the strategy; `account_snapshots` and
  `terminal_connection` are **nullified**, not destroyed — history survives
- deleting the user removes the strategy (FK + `dependent: :destroy`)

---

## 5. Deliberately not worth testing

Listed so the omissions read as decisions rather than oversights.

- `Session`, `Current`, `ApplicationRecord`, `ApplicationJob` — no logic.
- Rails' own enum/validation machinery. Test *our* boundary values, not that
  `numericality` works.
- View markup beyond what the accessibility and design-system tests already
  assert. Pinning exact copy makes every wording change a test failure.
- `bin/`, `config/`, Kamal and Docker files.
- Getters that only read an attribute (`read?`, `used?`, `verified?`) — covered
  wherever the behaviour they gate is covered.
- The `mt5/` MQL sources — not Ruby, and the contract with them is already
  pinned from the Rails side by `ea_contract_test.rb`.

# MT5 Expert Advisor integration contract

This document specifies everything an MT5 Expert Advisor needs in order to work
with this platform. It is the authoritative contract: the Rails side is tested
against exactly these payloads (see `test/integration/api_v1_trading_test.rb`,
which acts as a fake EA).

**No MQL5 code ships with this platform.** The EA is written separately, against
this document.

---

## 1. Responsibility boundary

| This platform | The Expert Advisor |
|---|---|
| Stores strategy configuration | Reads it and decides what to do |
| Records what the terminal reports | Places, modifies and closes orders |
| Shows status, positions, P/L, history | Enforces grid logic and risk limits at execution time |
| Authenticates and authorises clients | Holds the broker connection |

The platform **never sends an order**. It exposes configuration and records
state. Every decision that results in a trade is made inside the EA.

**This means the risk limits stored here are not enforced by this platform.**
They are configuration. If the EA does not implement them, they do nothing. Any
EA written against this contract must enforce `max_positions`,
`max_exposure_lots`, `max_drawdown_percent`, `min_margin_level_percent` and
`max_spread_points` itself, before placing an order.

---

## 2. Authentication

Every request carries a bearer token:

```
Authorization: Bearer ggk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The user creates a token at **Settings → API tokens** and pastes it into the
EA's inputs. Notes:

* The token is shown **once**. It is stored only as a SHA-256 digest.
* Issuing a token requires a verified email address, and a fresh password
  confirmation (plus a two-factor code, if enabled) — so the user may be asked
  to confirm their password when creating one.
* A revoked token stops working immediately — handle `401` by stopping and
  surfacing an alert to the user rather than retrying in a loop.
* A password reset revokes every token. `401` after a period of working is
  expected and means "ask the user for a new token".
* Production is HTTPS only (`force_ssl`). In MetaTrader, the endpoint URL must
  be added to **Tools → Options → Experts → Allow WebRequest for
  listed URL**.

---

## 3. Reporting state (the only write endpoint)

```
POST /api/v1/trading/report
Content-Type: application/json
```

The EA posts its **complete current state** on a fixed interval. This is
deliberately a full snapshot, not a stream of changes:

* It is **idempotent** — sending the same report twice produces the same result.
* A missed report needs no recovery; the next one corrects everything.
* There is no sequence number or delta bookkeeping to get wrong.

Recommended interval: **every 5–15 seconds** while running. A connection is
considered stale after **90 seconds** without a report.

### Request body

```json
{
  "strategy_id": 1,
  "terminal": {
    "ea_version": "1.0.0",
    "broker": "Demo Broker",
    "account_login": "12345",
    "symbol": "XAUUSD"
  },
  "tick": { "bid": "2318.40", "ask": "2318.45", "spread_points": 5 },
  "execution": {
    "state": "ARMED",
    "reason": "ladder complete — 58 resting, 2 filled, 0 skipped, capacity 60",
    "reversal_level": "0.00000",
    "daily_profit": "1.10",
    "risk_halt": "",
    "cycle": 3,
    "resting_orders": 58,
    "filled_orders": 2,
    "basket_profit": "-0.84",
    "pause_seconds_left": 0
  },
  "account": {
    "currency": "USD",
    "balance": "10000.00",
    "equity": "10184.20",
    "margin": "120.00",
    "free_margin": "10064.20",
    "margin_level_percent": "8486.83"
  },
  "positions": [
    {
      "ticket": "1001",
      "direction": "buy",
      "grid_level": 1,
      "volume": "0.01",
      "open_price": "2310.20",
      "current_price": "2318.40",
      "stop_loss": "2316.40",
      "profit": "82.00",
      "swap": "-1.20",
      "commission": "-0.30",
      "opened_at": "2026-09-06T08:00:00Z"
    }
  ],
  "orders": [
    {
      "ticket": "2001",
      "order_type": "buy_stop",
      "grid_level": 2,
      "volume": "0.01",
      "price": "2322.45",
      "placed_at": "2026-09-06T08:00:00Z"
    }
  ]
}
```

### The execution block

What the EA is doing, for the Robot state card. `state` and `reason` come
from the EA's state machine: `INITIALIZING`, `WAITING`, `BUY_ACTIVE`,
`SELL_ACTIVE`, `REVERSING`, `CLOSING`, `RECOVERY` for a trailing or reversal
strategy (`mt5/Include/GoldGrid/State.mqh`); `INITIALIZING`, `PLACING`,
`ARMED`, `CLOSING`, `COOLDOWN`, `RECOVERY` for a grid
(`mt5/Include/GoldGrid/Cycle.mqh`). The rest of the block:

| Key | Type | Meaning |
| --- | --- | --- |
| `reversal_level` | string | Reversal only: the price the open position's opposite stop rests at. `"0.00000"` means none and is stored as null |
| `daily_profit` | string | Today's realised + floating P/L, every category |
| `risk_halt` | string | Why trading is halted (emergency stop, daily loss), `""` for none |
| `cycle` | integer or null | Grid: the cycle number. Null for the other categories |
| `resting_orders` | integer or null | Grid: ladder rungs resting |
| `filled_orders` | integer or null | Grid: rungs that filled and are open |
| `basket_profit` | string or null | Grid: the combined floating P/L of every open position, net of swap and commission — the figure compared with the basket take profit |
| `pause_seconds_left` | integer or null | Grid: seconds of pause left; 0 outside `COOLDOWN` |

The whole block may be absent (an EA older than the state machine), in which
case the stored state is cleared rather than left showing an old one. A grid
order's `grid_level` is its rung, counted outward from the anchor; `0` for an
order that is not a ladder rung.

### Rules that matter

* **Send all numbers as JSON strings.** They are parsed as decimals. Sending
  them as JSON numbers risks float rounding on money values.
* `ticket` is the broker's ticket number and is the identity of a position or
  order. The same ticket always updates the same row.
* **Omitting a key and sending an empty array mean different things:**
  * `"positions": []` → *"I have no open positions."* Anything previously open
    is marked **closed**.
  * key absent → *"no information about positions in this report."* Existing
    positions are left untouched.

  A lightweight heartbeat must therefore **omit** `positions` and `orders`
  rather than send empty arrays, or it will close everything.
* An order that stops being reported is marked `cancelled`.
* Closed positions are retained as history, never deleted.

### Responses

| Status | Meaning | EA should |
|---|---|---|
| `202 Accepted` | Report stored | Continue |
| `401 Unauthorized` | Token invalid or revoked | Stop; alert the user |
| `422 Unprocessable Entity` | Payload rejected (see `error.message`) | Log; do not retry unchanged |
| `429 Too Many Requests` | Rate limited | Back off |

---

## 4. Reading configuration

```
GET /api/v1/strategies          # all strategies
GET /api/v1/strategies/:id      # one strategy
```

The EA polls its strategy to learn what it should be doing. Act on
`status`:

* `running` — operate normally.
* `stopped` / `draft` — **place no new orders.** Stopping does not instruct the
  EA to close existing positions; that decision belongs to the user's own
  configuration and the EA's design. Whatever it does, it must be documented to
  the user, because the interface tells them positions are *not* closed by
  stopping.

Configuration may be edited while `running`; only the category is locked. The
EA caches it and re-fetches as soon as the `config_version` in a report response
differs from the one it holds.

```json
{
  "strategy": {
    "id": 1, "name": "XAUUSD grid", "symbol": "XAUUSD",
    "status": "running", "category": "grid", "direction": "both",
    "grid": { "spacing_points": 200, "buy_stop_orders": 30, "sell_stop_orders": 30,
              "cycle_pause_seconds": 10, "initial_lot": "0.01" },
    "trailing": { "stop_points": null, "activation_points": null, "step_points": null },
    "entry": { "distance_points": null },
    "basket": { "take_profit": "2.00", "stop_loss": null },
    "risk": { "max_positions": 10, "max_exposure_lots": "0.50",
              "max_drawdown_percent": "20.00", "min_margin_level_percent": "200.00",
              "max_spread_points": 50, "maximum_theoretical_lots": "0.05" },
    "started_at": "2026-09-06T08:00:00Z", "updated_at": "2026-09-06T08:00:00Z"
  }
}
```

`direction`: `both` | `buy` | `sell`. Read by the trailing category only; a
grid's two order counts decide its sides, and a reversal always alternates. A
grid and a reversal both require a **hedging** broker account, because a buy
and a sell on one symbol would net against each other on a netting account.
Position, exposure, drawdown and margin ceilings apply across everything the
strategy holds.

`category`: `grid` | `trailing` | `reversal`. It decides how positions are
**opened**, not how they exit:

* `grid` — rests a ladder of stop orders: `grid.buy_stop_orders` Buy Stops
  above the market and `grid.sell_stop_orders` Sell Stops below it, each
  `grid.spacing_points` further out than the last, every one of
  `grid.initial_lot`. Whatever fills is closed together when the combined
  floating profit reaches `basket.take_profit` (always present for a grid);
  the remaining orders are cancelled and the ladder is placed again
  `grid.cycle_pause_seconds` later. The ladder never exceeds
  `risk.max_positions`. `trailing.*` is always `null` for a grid.
* `trailing` — holds **one position** and manages it with its stop. The grid
  keys are `null`, and `trailing.stop_points` is guaranteed non-null.
* `reversal` — holds one position with no stop loss; a stop order for the
  opposite side trails it at `trailing.stop_points`, and `entry.distance_points`
  is the flat bracket's distance.

`stop_loss` on a reported position is the live stop level the position is
carrying. MT5 reports "no stop attached" as `0`, and the platform stores that
as `null` rather than as a price.

### The trailing block

Present on every strategy. A `stop_points` of `null` means the EA trails
nothing, which is always the case for a grid and impossible for a trailing
strategy.

| Key | Meaning |
| --- | --- |
| `stop_points` | The loss margin, in points, that a position may give back from the best price it has seen. On XAUUSD a point is `0.01`, so `200` is a $2 margin. |
| `activation_points` | Profit a position must reach before a stop is placed at all. `null` trails from the moment it opens. |
| `step_points` | Minimum improvement before the stop is moved. Never `null` when `stop_points` is set — without it the EA would modify the position on nearly every tick and be throttled by the broker. |

Worked through with a $2 margin (200 points) on a buy at $345:

| Price reaches | Stop |
| --- | --- |
| $355 | placed at $353 |
| $365 | moved to $363 |
| falls back to $360 | stays at $363 |

A sell is the mirror image: the stop sits above the market and only moves down.
The stop is only ever moved in the favourable direction — this is the one
invariant the EA will not break, and the stop level itself is what records the
best price seen, so restarting the terminal cannot reset a trail that has
already ratcheted.

Trailing applies **per position**, because an MT5 stop belongs to a position.
A grid position carries none: its exit is the basket target.

---

## 5. Read-back endpoints

Used by the dashboard and mobile clients. An EA does not need these.

```
GET /api/v1/trading/account      # connection status + latest account snapshot
GET /api/v1/trading/positions    # open positions + computed basket totals
GET /api/v1/trading/orders       # pending orders
GET /api/v1/trading/history      # closed positions (?limit=, max 200)
```

Also available: `POST /api/v1/strategies/:id/start` and `/stop`. Starting
requires a verified email address; **stopping never does** — a user must always
be able to halt.

### Mobile sign-in and two-factor

`POST /api/v1/auth/login` exchanges credentials for a token. If the account has
two-factor enabled, the first attempt returns `401` with
`error.code = "otp_required"`; repeat the request with an `otp_code` field
(an authenticator code or a recovery code):

```json
{ "email_address": "you@example.com", "password": "…", "otp_code": "123456",
  "device_name": "iPhone" }
```

Distinguish the codes when prompting the user: `invalid_credentials` means the
password was wrong, `otp_required` means ask for a code, `invalid_otp` means the
code was wrong. An EA never uses this endpoint — its token is issued from the
web interface.

---

## 6. Number formatting

All decimal values are returned as **strings at a fixed scale**:

| Kind | Places | Example |
|---|---|---|
| Money | 2 | `"10184.20"` |
| Lots | 2 | `"0.01"` |
| Prices | 5 | `"2310.20000"` |
| Percent | 2 | `"200.00"` |

Parse these as decimals, not floats.

---

## 7. Before connecting a real account

1. Test against a **demo account** first. This integration has never been
   exercised against a live broker.
2. Confirm the EA enforces every risk limit itself (§1).
3. Confirm behaviour when the platform is unreachable: the EA holds the broker
   connection, so it must decide what to do when it cannot report. Failing
   closed (placing no new orders) is the safer default.
4. Confirm `401` handling stops the EA rather than looping.

Trading leveraged instruments carries a substantial risk of loss. Nothing in
this platform or this document reduces that risk.

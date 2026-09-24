# Testing with a demo account

Three stages, in order. Each one proves something before the next adds risk.

**Never connect a live account.** The Expert Advisor has never run against a
broker. Use a demo account until you have watched it behave correctly for a
sustained period.

---

## Stage 1 — Platform only, no MetaTrader

Proves the whole platform works: token authentication, ingestion, the dashboard,
history and alerting. Nothing touches a broker, and MT5 is not involved.

### 1. Start the app

```bash
bin/dev            # http://localhost:3000
```

### 2. Create an account and verify it

Go to `/signup`. In development no real email is sent — open the local inbox:

```
http://localhost:3000/dev/mails
```

Click **Verify email address** in the message. Verification is required before
you can issue an API token, because a token can place orders.

### 3. Create a strategy

`/strategies/new`. The defaults are deliberately small (0.01 lots, 5 levels).
Save it, then press **Start strategy**. Note the id in the URL — `/strategies/1`
means the strategy id is `1`.

### 4. Issue an API token

`/settings/api-tokens` → give it a name → **Create token**.

You will be asked to confirm your password first. The token is shown **once**;
copy it now.

### 5. Run the simulator

```bash
bin/simulate_terminal --token ggk_your_token --strategy 1
```

It posts the same payloads the real EA sends, every 10 seconds. Open
`/dashboard` and you should see the terminal connected, a live quote, account
figures and open positions.

Scenarios worth trying:

```bash
# Basket drifting into loss
bin/simulate_terminal --token ggk_… --strategy 1 --scenario losing

# Margin level below the configured minimum — should raise an alert
bin/simulate_terminal --token ggk_… --strategy 1 --scenario margin

# Reports once then goes quiet — should raise a stale-terminal alert
bin/simulate_terminal --token ggk_… --strategy 1 --scenario silent
```

### 6. Test a trailing strategy

This needs no broker and no MetaTrader either. Create a second strategy at
`/strategies/new` and set **Strategy type** to *Trailing stop*:

| Field | Value |
| --- | --- |
| Strategy type | Trailing stop |
| Order direction | Both directions |
| Entry lot size | 0.01 |
| Trailing distance (points) | 200 &nbsp;— the form confirms "That is $2.00 on gold" |
| Start trailing after | leave blank |
| Minimum step | leave blank (defaults to 10) |
| Maximum positions | 10 |
| Maximum exposure (lots) | 0.5 |

The Grid section disappears when you pick *Trailing stop*: a trailing strategy
has no levels. Save it, press **Start strategy**, then run:

```bash
bin/simulate_terminal --token ggk_… --strategy 2 --scenario trailing --interval 2
```

This scenario walks a scripted price path through the worked example — a buy
around $345, a $2 margin — and prints every stop it moves:

```
13:36:01  price 355.00  buy stop 353.00  -> accepted
13:36:07  price 365.00  buy stop 363.00  -> accepted
13:36:09  price 364.00  buy stop 363.00  -> accepted     <- price fell, stop did NOT
13:36:11  BUY  STOPPED OUT at 362.00 (stop was 363.00)
13:36:11  BUY  OPENED at 362.05 (stop 360.05)            <- re-enters on its own
```

Open the strategy page while it runs. What to check:

1. **The Stop column** in *Open positions* — it rises with the price and never
   falls. This is the whole feature.
2. **A buy row and a sell row at the same time.** Both directions run
   independently; the sell side stops out on every rise and re-enters at once,
   while the buy side rides the move.
3. **Nothing is ever restarted by hand.** Positions close and new ones appear on
   their own.
4. **Trading history** fills up at `/history` as each stop-out closes a position.
5. On a **grid** strategy the same column reads `—`: MT5 reports "no stop
   attached" as zero, and the platform must show a dash rather than `0.00000`.
   Run any other scenario to confirm.

### 7. Check alerting

The stale-terminal monitor is scheduled in production only. In development, run
it by hand after the `silent` scenario:

```bash
bin/rails runner 'Alerts::MonitorTerminals.call'
```

Then look at `/notifications`, and at `/dev/mails` for the alert email.

---

## Stage 1b — Get a MetaTrader 5 demo account

Skip this if MetaTrader already shows an account number in the Navigator panel.

1. Download MetaTrader 5 from `metatrader5.com/en/download` and install it.
2. **File → Open an Account.**
3. Search for `MetaQuotes-Demo` and select it. It is MetaQuotes' own practice
   server — no broker signup, no email, no documents, instant approval.
4. Choose **Open a demo account**, fill in a name and email (nothing is
   verified), set deposit `10000` USD and leverage `1:100`.
5. Copy the **login, password and investor password** from the confirmation
   dialog. They are shown once, and MetaTrader does not email them to you.
6. Confirm the bottom-right corner shows a connection speed rather than
   "No connection", and that **XAUUSD** appears in Market Watch. If it does not:
   right-click Market Watch → **Symbols** → search `XAUUSD` → **Show**.

A demo account trades the real market feed with fake money. Prices, spreads and
slippage are real; only the balance is not.

### Choosing a trailing distance that matches the instrument

Gold trades around **$4,400**, so a "$2 loss margin" is about 0.045% — normal
tick noise will stop it out within seconds, over and over. The mechanism will be
working correctly and it will look broken.

| Trailing distance | Points | Behaviour on gold at $4,400 |
| --- | --- | --- |
| $2 | 200 | Stops out almost immediately. Useful only to prove re-entry fires. |
| $5 | 500 | Triggers within minutes. Good for a first watch. |
| $20 | 2000 | Survives ordinary swings. Closer to a real setting. |

The points-to-dollars hint under the field always tells you which you have
typed.

---

## Stage 2 — Real MT5 demo account, reporting only

Proves the EA can authenticate, read configuration and report state. It places
**no orders**, because `InpAllowTrading` defaults to `false`.

### 1. Install the files

Copy into your MetaTrader data folder (**File → Open Data Folder** in MT5):

```
mt5/GoldGrid.mq5            ->  MQL5/Experts/GoldGrid.mq5
mt5/Include/GoldGrid/*.mqh  ->  MQL5/Include/GoldGrid/
```

Open `GoldGrid.mq5` in MetaEditor and press **Compile** (F7). Fix any compile
errors before going further — this code has never been compiled.

### 2. Allow the platform URL

**Tools → Options → Expert Advisors → Allow WebRequest for listed URL**, and add
exactly:

```
http://127.0.0.1:3000
```

> **Not `localhost`.** MetaTrader's whitelist refuses a host name with no dot in
> it, so `http://localhost:3000` cannot be added however carefully it is typed —
> the dialog simply discards it. Use the IP. It is the same machine, and Rails
> listens on `127.0.0.1:3000` by default. The EA's `InpBaseUrl` must then be the
> same string.

Without this, every request fails with error 4014/4060. The EA reports this
specific problem in the Experts log rather than failing silently, and names the
`localhost` substitution when that is what you tried.

If MT5 runs in a Windows VM (not the Mac build, which shares your network), the
loopback address will not reach your Mac.
Use your machine's LAN address instead (e.g. `http://192.168.1.20:3000`), start
Rails with `bin/rails server -b 0.0.0.0`, and whitelist that same URL.

### 3. Attach it to a chart

First open an **XAUUSD** chart. Note that **double-clicking a symbol in Market
Watch opens the New Order dialog, not a chart** — a genuinely confusing default.
Use one of these instead:

* **File → New Chart → XAUUSD**, or
* right-click XAUUSD in Market Watch → **Chart Window**, or
* drag XAUUSD from Market Watch onto an empty chart area.

If XAUUSD is not listed in Market Watch at all, press **Ctrl+U**, find it under
Metals, select it and press **Show**. If the Market Watch panel itself is
missing, **View → Market Watch** (Ctrl+M).

Then drag the EA from Navigator onto that chart, and set:

| Input | Value |
|---|---|
| `InpBaseUrl` | `http://127.0.0.1:3000` |
| `InpApiToken` | the token from step 4 above |
| `InpStrategyId` | your strategy id |
| `InpAllowTrading` | **false** — leave it off for this stage |

Enable **Algo Trading** in the toolbar.

### Or skip the dragging entirely

`bin/mt5_run` writes the preset and a startup file that attaches the EA to an
XAUUSD chart itself, then launches the terminal:

```bash
bin/mt5_run --token ggk_… --strategy 1                   # reporting only
bin/mt5_run --token ggk_… --strategy 1 --allow-trading   # stage 3
```

It refuses to run while MetaTrader is open, because MetaTrader writes the
WebRequest whitelist to `config/settings.ini` only on a clean exit — so do the
whitelist in Options first, quit with Cmd-Q, then run this.

### 4. What you should see

* The Experts tab logs a successful connection and configuration fetch.
* `/dashboard` shows the terminal connected, with your broker name and real
  bid/ask.
* No orders are placed anywhere.

Leave it running for a while. Then close MetaTrader and confirm the platform
notices — that is the alert that matters most.

---

## Stage 3 — Let the demo account trade

Only after stage 2 has been stable.

Set `InpAllowTrading = true` and reattach the EA.

Watch closely for the first basket:

* Does level 1 open at the size you configured?
* Do further levels open at the spacing you set, and no closer?
* Does the position count stop at `max_positions`?
* Does total volume stop at `max_exposure_lots`?
* Does the basket close at your take profit or stop loss?

**The risk limits are enforced by the EA, not by this platform.** The platform
records what it is told. If the EA has a bug, the limits shown in the interface
will not save you — which is exactly why stage 3 belongs on a demo account and
why you should verify each limit yourself.

Press **Stop strategy** in the web interface and confirm the EA stops opening
new levels. Stopping does **not** close open positions; that is deliberate and
stated in the interface.

---

## If something does not work

| Symptom | Cause |
|---|---|
| `401` in the Experts log | Token wrong, revoked, or the password was reset (which revokes every token) |
| WebRequest error 4014 / 4060 | URL not whitelisted, or whitelisted with a different scheme, host or port |
| Connected but no positions | `InpAllowTrading` is false — correct for stage 2 |
| Dashboard says "not reporting" | The EA stopped, MetaTrader is closed, or Algo Trading is off |
| No verification email | Development mail goes to `/dev/mails`, never to a real address |

Watch the Rails log alongside the MT5 Experts tab. Every ingestion attempt shows
up in both.

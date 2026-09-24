# How to try this out — simple version

You need **two Terminal windows**. Keep both open the whole time.

Everything below runs on your Mac. Your phone is only used to *look* at the app.

---

## Part 1 — Start the app (5 minutes)

### Window 1: start the app

```bash
cd ~/Desktop/learning/trading-project/full-stack
bin/dev
```

Leave it running. You should see lines scrolling. That is normal.

Open **http://localhost:3000** in your browser. You should see the GoldGrid
landing page.

If you only want to use it on your Mac, skip Part 2 and go to Part 3.

---

## Part 2 — Open it on your iPhone (optional)

Your phone cannot reach `localhost` on your Mac, so ngrok makes a public web
address that points at your Mac.

### Window 2: start the tunnel

```bash
ngrok http 3000
```

It prints a line like:

```
Forwarding   https://abc-123-45.ngrok-free.app -> http://localhost:3000
```

Copy that `https://…ngrok-free.app` address. That is your app's temporary
public address. **It changes every time you restart ngrok.**

### Restart the app with that address

Go back to **Window 1**, press `Ctrl+C`, then start it again with the address
(no `https://`, just the host):

```bash
APP_HOST=abc-123-45.ngrok-free.app bin/dev
```

This step matters: without it, the links inside your verification email will
point at `localhost` and will not open on your phone.

### On your iPhone

1. Open Safari and go to the `https://…ngrok-free.app` address.
2. Tap the **Share** button, then **Add to Home Screen**.
3. Open it from your home screen — it now behaves like an app.

---

## Part 3 — Make an account

1. Go to **/signup** and create an account. Use any email address — no real
   email is sent.
2. You now need the verification link. On your **Mac**, open:

   **http://localhost:3000/dev/mails**

   This is a fake inbox holding every email the app "sent". Click your message,
   then click **Verify email address**.

Verification is required before the app will give you a trading token.

---

## Part 4 — Make a strategy

1. Go to **Strategies → New strategy**.
2. Leave every default as it is. They are deliberately small.
3. Click **Create strategy**, then click **Start strategy**.
4. Look at the address bar. If it says `/strategies/1`, your **strategy id is 1**.
   Write that number down.

Nothing is trading. This has only saved settings.

---

## Part 5 — Get a token

1. Go to **Settings → Manage API tokens**.
2. It asks for your password again. Type it.
3. Name it `Test`, click **Create token**.
4. A long code starting `ggk_` appears. **Copy it now** — it is never shown again.

---

## Part 6 — See it all working (no MetaTrader needed)

This is the part that proves everything works. Open a **third** Terminal window:

```bash
cd ~/Desktop/learning/trading-project/full-stack
bin/simulate_terminal --token ggk_paste_yours_here --strategy 1
```

Replace `ggk_paste_yours_here` with your token, and `1` with your strategy id.

Every 10 seconds it prints a line like `accepted`. Now open **/dashboard**.
You should see:

* **MT5 connected**, in green
* A gold price, balance and equity
* Four open positions with profit and loss

This is pretend data from the simulator. It is not real trading, and no broker
is involved. It exists so you can see the whole platform working.

Press `Ctrl+C` to stop it.

### Try a failure on purpose

```bash
bin/simulate_terminal --token ggk_… --strategy 1 --scenario silent
```

That sends one report and stops, like a terminal that crashed. Then run:

```bash
bin/rails runner 'Alerts::MonitorTerminals.call'
```

Check **/notifications** and the fake inbox at **/dev/mails**. You should have a
red alert saying your terminal stopped reporting. That alert is the most
important thing this platform does.

---

## Part 7 — Connecting a real XM demo account

**Your iPhone cannot do this part.** The MetaTrader app on iOS and Android
cannot run Expert Advisors — MetaQuotes does not allow it. The trading robot
only runs on MetaTrader 5 for **desktop**.

To do it on your Mac:

1. Download **MetaTrader 5 for Mac** from XM's website and install it.
2. Log in with your **XM demo account** (not a live one).
3. In MT5: **File → Open Data Folder**.
4. Copy the robot files in:
   * `mt5/GoldGrid.mq5` → into the `MQL5/Experts` folder
   * everything in `mt5/Include/GoldGrid/` → into `MQL5/Include/GoldGrid/`
     (create the `GoldGrid` folder)
5. In MT5: **Tools → MetaQuotes Language Editor**, open `GoldGrid.mq5`,
   press **Compile**. Fix any errors it reports — this code has never been
   compiled before, so expect some.
6. In MT5: **Tools → Options → Expert Advisors** → tick *Allow WebRequest for
   listed URL* → add `http://localhost:3000`.
7. Open an **XAUUSD** chart, drag **GoldGrid** onto it, and fill in:
   * `InpBaseUrl` → `http://localhost:3000`
   * `InpApiToken` → your `ggk_…` token
   * `InpStrategyId` → your strategy id
   * `InpAllowTrading` → **false** (leave it off at first)
8. Turn on **Algo Trading** in the toolbar.

With `InpAllowTrading` off, it connects and reports but places no orders. Watch
`/dashboard` — you should see your real broker name and the real gold price.

Only turn `InpAllowTrading` on once that has worked for a while, and only ever
on a **demo** account.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| Page will not load | Is `bin/dev` still running in Window 1? |
| ngrok address does not work | ngrok gives a new address each restart — use the new one |
| No verification email | It is not a real email. Open `/dev/mails` on your Mac |
| Cannot create a token | Verify your email first |
| Simulator says `401` | Wrong token, or you copied it with a space |
| MT5 error 4014 or 4060 | The URL is not in the WebRequest allow-list |
| Dashboard says "not reporting" | The simulator or MT5 stopped |

---

## The honest summary

* Parts 1–6 work today. I have run them.
* Part 7 has never been tested. The robot has never been compiled or run
  against a broker.
* **Use a demo account only.** The safety limits are enforced by the robot, not
  by this website. If the robot has a bug, the limits on screen will not stop it.

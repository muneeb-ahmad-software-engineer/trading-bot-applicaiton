//+------------------------------------------------------------------+
//| GoldGrid.mq5                                                      |
//| XAUUSD grid Expert Advisor for the GoldGrid platform.             |
//|                                                                   |
//| ---------------------------------------------------------------- |
//| READ THIS BEFORE RUNNING                                          |
//|                                                                   |
//| This EA places real orders with your broker. It has been written  |
//| against doc/MT5_INTEGRATION.md but has NOT been run against a     |
//| live or demo terminal by its author. Test it on a DEMO account    |
//| until you are satisfied it behaves as you expect.                 |
//|                                                                   |
//| Grid strategies accumulate positions as price moves against them. |
//| Losses can exceed expectations. The limits configured on the      |
//| platform are enforced here, in this EA — the platform stores them |
//| but cannot enforce anything.                                      |
//| ---------------------------------------------------------------- |
//|                                                                   |
//| Three strategy categories are supported:                          |
//|   * grid     — BEING REBUILT (grid-strategy-plan.md): a ladder of |
//|                resting Buy Stop orders above the market and Sell  |
//|                Stop orders below it, one gap apart, closed as ONE |
//|                basket at a combined profit target, then placed    |
//|                again after a pause. The cycle is persisted and    |
//|                reconciled with the broker on every start. Risk    |
//|                gates (Phase 6) and reporting (Phase 7) are still  |
//|                being wired in. Do not deploy it to a trading      |
//|                account yet.                                       |
//|   * trailing — ONE position in total, managed by a stop that      |
//|                follows price in the favourable direction only.    |
//|   * reversal — ONE position in total, with NO stop loss. Flat, it |
//|                brackets the market with a buy stop and a sell     |
//|                stop; the first to fill cancels the other. While a |
//|                BUY is open a SELL STOP trails below it (a BUY     |
//|                STOP above a SELL). When that order fills, the EA  |
//|                closes the old position at once, and the new one   |
//|                gets its own trailing opposite stop. Forever.      |
//|                                                                   |
//| Trailing and reversal hold one position. The only exception is    |
//| the moment a reversal order fills, before the EA closes the old   |
//| side; anything else is closed as a breach (StepState / Recover).  |
//|                                                                   |
//| Behaviour when the strategy is stopped:                           |
//|   * No new positions or baskets are opened. A grid's resting      |
//|     ladder orders are withdrawn — each one is a future entry.     |
//|   * Existing baskets CONTINUE to be managed — basket take profit, |
//|     stop loss and trailing stops still apply. Abandoning an open  |
//|     basket with no exit would be more dangerous than continuing   |
//|     to manage it.                                                 |
//|   * Nothing is force-closed. Stopping is not "close everything".  |
//|   * The grid holds through the market's daily break and the       |
//|     weekend: resting orders and positions are held by the broker  |
//|     and the basket exit resumes at the open. (Only the reversal   |
//|     goes flat before the break — InpFlatBeforeBreakMinutes.)      |
//|                                                                   |
//| Behaviour when the platform is unreachable:                       |
//|   * Fails closed. No new positions are opened once the cached     |
//|     configuration goes stale.                                     |
//|   * Existing baskets continue to be managed from the last known   |
//|     configuration, so open risk is not left unattended.           |
//+------------------------------------------------------------------+
#property copyright "GoldGrid"
#property version   "1.10"
#property description "Grid and trailing-stop EA driven by GoldGrid strategy configuration. Test on a demo account first."

#include "Include/GoldGrid/Api.mqh"
#include "Include/GoldGrid/Strategy.mqh"
#include "Include/GoldGrid/Grid.mqh"
#include "Include/GoldGrid/State.mqh"
#include "Include/GoldGrid/Cycle.mqh"
#include "Include/GoldGrid/Tester.mqh"

//--- Inputs -------------------------------------------------------------
input group "Platform connection"
//--- 127.0.0.1 rather than localhost, because MetaTrader's WebRequest
//--- whitelist refuses a host name with no dot in it. The default has to be an
//--- address the user can actually whitelist.
input string InpBaseUrl        = "http://127.0.0.1:3000";  // Platform URL (must be whitelisted)
input string InpApiToken       = "";                        // API token from Settings > API tokens
input long   InpStrategyId     = 0;                         // Strategy id to run
input int    InpReportSeconds  = 10;                        // Seconds between state reports
input int    InpConfigSeconds  = 30;                        // Seconds between configuration refreshes

input group "Execution"
input long   InpMagicNumber    = 20260906;                  // Identifies this EA's orders
input int    InpSlippagePoints = 20;                        // Maximum price deviation
input bool   InpAllowTrading   = false;                     // Master switch — off by default, on purpose
input int    InpReentryCooldownSeconds = 60;                // Trailing/reversal: pause after a close before any new entry
input int    InpFlatBeforeBreakMinutes = 5;                 // Reversal: close and go flat this long before the market's daily/weekend break (0 = off)
input int    InpWaitAfterOpenMinutes   = 15;                // Reversal: no new bracket until this long after the market reopens (0 = off)

//--- Read ONLY in the Strategy Tester, which cannot reach the platform: the
//--- strategy is built from these instead of fetched. Ignored live.
input group "Strategy Tester only"
input ENUM_TEST_CATEGORY InpTestCategory      = TEST_REVERSAL; // Category
input double InpTestLot                       = 0.01;          // Entry lot
input int    InpTestTrailingPoints            = 300;           // Trailing distance (points)
input int    InpTestStepPoints                = 20;            // Trailing step (points)
input int    InpTestEntryPoints               = 0;             // Entry distance, reversal (0 = trailing distance)
input int    InpTestMaxSpreadPoints           = 0;             // Maximum spread (0 = none)
input double InpTestMaxDailyLoss              = 0.0;           // Maximum daily loss (0 = none)
input int    InpTestGridSpacingPoints         = 200;           // Grid: gap between ladder orders (points)
input int    InpTestGridBuyOrders             = 30;            // Grid: Buy Stop orders per cycle
input int    InpTestGridSellOrders            = 30;            // Grid: Sell Stop orders per cycle
input double InpTestGridTargetMoney           = 2.0;           // Grid: combined basket profit target (account currency)
input int    InpTestGridPauseSeconds          = 10;            // Grid: pause between cycles (seconds)
input int    InpTestOrderLimit                = 0;             // Grid: pretend the broker allows this many orders (0 = real)
input int    InpChaosEveryMinutes             = 0;             // Chaos: inject a failure every N minutes (0 = off)
input int    InpChaosSeed                     = 1;             // Chaos: random seed
input bool   InpChaosRestartOnly              = false;         // Chaos: inject EA restarts only

//--- How far back each report looks for closed positions to include. Six
//--- hours, so that a platform that recorded a close from stale data — or
//--- missed it entirely across its own restart — keeps getting the broker's
//--- real numbers until well after anyone could care. The cost is a few
//--- history reads per report; the list itself only carries each position
//--- once.
#define CLOSED_REPORT_WINDOW_SECONDS (6 * 3600)

//--- State --------------------------------------------------------------
// Globals carry a g_ prefix so that a parameter named `strategy` inside a
// helper cannot silently shadow the one piece of state the whole EA turns on.
// In a program that places orders, reading the wrong `strategy` is not a
// style problem.
CGoldGridApi  g_api;
CGridEngine   g_grid;
SGridStrategy g_strategy;
CInvariantMonitor g_monitor;   // Strategy Tester only
CChaosEngine      g_chaos;     // Strategy Tester only

//--- SCHEDULING USES A MONOTONIC CLOCK, NOT TimeCurrent().
//---
//--- TimeCurrent() is the timestamp of the last quote the terminal received,
//--- not the time. With the market closed no quotes arrive, so it stops
//--- advancing — and every interval measured against it stops elapsing with
//--- it. Observed on a Sunday: the EA connected, sent exactly one report, and
//--- then went silent for hours while the platform showed the terminal as
//--- "not reporting". Nothing had crashed. Its clock had stopped.
//---
//--- GetTickCount64() counts milliseconds since the terminal started. It is
//--- unaffected by quotes, by the market being closed, and by the user
//--- changing the system clock or a DST boundary passing.
//---
//--- Broker server time is still the right clock for anything describing WHEN
//--- A TRADE HAPPENED, so IsoTime() below keeps using TimeCurrent().
ulong NowMs(void) { return ClockMs(); }   // Include/GoldGrid/Clock.mqh

ulong    last_report_at = 0;
ulong    last_config_at = 0;
string   halt_reason    = "";     // non-empty means: do not open anything
bool     halted         = false;
string   last_gate_note = "";
string   ea_version     = "1.10";

//--- A market order does not appear in PositionsTotal() instantly. Without a
//--- short pause after opening, the next tick would see the same empty level
//--- and open it a second time.
//---
//--- Held PER DIRECTION. A single shared timer meant that opening the buy side
//--- of a both-directions strategy locked the sell side out for the next three
//--- seconds, so the two sides never started together and entered at prices
//--- that had already drifted apart. The settling problem it guards against is
//--- per position, so the guard is too.
ulong    last_open_at[2] = { 0, 0 };   // [0] buy, [1] sell
int      OPEN_COOLDOWN_SECONDS = 3;

int DirectionSlot(const ENUM_POSITION_TYPE type)
  {
   return type == POSITION_TYPE_BUY ? 0 : 1;
  }

//--- The cached configuration is only trusted for this long once the
//--- platform stops answering. After that the EA fails closed.
int CONFIG_STALE_AFTER_SECONDS = 120;

//--- RISK HALTS (every category).
//---
//--- An emergency stop from the platform, or the daily loss limit, closes
//--- every position and pending order of this EA at market and opens nothing
//--- more. Unlike the ordinary gates, which only refuse new entries, these
//--- act on what is already open — that is the point of them.
string   risk_halt_noted          = "";
ulong    last_halt_close_attempt  = 0;

//--- "" when trading may continue, otherwise why it may not.
string RiskHaltReason()
  {
   if(!g_strategy.loaded)
      return "";
   if(g_strategy.emergency_stop)
      return "Emergency stop from the platform — closing everything";
   if(g_grid.DailyLossBreached(g_strategy))
      return StringFormat("Daily loss limit reached (%.2f today, limit %.2f) — closed until the next trading day",
                          g_grid.TodayProfit(), g_strategy.max_daily_loss);
   return "";
  }

//+------------------------------------------------------------------+
//| Returns true while a halt is in force, so the caller decides      |
//| nothing else that pass. Pending orders go first — nothing may     |
//| fill while positions are being closed — then the positions, paced |
//| so a close the broker keeps refusing is not hammered every tick.  |
//+------------------------------------------------------------------+
bool EnforceRiskHalts()
  {
   string halt = RiskHaltReason();
   if(halt == "")
     {
      if(risk_halt_noted != "")
         Print("GoldGrid: risk halt cleared");
      risk_halt_noted = "";
      return false;
     }

   if(halt != risk_halt_noted)
      PrintFormat("GoldGrid: RISK HALT — %s", halt);
   risk_halt_noted = halt;

   //--- The master switch means "send nothing", closes included. Entries are
   //--- refused by the gate regardless.
   if(!InpAllowTrading)
      return true;

   //--- The grid closes through its own CLOSING state, so the close is
   //--- confirmed with the broker, the cycle is retired, and the next one
   //--- waits in COOLDOWN until the halt clears (CooldownCycle).
   if(g_strategy.category == CATEGORY_GRID)
     {
      if(g_cycle.Is(CYCLE_INITIALIZING))
         ReconcileCycle();
      else if(!g_cycle.Is(CYCLE_CLOSING) && (g_grid.TotalPositions() > 0 || g_grid.OurOrders() > 0))
         BeginCycleClose("risk halt — " + halt, g_grid.CombinedBasket());
      if(g_cycle.Is(CYCLE_CLOSING))
         CloseCycle();
      return true;
     }

   int cancelled = g_grid.DeleteAllPendingStops() + g_grid.DeleteStrayOrders();
   if(cancelled > 0)
      PrintFormat("GoldGrid: risk halt cancelled %d pending order(s)", cancelled);

   if(g_grid.TotalPositions() == 0 || NowMs() - last_halt_close_attempt < 5000)
      return true;
   last_halt_close_attempt = NowMs();

   //--- A single position closes through CLOSING, so the state machine
   //--- confirms it with the broker like any other close the EA sends.
   if(SinglePositionMode() && g_state.Is(STATE_CLOSING))
      return true;
   if(SinglePositionMode() && g_state.IsActive())
     {
      BeginClose(g_state.Ticket(), "risk halt");
      return true;
     }

   int failed = g_grid.CloseAllPositions("risk halt");
   if(failed > 0)
      PrintFormat("GoldGrid: risk halt could not close %d position(s) — retrying", failed);
   return true;
  }

//--- ONE ACTIVE POSITION + EXECUTION STATE (trailing and reversal categories).
//---
//--- These strategies may hold zero or one position — never a buy and a sell
//--- together. What the EA is doing is held in g_state (Include/GoldGrid/
//--- State.mqh), persisted across restarts and reconciled against the broker's
//--- actual positions on every pass by StepState():
//---
//---   INITIALIZING --flat--> WAITING --fill--> BUY_ACTIVE / SELL_ACTIVE
//---   *_ACTIVE --opposite stop fills--> REVERSING --old side closed--> the other *_ACTIVE
//---   *_ACTIVE --stop/TP/manual close--> WAITING (cooldown starts)
//---   *_ACTIVE --EA sends a close--> CLOSING --broker confirms--> WAITING
//---   anything --breach / unconfirmed close--> RECOVERY --consistent--> resumes
//---
//--- Entries are only ever placed from WAITING, and only after EntryAllowed()
//--- has re-read the broker.
//---
//--- entry_lock_until: set the moment an order is sent or a fill is seen, so a
//--- position that has not yet appeared in PositionsTotal() cannot be
//--- mistaken for "flat" and doubled. In-memory on purpose: a restart goes
//--- through INITIALIZING, which re-reads the broker anyway.
CExecutionState g_state;
ulong    entry_lock_until      = 0;
ulong    recovery_clean_since  = 0;
ulong    last_recovery_attempt = 0;
int      CLOSE_CONFIRM_TIMEOUT_SECONDS = 15;
int      RECOVERY_SETTLE_SECONDS       = 10;

//--- THE REVERSAL (reversal category).
//---
//--- The open position's exit is one price trailed behind the market by
//--- TrailReversalExit (Include/GoldGrid/Grid.mqh), held by the broker twice:
//--- as the position's own stop loss, and as a stop order for the opposite
//--- side at the same price. When price turns by the trailing distance the
//--- broker closes the old position and opens the new one on the same tick —
//--- whether or not this EA is running, busy or waiting on the platform:
//---
//---   BUY_ACTIVE --stop loss + sell stop at the exit--> SELL_ACTIVE
//---
//--- The new position is opened with its first stop loss already attached,
//--- and gets its own trailing exit on the next pass.
//---
//--- If both sides are ever open together (a stop loss that could not be set
//--- in time), the old way still applies: REVERSING, and the EA closes the
//--- old one.
//---
//---   *_ACTIVE --opposite stop fills, old still open--> REVERSING
//---   REVERSING --old position closed by the EA--> the opposite *_ACTIVE
//---
//--- While reversing is not allowed (strategy stopped, risk halt, platform
//--- unreachable) the stop order is withdrawn and the stop loss alone stays:
//--- the position still exits at the trailing level, flat.
ulong    reversing_close_at    = 0;     // last close request sent while REVERSING
bool     reversing_flat        = false; // close both sides instead of keeping the new one
int      REVERSE_RETRY_SECONDS = 2;
//--- Set when a reversal position closes: the opposite stop order that
//--- triggered with its stop loss is left alone this long while its fill
//--- reaches the terminal.
ulong    exit_settling_since   = 0;
const ulong EXIT_SETTLE_MS     = 3000;

bool SinglePositionMode()
  {
   return g_strategy.loaded && g_strategy.category != CATEGORY_GRID;
  }

void LockEntries(const int seconds)
  {
   ulong until = NowMs() + (ulong)seconds * 1000;
   if(until > entry_lock_until)
      entry_lock_until = until;
  }

//--- The gate every single-position entry passes, immediately before the order
//--- is sent. `why` is left empty when the refusal is the normal state of
//--- things (a position is simply open) so the log is not flooded with it.
bool EntryAllowed(string &why)
  {
   why = "";

   if(!g_state.Is(STATE_WAITING))
     {
      if(g_state.Is(STATE_RECOVERY))
         why = "in RECOVERY — " + g_state.Reason();
      return false;
     }

   //--- The state says flat; the broker has the final word.
   if(g_grid.TotalPositions() > 0)
      return false;

   if(NowMs() < entry_lock_until)
     {
      why = "a previous order is still settling";
      return false;
     }

   if(g_state.SecondsSinceClose() < InpReentryCooldownSeconds)
     {
      why = StringFormat("re-entry cooldown after a close (%d s)", InpReentryCooldownSeconds);
      return false;
     }

   return true;
  }

//--- Sends a close and moves to CLOSING. Only the broker's confirmation, seen
//--- by StepState(), takes the state out of CLOSING again.
bool BeginClose(const ulong ticket, const string why)
  {
   LockEntries(OPEN_COOLDOWN_SECONDS);
   //--- A reversal position's opposite stop goes first: once the position is
   //--- being closed, nothing may open in its place.
   if(g_strategy.category == CATEGORY_REVERSAL)
      g_grid.DeleteAllPendingStops();
   if(!g_grid.ClosePosition(ticket, why))
     {
      g_state.Set(STATE_RECOVERY, StringFormat("close of #%I64u failed (%s)", ticket, why), ticket);
      return false;
     }
   g_state.Set(STATE_CLOSING, why, ticket);
   return true;
  }

//+------------------------------------------------------------------+
//| RECOVERY. Nothing is opened. Excess positions are closed (unless  |
//| the master switch is off), nothing is left resting, and the state |
//| is only left once the broker has shown a consistent picture —     |
//| at most one position, and any close in question accounted for —   |
//| for RECOVERY_SETTLE_SECONDS in a row.                             |
//+------------------------------------------------------------------+
void Recover(const int held, const ulong ticket, const ENUM_EXEC_STATE active)
  {
   static bool reported_without_trading = false;

   //--- Nothing can be sent outside the trading session (or with the terminal's
   //--- own trading switched off); requests then would only be rejected, every
   //--- pass. The checks below still run, so the state is ready at the open.
   bool can_send = InpAllowTrading && g_grid.TradingAllowed();

   if(held > 1)
     {
      recovery_clean_since = 0;

      if(InpAllowTrading && !can_send)
         return;

      //--- The master switch means "send nothing", and that includes closes.
      if(!InpAllowTrading)
        {
         if(!reported_without_trading)
            PrintFormat("GoldGrid: %d positions open, but AllowTrading is off so nothing is "
                        "closed. Resolve it by hand.", held);
         reported_without_trading = true;
         return;
        }

      //--- Paced, so a close the broker keeps rejecting is not hammered on
      //--- every tick.
      if(NowMs() - last_recovery_attempt < 5000)
         return;
      last_recovery_attempt = NowMs();

      PrintFormat("GoldGrid: RECOVERY — %d positions open. Cancelling pending orders and "
                  "closing all but the newest.", held);
      g_grid.DeleteAllPendingStops();
      g_grid.CloseAllButNewest();
      LockEntries(OPEN_COOLDOWN_SECONDS);
      return;
     }
   reported_without_trading = false;

   //--- Nothing rests while the picture is uncertain — except a reversal
   //--- position's opposite stop, which is the only exit that position has.
   if(can_send)
     {
      if(held == 1 && g_strategy.category == CATEGORY_REVERSAL)
         KeepOppositeStop(active == STATE_BUY_ACTIVE ? POSITION_TYPE_BUY : POSITION_TYPE_SELL, ticket);
      else
         g_grid.DeleteAllPendingStops();
     }

   //--- A close that is still in question must be accounted for: either the
   //--- position is still open (the close failed — it keeps its own stop) or
   //--- the broker's history shows it closed. Neither yet means wait.
   ulong in_question = g_state.Ticket();
   bool  understood  = in_question == 0 ||
                       PositionSelectByTicket(in_question) ||
                       g_grid.PositionConfirmedClosed(in_question, g_state.PositionId());
   if(!understood)
     {
      recovery_clean_since = 0;
      //--- Staying put is the rule — no new trade until the close is
      //--- confirmed — but a strategy that silently stops trading for good is
      //--- a problem the user has to hear about.
      static ulong warned_for = 0;
      if(warned_for != in_question && g_state.MsInState() > 5 * 60 * 1000)
        {
         PrintFormat("GoldGrid: STILL IN RECOVERY after 5 minutes — the close of #%I64u cannot be found in the "
                     "broker's deal history, so nothing new will be opened. Check the account in MetaTrader; "
                     "restarting the strategy re-reads the broker from scratch.", in_question);
         warned_for = in_question;
        }
      return;
     }

   if(recovery_clean_since == 0)
     {
      recovery_clean_since = NowMs();
      return;
     }
   if(NowMs() - recovery_clean_since < (ulong)RECOVERY_SETTLE_SECONDS * 1000)
      return;

   recovery_clean_since = 0;
   //--- Leaving RECOVERY is treated like a close: the cooldown applies before
   //--- anything new opens.
   g_state.RecordClose();
   if(held == 1)
      g_state.Set(active, "recovered — one position open", ticket);
   else
      g_state.Set(STATE_WAITING, "recovered — flat");
  }

//+------------------------------------------------------------------+
//| The exit of the one open position — its stop loss and the         |
//| opposite stop order at the same price — trailed behind price, and |
//| nothing resting on the side already held.                         |
//+------------------------------------------------------------------+
void KeepOppositeStop(const ENUM_POSITION_TYPE held_side, const ulong ticket)
  {
   g_grid.DeletePendingStops(held_side);
   g_grid.DeleteStrayOrders();

   //--- A spread spike does not withdraw the order: the spread flickers, and
   //--- an order that comes and goes is not there when it is needed. A fill
   //--- during a spike is closed when it is seen (StepState).
   double lot = EntryLot(g_strategy, _Symbol);
   g_grid.TrailReversalExit(g_strategy, held_side, ticket, lot, StringFormat("GG:%I64d:REV", g_strategy.id),
                            ReversalBlockedReason(false) == "");
  }

//--- THE MARKET GUARD (reversal category).
//---
//--- Tested on the broker's real ticks: in the first minutes after gold
//--- reopens each day, the spread is $20-30 and quotes jump $30-50 back and
//--- forth. A resting stop order fills on every jump, so the strategy flipped
//--- dozens of times in minutes, paying the spread each time — three quarters
//--- of a week's loss came from those minutes. The guard keeps the strategy
//--- out of them:
//---
//---   * InpFlatBeforeBreakMinutes before the daily or weekend break, the
//---     position is closed and nothing rests, so nothing is carried into the
//---     reopen (or a weekend gap).
//---   * For InpWaitAfterOpenMinutes after the reopen, no new bracket. The
//---     reopen is the first real price after QUOTE_GAP_SECONDS without one —
//---     not the broker's session table, which on this broker says gold opens
//---     at 00:00 when the first price comes at 01:00. A bracket placed on the
//---     table's word rested on Friday's price and filled in the 01:00 chaos.
//---   * Nothing is placed on a price older than STALE_QUOTE_SECONDS.
//---   * While the spread is above the limit, no bracket rests, and a filled
//---     opposite stop does not flip into a new position: both sides close.
datetime last_quote_at       = 0;   // server time of the latest price seen
datetime reopened_at         = 0;   // the first price after a gap
int      QUOTE_GAP_SECONDS   = 600;
int      STALE_QUOTE_SECONDS = 300;

void TrackQuotes()
  {
   datetime quote = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
   if(quote <= 0 || quote == last_quote_at)
      return;
   //--- No earlier price known (the EA started with the market closed): the
   //--- first one is treated as the reopen, which is the cautious reading.
   if(last_quote_at == 0 || quote - last_quote_at >= QUOTE_GAP_SECONDS)
     {
      reopened_at = quote;
      if(last_quote_at > 0)
         PrintFormat("GoldGrid: market reopened — first price after %d min without one",
                     (int)((quote - last_quote_at) / 60));
     }
   last_quote_at = quote;
  }

//--- The widest spread the strategy trades at, in points: the strategy's own
//--- maximum spread, or a third of the trailing distance (at least 50 points)
//--- when none is set. A flip costs about one spread; paying more than a third
//--- of the distance on every flip cannot be made back.
int SpreadLimitPoints()
  {
   if(g_strategy.has_max_spread && g_strategy.max_spread_points > 0)
      return g_strategy.max_spread_points;
   return MathMax(g_strategy.trailing_stop_points / 3, 50);
  }

//--- The limit applies to new orders. Orders already resting, and a reversal
//--- that fills, are only stopped at twice the limit: gold's spread flickers
//--- a few points around any fixed number, and withdrawing on every flicker
//--- means the bracket is never there long enough to fill.
string SpreadTooWideReason(const bool hard = false)
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int  limit  = SpreadLimitPoints() * (hard ? 2 : 1);
   if(spread <= limit)
      return "";
   return StringFormat("the spread (%I64d points) is above the %d-point limit", spread, limit);
  }

//--- "" outside the guarded windows; otherwise which one. `closing` is true
//--- only in the window before a break, where an open position is closed.
string MarketGuardReason(bool &closing)
  {
   closing = false;
   int until_close;
   if(InpFlatBeforeBreakMinutes > 0 && g_grid.SecondsToSessionClose(until_close) &&
      until_close <= InpFlatBeforeBreakMinutes * 60)
     {
      closing = true;
      return StringFormat("the market breaks in %d min", (until_close + 59) / 60);
     }

   datetime now = TimeTradeServer();
   if(last_quote_at > 0 && now - last_quote_at > STALE_QUOTE_SECONDS)
      return StringFormat("no price for %d min — waiting for the market to open", (int)((now - last_quote_at) / 60));

   int since_open = (int)(now - reopened_at);
   if(InpWaitAfterOpenMinutes > 0 && reopened_at > 0 && since_open < InpWaitAfterOpenMinutes * 60)
      return StringFormat("the market reopened %d min ago (waiting %d min for the spread to settle)",
                          since_open / 60, InpWaitAfterOpenMinutes);
   return "";
  }

//--- "" when a filled opposite stop may become the new position, otherwise why
//--- not — in which case it is closed. `spread` false leaves out the spread,
//--- which decides what to do with a fill, not whether the order rests.
string ReversalBlockedReason(const bool spread_counts = true)
  {
   if(halted)
      return halt_reason;
   if(!InpAllowTrading)
      return "AllowTrading is off";
   if(!g_strategy.IsRunning())
      return "the strategy is stopped";
   if(!ConfigurationIsFresh())
      return "the platform has not answered recently";
   string spread = spread_counts ? SpreadTooWideReason(true) : "";
   if(spread != "")
      return spread;
   return RiskHaltReason();
  }

//--- Whether a second position is our opposite stop filling: a reversal
//--- strategy holding one side, and a newer position on the other side.
bool IsReversalFill(const int held, const ulong newest, const ENUM_POSITION_TYPE newest_type)
  {
   if(g_strategy.category != CATEGORY_REVERSAL || held != 2 || !g_state.IsActive())
      return false;

   ENUM_POSITION_TYPE was = g_state.Is(STATE_BUY_ACTIVE) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   return newest != g_state.Ticket() && newest_type != was && PositionSelectByTicket(g_state.Ticket());
  }

void BeginReversal(const ENUM_POSITION_TYPE new_side)
  {
   string blocked = ReversalBlockedReason();
   string old     = new_side == POSITION_TYPE_BUY ? "SELL" : "BUY";
   string fresh   = new_side == POSITION_TYPE_BUY ? "BUY" : "SELL";

   reversing_flat     = blocked != "";
   reversing_close_at = 0;
   LockEntries(OPEN_COOLDOWN_SECONDS);

   //--- The state keeps the OLD ticket: that is the position being closed.
   g_state.Set(STATE_REVERSING,
               reversing_flat
               ? StringFormat("%s stop filled, but %s — closing both sides", fresh, blocked)
               : StringFormat("%s stop filled — closing %s #%I64u", fresh, old, g_state.Ticket()),
               g_state.Ticket());
  }

//+------------------------------------------------------------------+
//| REVERSING: close the old position (or both, if reversing is not   |
//| allowed), paced so a close the broker refuses is not hammered,    |
//| and hand over to the new position once the old one is gone.       |
//+------------------------------------------------------------------+
void ContinueReversal(const int held, const ulong newest, const ENUM_POSITION_TYPE newest_type)
  {
   ulong old      = g_state.Ticket();
   bool  old_open = PositionSelectByTicket(old);
   ENUM_EXEC_STATE newest_active = newest_type == POSITION_TYPE_BUY ? STATE_BUY_ACTIVE : STATE_SELL_ACTIVE;

   if(held == 0)
     {
      g_state.RecordClose();
      g_state.Set(STATE_WAITING, reversing_flat ? "both sides closed — no reversal" : "both positions closed");
      return;
     }
   if(held == 1 && !old_open && !reversing_flat)
     {
      g_state.Set(newest_active, StringFormat("reversal complete — #%I64u closed, now holding %s #%I64u", old,
                                              newest_type == POSITION_TYPE_BUY ? "BUY" : "SELL", newest), newest);
      return;
     }
   if(held == 1 && old_open && !reversing_flat)
     {
      g_state.Set(newest_active, "the new position closed before the old one — still holding it", newest);
      return;
     }
   if(held > 2)
     {
      g_state.Set(STATE_RECOVERY, StringFormat("%d positions open during a reversal", held), old);
      return;
     }

   if(g_state.MsInState() > (ulong)CLOSE_CONFIRM_TIMEOUT_SECONDS * 1000)
     {
      g_state.Set(STATE_RECOVERY, StringFormat("reversal: the old side was not closed within %d s",
                                               CLOSE_CONFIRM_TIMEOUT_SECONDS), old);
      return;
     }
   if(!InpAllowTrading || !g_grid.TradingAllowed())
      return;
   if(reversing_close_at > 0 && NowMs() - reversing_close_at < (ulong)REVERSE_RETRY_SECONDS * 1000)
      return;
   reversing_close_at = NowMs();

   if(reversing_flat)
      g_grid.CloseAllPositions("the opposite stop filled but reversing is not allowed");
   else
      g_grid.ClosePosition(old, "reversal — the opposite stop filled");
  }

//+------------------------------------------------------------------+
//| THE STATE MACHINE. Reconciles g_state with the broker's actual    |
//| positions. Runs on every pass and on every trade transaction.     |
//+------------------------------------------------------------------+
void StepState()
  {
   ENUM_POSITION_TYPE type = POSITION_TYPE_BUY;
   int   held   = g_grid.TotalPositions();
   ulong ticket = g_grid.NewestPosition(type);
   ENUM_EXEC_STATE active = (type == POSITION_TYPE_BUY) ? STATE_BUY_ACTIVE : STATE_SELL_ACTIVE;

   //--- A second position is either our opposite stop filling — a reversal —
   //--- or something the EA cannot explain.
   if(held > 1 && !g_state.Is(STATE_RECOVERY) && !g_state.Is(STATE_REVERSING))
     {
      if(IsReversalFill(held, ticket, type))
         BeginReversal(type);
      else
         g_state.Set(STATE_RECOVERY, StringFormat("%d positions open — one-position rule breached", held));
     }

   switch(g_state.State())
     {
      case STATE_INITIALIZING:
         if(held == 1)
            g_state.Set(active, "position found at startup", ticket);
         else
            g_state.Set(STATE_WAITING, "flat at startup");
         break;

      case STATE_WAITING:
         if(held == 1)
           {
            //--- Right after an exit, a new position is the reversal whose
            //--- fill arrived after the close.
            bool reversed = g_strategy.category == CATEGORY_REVERSAL && exit_settling_since > 0;
            g_state.Set(active, reversed ? "reversal — the opposite stop filled at the exit" : "entry filled", ticket);
            string blocked = reversed ? ReversalBlockedReason() : "";
            if(blocked != "" && InpAllowTrading && g_grid.TradingAllowed())
               BeginClose(ticket, StringFormat("the reversal filled, but %s", blocked));
           }
         break;

      case STATE_BUY_ACTIVE:
      case STATE_SELL_ACTIVE:
         if(held == 0)
           {
            //--- Closed by something other than a reversal: a take profit, a
            //--- manual close, a stop-out. That is not a signal to enter again
            //--- — the cooldown starts here — and the position's opposite stop
            //--- goes with it.
            //---
            //--- A reversal's stop loss and its opposite stop trigger on the
            //--- same quote, and the fill of the order can reach the terminal
            //--- a moment after the close. The order is left alone for
            //--- EXIT_SETTLE_MS so it is not cancelled while it fills;
            //--- ManageReversal withdraws it after that if it is still there.
            g_state.RecordClosedSide(g_state.Is(STATE_BUY_ACTIVE) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
            g_state.RecordClose();
            if(g_strategy.category == CATEGORY_REVERSAL)
               exit_settling_since = NowMs();
            g_state.Set(STATE_WAITING, StringFormat("#%I64u closed", g_state.Ticket()));
           }
         else if(ticket != g_state.Ticket() || !g_state.Is(active))
           {
            //--- The usual way a reversal completes now: the broker closed
            //--- the old position at its stop loss and opened this one.
            bool reversed = g_strategy.category == CATEGORY_REVERSAL && g_state.IsActive() && !g_state.Is(active);
            g_state.Set(active, reversed ? StringFormat("reversal — the broker closed #%I64u at its stop loss", g_state.Ticket())
                                         : "the open position changed", ticket);
            string blocked = reversed ? ReversalBlockedReason() : "";
            if(blocked != "" && InpAllowTrading && g_grid.TradingAllowed())
               BeginClose(ticket, StringFormat("the reversal filled, but %s", blocked));
           }
         break;

      case STATE_REVERSING:
         ContinueReversal(held, ticket, type);
         break;

      case STATE_CLOSING:
         if(g_grid.PositionConfirmedClosed(g_state.Ticket(), g_state.PositionId()))
           {
            g_state.RecordClose();
            if(held == 0)
               g_state.Set(STATE_WAITING, "close confirmed by the broker");
            else
               g_state.Set(active, "close confirmed; another position remains", ticket);
           }
         else if(g_state.MsInState() > (ulong)CLOSE_CONFIRM_TIMEOUT_SECONDS * 1000)
            g_state.Set(STATE_RECOVERY,
                        StringFormat("close of #%I64u not confirmed within %d s",
                                     g_state.Ticket(), CLOSE_CONFIRM_TIMEOUT_SECONDS),
                        g_state.Ticket());
         break;

      case STATE_RECOVERY:
         Recover(held, ticket, active);
         break;

      default:
         g_state.Set(STATE_RECOVERY, "unexpected state " + g_state.Name());
         break;
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(IsTester())
      return InitTester();

   if(StringLen(InpApiToken) == 0)
     {
      Print("GoldGrid: no API token set. Create one at Settings > API tokens and paste it into the EA inputs.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpStrategyId <= 0)
     {
      Print("GoldGrid: no strategy id set.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpReportSeconds < 5)
     {
      Print("GoldGrid: report interval must be at least 5 seconds.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_api.Configure(InpBaseUrl, InpApiToken);
   g_grid.Configure(InpMagicNumber, _Symbol, InpSlippagePoints);
   g_grid.LoadPeakEquity();

   g_state.Configure(InpMagicNumber, _Symbol);
   ENUM_EXEC_STATE previous = g_state.Load();
   g_started_ms = NowMs();
   g_cycle.Configure(InpMagicNumber, _Symbol);
   ENUM_CYCLE_STATE previous_cycle = g_cycle.Load();
   if(g_cycle.Number() > 0)
      PrintFormat("GoldGrid: grid cycle record — cycle %d, was %s%s", g_cycle.Number(), CycleStateName(previous_cycle),
                  g_cycle.Anchored() ? "" : ", not anchored");
   last_quote_at = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
   long since_close = g_state.SecondsSinceClose();
   PrintFormat("GoldGrid: previous session ended in state %s%s. Reconciling with the broker before "
               "anything is placed.", ExecStateName(previous),
               since_close == LONG_MAX ? "" : StringFormat(", last close %I64d s ago", since_close));

   if(!InpAllowTrading)
      Print("GoldGrid: AllowTrading is OFF. The EA will report state but place no orders.");

   //--- Said at startup rather than discovered later from an order that never
   //--- appears. A user who set "both directions" on a netting account has a
   //--- configuration that cannot do what they asked, and the only honest
   //--- moment to tell them is before it starts.
   if(!g_grid.AccountIsHedging())
      Print("GoldGrid: this is a NETTING account — one position per symbol. "
            "Only one direction can be held at a time; a both-directions strategy "
            "will run whichever side opens first and refuse the other.");

   //--- Confirm the platform is reachable and the URL is whitelisted before
   //--- the user assumes everything is working.
   ENUM_API_RESULT ping = g_api.Ping();
   if(ping != API_OK)
     {
      PrintFormat("GoldGrid: cannot reach the platform — %s", g_api.LastError());
      if(ping == API_NOT_ALLOWED)
         return INIT_FAILED;
     }
   else
     {
      Print("GoldGrid: platform reachable.");
     }

   RefreshConfiguration();
   EventSetTimer(1);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Print("GoldGrid: stopped. Open positions are NOT closed by removing the EA.");
  }

//+------------------------------------------------------------------+
//| Trading decisions run on the timer rather than on every tick, so  |
//| behaviour does not depend on market activity.                     |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_grid.TrackEquity();
   //--- Keeps the grid's cycle record from expiring (the terminal deletes a
   //--- global variable untouched for four weeks). Nothing to do for the
   //--- other categories, whose record is written on every transition.
   if(g_strategy.category == CATEGORY_GRID)
      g_cycle.Touch();

   //--- The tester has no platform to refresh from or report to.
   if(IsTester())
     {
      ManageBaskets();
      return;
     }

   if(NowMs() - last_config_at >= (ulong)InpConfigSeconds * 1000)
      RefreshConfiguration();

   ManageBaskets();

   if(NowMs() - last_report_at >= (ulong)InpReportSeconds * 1000)
      SendReport();
  }

//+------------------------------------------------------------------+
bool ConfigurationIsFresh()
  {
   if(!g_strategy.loaded)
      return false;
   //--- The tester's configuration comes from its inputs and cannot go stale.
   if(IsTester())
      return true;
   return (NowMs() - g_strategy.fetched_at) <= (ulong)CONFIG_STALE_AFTER_SECONDS * 1000;
  }

//+------------------------------------------------------------------+
void RefreshConfiguration()
  {
   last_config_at = NowMs();

   CJsonNode *document = NULL;
   ENUM_API_RESULT result = g_api.FetchStrategy(InpStrategyId, document);

   if(result != API_OK)
     {
      //--- A revoked token is terminal: stop trying to trade and tell the user.
      //---
      //--- Alert only on the transition into the halted state. Polling has to
      //--- continue so the EA can recover on its own once a new token is
      //--- pasted in, but Alert() raises a modal popup with a sound, and
      //--- firing one every report interval turns a single problem into an
      //--- unusable terminal that the user has to kill.
      if(result == API_UNAUTHORIZED)
        {
         if(!halted)
            Alert("GoldGrid: ", g_api.LastError());
         halted = true;
         halt_reason = g_api.LastError();
        }
      PrintFormat("GoldGrid: configuration refresh failed — %s", g_api.LastError());
      if(CheckPointer(document) == POINTER_DYNAMIC)
         delete document;
      return;
     }

   SGridStrategy fetched;
   string error;
   if(!ParseStrategy(document, fetched, error))
     {
      PrintFormat("GoldGrid: unusable configuration — %s", error);
      delete document;
      return;
     }
   delete document;

   if(fetched.symbol != _Symbol)
     {
      halted = true;
      halt_reason = StringFormat("Strategy is configured for %s but the EA is attached to %s.",
                                 fetched.symbol, _Symbol);
      Alert("GoldGrid: ", halt_reason);
      return;
     }

   //--- Recovered from an earlier authorisation failure.
   if(halted && StringFind(halt_reason, "token") >= 0)
     {
      halted = false;
      halt_reason = "";
     }

   g_strategy = fetched;
  }

//+------------------------------------------------------------------+
//| Basket management. Runs even when the strategy is stopped or the  |
//| platform is unreachable, so an open basket always keeps its exit  |
//| rules.                                                            |
//+------------------------------------------------------------------+
void ManageBaskets()
  {
   if(!g_strategy.loaded)
      return;

   TrackQuotes();

   //--- Stops first, before anything can be closed or opened.
   //---
   //--- A trailing stop is protection that already exists on the broker's
   //--- side; moving it forward costs nothing and can only ever tighten. Doing
   //--- it ahead of the exit and entry logic means a position that is about to
   //--- be joined by another level is already protected at its own best price,
   //--- rather than waiting a further pass for it.
   //---
   //--- This runs regardless of InpAllowTrading and of whether the strategy is
   //--- running. Refusing to move a stop on a position that is already open
   //--- would not be caution: it would leave the user exposed to exactly the
   //--- loss they configured the stop to prevent.
   g_grid.ApplyTrailingStops(g_strategy);

   //--- Reconcile the execution state with the broker before anything else.
   //--- While a close awaits confirmation, or the account is in RECOVERY,
   //--- nothing further is decided this pass — the stops above still trail.
   if(SinglePositionMode())
      StepState();

   //--- Outside the broker's trading session (weekend, gold's daily break)
   //--- every request is rejected with "Market closed", so none is sent: no
   //--- entries, no cancels, no closes. Resting orders and the positions'
   //--- stops are held by the broker meanwhile. The state machine above has
   //--- still reconciled, so the first pass after the open acts on the truth.
   static bool closed_noted = false;
   if(g_grid.TradingGate() == GATE_MARKET_CLOSED)
     {
      //--- Close-only (the broker forbids new entries, not closes): a grid
      //--- basket at its target, or under a risk halt, is still closed.
      bool close_only = g_strategy.category == CATEGORY_GRID && g_grid.OnlyClosesAllowed();
      if(!closed_noted)
         Print(close_only ? "GoldGrid: the symbol is close-only — the basket is still closed at its target or on a "
                            "risk halt; nothing new is placed"
                          : "GoldGrid: market closed for this symbol — sending nothing until it opens");
      closed_noted = true;
      if(close_only)
         ManageGridCloseOnly();
      return;
     }
   if(closed_noted)
      Print("GoldGrid: market open again");
   closed_noted = false;

   //--- Emergency stop and daily loss act on what is open, in every state —
   //--- RECOVERY included.
   if(EnforceRiskHalts())
      return;

   if(SinglePositionMode() && (g_state.Is(STATE_CLOSING) || g_state.Is(STATE_RECOVERY)))
      return;

   //--- A trailing strategy enters at market and never places a pending
   //--- order, so any resting order with this magic number is a stray — left
   //--- by an older build, a manual order, a retried request — and a second
   //--- way to open a position. It goes at once. (Found by the tester's
   //--- invariant monitor: a stray rested beside the open position forever,
   //--- because only the reversal path cleaned orders up.)
   if(g_strategy.category == CATEGORY_TRAILING && InpAllowTrading)
     {
      int removed = g_grid.DeleteAllPendingStops() + g_grid.DeleteStrayOrders();
      if(removed > 0)
         PrintFormat("GoldGrid: removed %d stray pending order(s) — a trailing strategy places none", removed);
     }

   if(g_strategy.category == CATEGORY_REVERSAL)
     {
      ManageReversal();
      return;
     }

   if(g_strategy.category == CATEGORY_GRID)
     {
      ManageGridCycle();
      return;
     }

   ManageDirection(POSITION_TYPE_BUY);
   ManageDirection(POSITION_TYPE_SELL);
  }

//+------------------------------------------------------------------+
//| Closes a basket that has reached its take profit or stop loss.   |
//| Returns true if it did.                                           |
//+------------------------------------------------------------------+
bool ExitBasketIfDue(const ENUM_POSITION_TYPE type, const SBasket &basket)
  {
   if(!g_grid.ShouldCloseBasket(g_strategy, basket))
      return false;

   //--- A close is an order, and the master switch means none is sent. The
   //--- position keeps its stop, which the broker holds.
   if(!InpAllowTrading)
     {
      NoteGate(type, "basket exit reached, but AllowTrading is off — not closing");
      return false;
     }

   //--- The close is tracked through CLOSING until the broker confirms it, so
   //--- nothing can open in the meantime. (Only trailing and reversal reach
   //--- this: the grid has its own combined-basket exit.)
   int closed = 0;
   ENUM_POSITION_TYPE held_type;
   ulong ticket = g_grid.OurPosition(held_type);
   if(ticket != 0 && held_type == type && BeginClose(ticket, "basket exit"))
      closed = 1;

   //--- Record *why*, and the spread at the moment of the decision.
   //---
   //--- A basket is valued at the price it could be closed at, so it carries
   //--- the full spread. When the spread widens — rollover, news, thin
   //--- liquidity — a basket can cross its stop loss without the market
   //--- having moved against it at all. Observed on a demo account: the EA
   //--- measured -1.55 and stopped out while the spread was 245 points; the
   //--- actual fill was -0.23. Without the spread in this line that looks
   //--- like a broker discrepancy rather than what it is.
   string why = "stop loss";
   if(g_strategy.has_basket_take_profit && basket.profit >= g_strategy.basket_take_profit)
      why = "take profit";

   PrintFormat("GoldGrid: closed %d %s position(s) on %s, basket P/L %.2f, spread %d points",
               closed, type == POSITION_TYPE_BUY ? "buy" : "sell", why, basket.profit,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   return true;
  }

//+------------------------------------------------------------------+
void ManageDirection(const ENUM_POSITION_TYPE type)
  {
   //--- Skip a direction the strategy does not use.
   if(g_strategy.direction == GRID_BUY_ONLY  && type == POSITION_TYPE_SELL) return;
   if(g_strategy.direction == GRID_SELL_ONLY && type == POSITION_TYPE_BUY)  return;

   SBasket basket = g_grid.Basket(type);

   //--- 1. Exits first. Closing takes precedence over opening, always.
   if(ExitBasketIfDue(type, basket))
      return;

   //--- 2. Opening is gated.
   if(halted || !InpAllowTrading)
      return;

   //--- A trailing strategy holds ONE position in total, not one per direction:
   //--- a buy and a sell side by side were each stopped out in turn and
   //--- re-opened, which is how losses compounded. Whichever side is open, the
   //--- other waits until it has closed and the cooldown has passed.
   //--- With both directions allowed, the next entry is the side opposite the
   //--- one that just closed: a trailing stop is hit because price turned, so
   //--- re-entering the same way means betting against the move that took the
   //--- last position out. The first entry ever is a buy.
   if(SinglePositionMode() && g_strategy.direction == GRID_BOTH && g_state.LastSide() == (int)type)
      return;

   if(SinglePositionMode())
     {
      string why;
      if(!EntryAllowed(why))
        {
         if(why != "")
            NoteGate(type, why);
         return;
        }
     }

   //--- A trailing strategy holds one position per direction at most, and
   //--- SinglePositionMode() above reduces that to one in total.
   if(basket.count > 0)
      return;

   double next_lot = EntryLot(g_strategy, _Symbol);

   string reason;
   if(!g_grid.MayOpen(g_strategy, ConfigurationIsFresh(), next_lot, type, reason))
     {
      //--- Noted per direction: with a both-directions strategy a single note
      //--- meant the buy side's reason overwrote the sell side's and each one
      //--- reprinted the other's, every pass.
      string note = StringFormat("%s:%s", type == POSITION_TYPE_BUY ? "buy" : "sell", reason);
      if(note != last_gate_note)
        {
         PrintFormat("GoldGrid: not opening %s — %s",
                     type == POSITION_TYPE_BUY ? "buy" : "sell", reason);
         last_gate_note = note;
        }
      return;
     }
   last_gate_note = "";

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   //--- Do not stack orders in THIS direction while a previous fill is still
   //--- settling. The other direction is free to open on the same pass.
   if(NowMs() - last_open_at[DirectionSlot(type)] < (ulong)OPEN_COOLDOWN_SECONDS * 1000)
      return;

   //--- The position opens at market, with its stop already attached: it has
   //--- no other exit, so it is never left without one while it waits to
   //--- reach activation.
   //---
   //--- This is also the re-entry: once a trailing stop takes the position
   //--- out, the account is flat again and a later pass opens afresh. That is
   //--- deliberate — a trailing strategy is meant to keep working the market,
   //--- not to stop after one trade.
   int initial_stop = g_strategy.trailing_stop_points;

   //--- Locked before the request, not after: whatever it returns, the next
   //--- pass must not read the account as flat while it settles.
   LockEntries(OPEN_COOLDOWN_SECONDS);
   if(g_grid.OpenMarket(type, next_lot, StringFormat("GG:%I64d:L1", g_strategy.id), initial_stop))
     {
      last_open_at[DirectionSlot(type)] = NowMs();
      LogOpen(type, 1, next_lot);
     }
  }

//+------------------------------------------------------------------+
//| THE GRID: A LADDER OF STOP ORDERS, CLOSED TOGETHER.               |
//|                                                                   |
//| Each cycle rests `grid_buy_orders` Buy Stops above the market and |
//| `grid_sell_orders` Sell Stops below it, `grid_spacing_points`     |
//| apart. Rungs fill as price reaches them; the open positions are   |
//| one basket, closed together when their combined floating profit   |
//| reaches `basket_take_profit`; the rest of the ladder is cancelled,|
//| the EA waits `grid_cycle_pause_seconds`, and a new cycle begins.  |
//|                                                                   |
//| What the EA is doing is held in g_cycle (Include/GoldGrid/        |
//| Cycle.mqh), persisted across restarts and reconciled against the  |
//| broker in INITIALIZING:                                           |
//|                                                                   |
//|   INITIALIZING --reconcile--> PLACING --ladder complete--> ARMED  |
//|   PLACING / ARMED / RECOVERY --target reached--> CLOSING          |
//|   CLOSING --confirmed flat--> COOLDOWN --pause over--> PLACING    |
//|   INITIALIZING --ours on the broker, no cycle--> RECOVERY         |
//|   RECOVERY --nothing of ours left--> COOLDOWN                     |
//|                                                                   |
//| DUPLICATE PROTECTION. Orders are sent from PLACING only. PLACING  |
//| is entered from COOLDOWN after a confirmed flat, from             |
//| INITIALIZING with a cycle adopted from the broker, or from ARMED  |
//| when a rung is found missing. PlaceLadder itself only ever sends  |
//| rungs that neither rest nor have filled, so even a pass repeated  |
//| in the same instant (a tick storm) sends nothing twice.           |
//|                                                                   |
//| THE ANCHOR. The ladder is measured from one bid/ask, taken when   |
//| the first rung is sent and fixed for the rest of the cycle (D5).  |
//| Until that moment nothing is committed, so the anchor follows the |
//| market: a strategy that starts during a gate — spread, session,   |
//| stale configuration — does not place its ladder around a price    |
//| from an hour ago when the gate opens.                             |
//|                                                                   |
//| THE CLOSE. Positions first, then every order, every pass, until   |
//| the broker confirms each position closed and nothing of ours is   |
//| left — a rung that fills mid-close is caught by the next pass.    |
//| Nothing new is placed until then.                                 |
//+------------------------------------------------------------------+
#define LADDER_REQUESTS_PER_PASS 10
//--- How long after a send before the broker's lists are trusted to show
//--- it. Nothing is concluded from them meanwhile — no "rung missing", no
//--- "nothing of ours left" — and nothing new is sent.
#define LADDER_SEND_SETTLE_MS 2000
//--- How long after OnInit before an empty account is believed to be empty.
#define CYCLE_SETTLE_AFTER_START_MS 5000
//--- A cycle whose close will not confirm, or whose orders will not cancel,
//--- is reported at this interval.
#define CYCLE_STUCK_REPORT_MS (5 * 60 * 1000)

CCycleState g_cycle;

//--- In-memory bookkeeping for the current run. A restart goes through
//--- INITIALIZING, which rebuilds all of it from the broker and g_cycle.
int    g_ladder_seen_picture  = -1;    // LadderPicture() at the last full pass
ulong  g_ladder_last_send_ms  = 0;
ulong  g_ladder_checked_ms    = 0;
int    g_ladder_skipped       = 0;     // rungs the last pass found crossed
ulong  g_ladder_empty_since   = 0;     // the broker has shown nothing of ours since
bool   g_ladder_capacity_cut  = false; // the last pass had less room than the ladder
ulong  g_started_ms           = 0;     // OnInit, for the start-up settle
string g_ladder_gate_note     = "";
ENUM_CYCLE_STATE g_ladder_gate_state = CYCLE_INITIALIZING;   // where the note was set (GateNoteApplies)
int    g_ladder_gate_cycle    = 0;
//--- Close passes are 2 s apart, so an asynchronous close still executing is
//--- not sent again; a close the broker refused outright is retried after
//--- 500 ms (NoteCloseRejection).
#define CLOSE_RETRY_PACE_MS            2000
#define CLOSE_RETRY_AFTER_REJECTION_MS 500
#define CLOSE_FAST_RETRIES_MAX         3      // per close; then the 2 s pace
int    g_close_fast_retries   = 0;
int    g_close_passes         = 0;
uint   g_close_reject_code    = 0;            // last rejection printed, for the log throttle
ulong  g_close_reject_ms      = 0;
int    g_close_reject_quiet   = 0;            // rejections not printed since
bool   g_ladder_gate_entry    = false;        // the note is an entry gate (halt, stopped, ...)
string g_cycle_close_reason   = "";
ulong  g_cycle_close_attempt  = 0;
ulong  g_cycle_stuck_reported = 0;
int    g_cycle_close_cancelled = 0;
//--- Tester statistics.
int    g_ladder_max_orders    = 0;
int    g_ladder_requests      = 0;
double g_ladder_closed_profit = 0.0;

void ManageGridCycle()
  {
   //--- THE MONITOR runs first, in every state but CLOSING itself. A basket
   //--- at its target is closed whether or not anything may be placed —
   //--- in RECOVERY too.
   if(!g_cycle.Is(CYCLE_CLOSING) && !g_cycle.Is(CYCLE_INITIALIZING))
     {
      SBasket basket = g_grid.CombinedBasket();
      string  why    = g_grid.BasketExitReason(g_strategy, basket);
      if(why != "")
        {
         //--- A close is an order, and the master switch means none is sent.
         if(!InpAllowTrading)
           {
            NoteGridGate(StringFormat("%s, but AllowTrading is off — not closing", why));
            return;
           }
         BeginCycleClose(why, basket);
        }
     }

   switch(g_cycle.State())
     {
      case CYCLE_INITIALIZING: ReconcileCycle();  return;
      case CYCLE_CLOSING:      CloseCycle();      return;
      case CYCLE_COOLDOWN:     CooldownCycle();   return;
      case CYCLE_RECOVERY:     RecoverCycle();    return;
      case CYCLE_PLACING:
      case CYCLE_ARMED:        PlaceCycle();      return;
     }
  }

//+------------------------------------------------------------------+
//| INITIALIZING: the persisted cycle meets the broker.               |
//|                                                                   |
//|   ours on the broker, cycle readable  -> adopt it, PLACING        |
//|   ours on the broker, no cycle        -> RECOVERY                 |
//|   nothing of ours, pause remaining    -> COOLDOWN                 |
//|   nothing of ours, first run ever     -> cycle 1, PLACING         |
//|   nothing of ours, a cycle on record  -> it ended outside the EA  |
//|                                          (a risk halt, a manual   |
//|                                          close): next cycle,      |
//|                                          COOLDOWN                 |
//+------------------------------------------------------------------+
void ReconcileCycle()
  {
   //--- Nothing can be concluded from empty lists before the terminal has
   //--- its account data: a start alongside the terminal, or a reconnect,
   //--- shows no orders and no positions for a moment, and "nothing of ours"
   //--- would retire a live cycle and place a second ladder over it.
   if(!IsTester() && !TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      NoteGridGate("waiting for the terminal to connect before reading the account");
      return;
     }
   if(!IsTester() && NowMs() - g_started_ms < CYCLE_SETTLE_AFTER_START_MS)
      return;

   int orders    = g_grid.OurOrders();
   int positions = g_grid.TotalPositions();

   if(orders + positions > 0)
     {
      int      number;
      double   bid, ask;
      datetime since;
      //--- The record's shape (gap, first offset) describes the record's
      //--- cycle; the broker's rungs are read with it first, and with the
      //--- live configuration if they turn out to belong to another cycle.
      SGridStrategy shape = LadderShape();
      int  first_hint = g_cycle.Anchored() ? g_cycle.FirstPoints() : 0;
      bool readable   = g_grid.RecoverLadder(shape, first_hint, number, bid, ask, since);
      if(readable && number != g_cycle.Number())
         readable = g_grid.RecoverLadder(g_strategy, 0, number, bid, ask, since);

      if(readable && number < g_cycle.Number())
        {
         //--- Rungs of a cycle the record has already retired: its basket
         //--- was confirmed flat and the number advanced, and these orders
         //--- were listed late. They are leftovers, not a cycle to resume —
         //--- adopting them would roll the number back and re-place a ladder
         //--- whose basket is gone. COOLDOWN withdraws orders; positions, if
         //--- any, belong to no live cycle and go through RECOVERY.
         PrintFormat("GoldGrid: %d order(s) and %d position(s) carry cycle %d, but the record is already on "
                     "cycle %d — treated as leftovers", orders, positions, number, g_cycle.Number());
         if(positions > 0)
            g_cycle.Set(CYCLE_RECOVERY, StringFormat("positions of retired cycle %d are still open", number));
         else
            g_cycle.Set(CYCLE_COOLDOWN, StringFormat("orders of retired cycle %d are still resting", number));
         return;
        }

      if(readable)
        {
         if(number != g_cycle.Number() || !g_cycle.Anchored())
           {
            PrintFormat("GoldGrid: the broker's orders say cycle %d anchored at %s/%s; the record said cycle %d%s — "
                        "the broker wins", number, DoubleToString(bid, _Digits), DoubleToString(ask, _Digits),
                        g_cycle.Number(), g_cycle.Anchored() ? "" : " with no anchor");
            //--- The record's shape is kept when it was made for this very
            //--- cycle; otherwise the live configuration is the best guess.
            bool same = number == g_cycle.Number() && g_cycle.Anchored() && g_cycle.Gap() > 0;
            g_cycle.Adopt(number, bid, ask,
                          same ? g_cycle.Gap()       : g_strategy.grid_spacing_points,
                          same ? g_cycle.BuyRungs()  : g_strategy.grid_buy_orders,
                          same ? g_cycle.SellRungs() : g_strategy.grid_sell_orders,
                          same ? g_cycle.FirstPoints() : g_grid.FirstRungPoints(g_strategy.grid_spacing_points),
                          same && g_cycle.Lot() > 0.0 ? g_cycle.Lot() : EntryLot(g_strategy, _Symbol), since);
           }
        }
      else if(g_cycle.Number() > 0 && g_cycle.Anchored())
        {
         //--- Comments stripped by the broker, or only positions without a
         //--- ladder comment remain (a chaos injection, a manual trade with
         //--- our magic): the record is all there is, and it is enough.
         PrintFormat("GoldGrid: %d order(s) and %d position(s) of ours carry no readable cycle — continuing "
                     "cycle %d from the record, anchored at %s/%s", orders, positions, g_cycle.Number(),
                     DoubleToString(g_cycle.AnchorBid(), _Digits), DoubleToString(g_cycle.AnchorAsk(), _Digits));
        }
      else
        {
         g_cycle.Set(CYCLE_RECOVERY, StringFormat("%d order(s) and %d position(s) of ours on the broker, but no cycle "
                                                  "can be reconstructed from them or from the record", orders, positions));
         return;
        }

      //--- Rungs that filled before the restart, open or since closed, so
      //--- none is placed twice in the cycle (D6).
      g_grid.RebuildFilled(g_strategy.id, g_cycle.Number(), g_cycle.AnchorAt());
      ResetLadderMemory();

      //--- A close that was interrupted is a close, not a ladder to complete:
      //--- the cycle's orders are gone, part of its basket may be, and
      //--- re-placing the ladder would run half a basket on indefinitely.
      if(g_cycle.Previous() == CYCLE_CLOSING)
        {
         BeginCycleClose("resumed after a restart — the close had begun", g_grid.CombinedBasket());
         return;
        }
      if(g_cycle.Previous() == CYCLE_RECOVERY)
        {
         g_cycle.Set(CYCLE_RECOVERY, "the record says RECOVERY, and something of ours is still on the broker");
         return;
        }

      g_cycle.Set(CYCLE_PLACING, StringFormat("cycle %d adopted from the broker — %d order(s) resting, %d position(s) "
                                              "open, %d rung(s) filled so far", g_cycle.Number(), orders, positions,
                                              g_grid.FilledCount(g_cycle.Number())));
      return;
     }

   if(g_cycle.PauseRemaining(g_strategy.grid_cycle_pause_seconds) > 0)
     {
      g_cycle.Set(CYCLE_COOLDOWN, StringFormat("flat; %d s of the pause before cycle %d remain",
                                               (int)g_cycle.PauseRemaining(g_strategy.grid_cycle_pause_seconds),
                                               g_cycle.Number()));
      return;
     }

   if(g_cycle.Number() == 0)
     {
      g_cycle.Begin();
      ResetLadderMemory();
      g_cycle.Set(CYCLE_PLACING, "first cycle");
      return;
     }

   if(g_cycle.Anchored())
     {
      //--- A cycle was under way and nothing of it is left: it ended without
      //--- the EA seeing the end. Its number is retired so its comments are
      //--- never reused, and the pause applies as after any close.
      g_cycle.NextCycle(g_strategy.grid_cycle_pause_seconds);
      g_cycle.Set(CYCLE_COOLDOWN, StringFormat("cycle %d ended outside the EA (nothing of ours on the broker); "
                                               "cycle %d after the pause", g_cycle.Number() - 1, g_cycle.Number()));
      return;
     }

   //--- A cycle number but no anchor: the previous run never sent a rung.
   g_cycle.EndPause();
   ResetLadderMemory();
   g_cycle.Set(CYCLE_PLACING, StringFormat("cycle %d had not placed anything yet", g_cycle.Number()));
  }

//--- The strategy as the ladder sees it: the shape the cycle anchored with
//--- (D8 corollary — a setting changed on the platform applies to the next
//--- cycle), the rest of the configuration live.
SGridStrategy LadderShape()
  {
   SGridStrategy shape = g_strategy;
   if(g_cycle.Anchored() && g_cycle.Gap() > 0)
     {
      shape.grid_spacing_points = g_cycle.Gap();
      shape.grid_buy_orders     = g_cycle.BuyRungs();
      shape.grid_sell_orders    = g_cycle.SellRungs();
      if(g_cycle.Lot() > 0.0)
         shape.initial_lot      = g_cycle.Lot();
     }
   return shape;
  }

//+------------------------------------------------------------------+
//| PLACING and ARMED. Hygiene, then the ladder; the monitor has      |
//| already run. ARMED re-checks the ladder when the picture changes, |
//| or once a second while a skipped rung might have come back into   |
//| reach, and goes back to PLACING if a rung is missing.             |
//+------------------------------------------------------------------+
void PlaceCycle()
  {
   if(!InpAllowTrading || halted)
     {
      NoteGridGate(halted ? halt_reason : "AllowTrading is off", true);
      return;
     }

   //--- A ladder is two baskets side by side; a netting account would turn a
   //--- buy fill and a sell fill into one flat position.
   if(!g_grid.AccountIsHedging())
     {
      NoteGridGate(TradeGateReason(GATE_NETTING_OPPOSITE), true);
      return;
     }

   //--- STOPPED ON THE PLATFORM. A resting rung is nothing but a future
   //--- entry, and "stopped" means no new entries: the rungs are withdrawn.
   //--- The open basket is not touched — the monitor above keeps closing it
   //--- at its target, consistent with "stopping is not close everything".
   //--- When the strategy is started again the cycle resumes here: with a
   //--- basket still open, its missing rungs are re-placed at the same
   //--- anchor; with nothing left, the cycle is retired below.
   if(!g_strategy.IsRunning())
     {
      if(g_grid.OurOrders() > 0 && NowMs() - g_cycle_close_attempt >= CLOSE_RETRY_PACE_MS)
        {
         g_cycle_close_attempt = NowMs();
         //--- Sent in parallel: one reply at a time, a 50-rung ladder held
         //--- this pass, and the open basket's target with it, for seconds.
         int withdrawn = g_grid.DeleteAllOrders(true);
         if(withdrawn > 0)
            PrintFormat("GoldGrid: the strategy is stopped — withdrawing %d resting ladder order(s); %d open position(s) "
                        "keep their basket target", withdrawn, g_grid.TotalPositions());
        }
      NoteGridGate(g_grid.TotalPositions() > 0 ? "the strategy is stopped — the open basket is managed, nothing new rests"
                                               : "the strategy is stopped", true);
      return;
     }

   //--- Every entry gate is open again: a note one of them left is no longer
   //--- true. Cleared here, ahead of the early returns below — an ARMED
   //--- ladder whose picture did not change would otherwise go on reporting
   //--- "the strategy is stopped" after it was started again.
   if(g_ladder_gate_entry)
     {
      g_ladder_gate_note  = "";
      g_ladder_gate_entry = false;
     }

   //--- The broker's lists lag a send by up to a few hundred milliseconds,
   //--- and ticks can arrive faster than that. Until a send has settled
   //--- nothing is concluded from the lists: no "rung missing", no "nothing
   //--- of ours left", no second copy of a rung that is simply not listed
   //--- yet. (The tester's lists update synchronously; live they do not.)
   bool settled = NowMs() - g_ladder_last_send_ms >= LADDER_SEND_SETTLE_MS;
   if(!settled)
      return;

   SGridStrategy shape = LadderShape();

   //--- A committed cycle with nothing left on the broker ended outside the
   //--- EA — a risk halt cancelled and closed everything, or the user did.
   //--- Believed only once the empty picture has held for a few seconds with
   //--- the terminal connected: on a reconnect the lists blink empty for a
   //--- moment, and retiring a live cycle on that would place a second ladder
   //--- beside its basket.
   bool empty = g_grid.OurOrders() == 0 && g_grid.TotalPositions() == 0 &&
                (IsTester() || TerminalInfoInteger(TERMINAL_CONNECTED));
   if(!empty)
      g_ladder_empty_since = 0;
   else if(g_ladder_empty_since == 0)
      g_ladder_empty_since = NowMs();
   if(g_cycle.Anchored() && empty)
     {
      if(NowMs() - g_ladder_empty_since < CYCLE_SETTLE_AFTER_START_MS)
         return;
      g_cycle.NextCycle(g_strategy.grid_cycle_pause_seconds);
      g_cycle.Set(CYCLE_COOLDOWN, StringFormat("cycle %d ended outside the EA (nothing of ours left on the broker); "
                                               "cycle %d after the pause", g_cycle.Number() - 1, g_cycle.Number()));
      return;
     }

   //--- A complete ladder is only re-checked when something changed: a fill
   //--- or a cancel moves the order or position picture — or, with a rung
   //--- skipped, once a second, in case the market has come back to its side.
   //--- Sixty rungs against sixty orders on every tick would be a lot of
   //--- reading for nothing. The same while the risk gate (or the broker)
   //--- refuses: re-asked once a second, not on every tick.
   bool same_picture = LadderPicture() == g_ladder_seen_picture;
   bool due          = NowMs() - g_ladder_checked_ms >= 1000;
   //--- A ladder cut by the broker's order limit is re-checked once a minute
   //--- as well, in case other orders on the account have gone and room has
   //--- opened up.
   bool cut_due      = g_ladder_capacity_cut && NowMs() - g_ladder_checked_ms >= 60000;
   if(g_cycle.Is(CYCLE_ARMED) && same_picture && !(g_ladder_skipped > 0 && due) && !cut_due)
      return;
   if(g_cycle.Is(CYCLE_PLACING) && same_picture && g_ladder_gate_note != "" && !due)
      return;
   g_ladder_checked_ms = NowMs();

   //--- Nothing of ours rests but rungs of this cycle. Checked here, behind
   //--- the pacing above, rather than on every tick.
   if(g_grid.DeleteLadderStrays(shape, g_cycle.Number()) > 0)
      g_ladder_seen_picture = -1;

   //--- Until the first rung is sent, the ladder is measured from the market
   //--- as it is now.
   double anchor_bid = g_cycle.Anchored() ? g_cycle.AnchorBid() : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double anchor_ask = g_cycle.Anchored() ? g_cycle.AnchorAsk() : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    first      = g_cycle.Anchored() && g_cycle.FirstPoints() > 0
                       ? g_cycle.FirstPoints() : g_grid.FirstRungPoints(shape.grid_spacing_points);

   //--- ARMED only looks (a request budget of zero); a missing rung sends it
   //--- back to PLACING, the one state that places.
   int budget = g_cycle.Is(CYCLE_PLACING) ? LADDER_REQUESTS_PER_PASS : 0;

   SLadderReport report;
   bool complete = g_grid.PlaceLadder(shape, ConfigurationIsFresh(), g_cycle.Number(),
                                      anchor_bid, anchor_ask, first, budget, report);
   g_ladder_requests += report.placed;
   g_ladder_skipped   = report.skipped;
   g_ladder_capacity_cut = report.capacity < shape.LadderSize();
   if(report.requests > 0)
      g_ladder_last_send_ms = NowMs();

   if(report.placed > 0 && !g_cycle.Anchored())
     {
      g_cycle.Anchor(anchor_bid, anchor_ask, shape.grid_spacing_points, shape.grid_buy_orders,
                     shape.grid_sell_orders, first, EntryLot(shape, _Symbol));
      PrintFormat("GoldGrid: ladder cycle %d anchored at %s/%s — %d Buy Stop(s) above, %d Sell Stop(s) below, "
                  "%d points apart (rung 1 at %d), %.2f lots each, capacity %d",
                  g_cycle.Number(), DoubleToString(anchor_bid, _Digits), DoubleToString(anchor_ask, _Digits),
                  shape.grid_buy_orders, shape.grid_sell_orders, shape.grid_spacing_points, first,
                  EntryLot(shape, _Symbol), report.capacity);
     }
   //--- Rungs held without a persisted anchor: only a position matched by
   //--- the comment-less fallback can bring this about (RecoverLadder
   //--- anchored every readable case in INITIALIZING).
   if(report.resting + report.held > 0 && !g_cycle.Anchored())
      g_cycle.Anchor(anchor_bid, anchor_ask, shape.grid_spacing_points, shape.grid_buy_orders,
                     shape.grid_sell_orders, first, EntryLot(shape, _Symbol));

   if(report.refused != "")
      NoteGridGate(report.refused);
   else
      g_ladder_gate_note = "";

   g_ladder_seen_picture = LadderPicture();
   g_ladder_max_orders   = MathMax(g_ladder_max_orders, g_grid.OurOrders());

   if(complete && g_cycle.Is(CYCLE_PLACING))
      g_cycle.Set(CYCLE_ARMED, StringFormat("ladder complete — %d resting, %d filled, %d skipped, capacity %d",
                                            report.resting + report.placed, report.held, report.skipped, report.capacity));
   else if(!complete && g_cycle.Is(CYCLE_ARMED) && report.refused == "")
      g_cycle.Set(CYCLE_PLACING, "a rung is missing from the ladder");
  }

//+------------------------------------------------------------------+
//| CLOSING. Entered by the monitor from any placing state.           |
//+------------------------------------------------------------------+
void BeginCycleClose(const string why, const SBasket &basket)
  {
   g_cycle_close_reason    = why;
   g_cycle_close_attempt   = 0;
   g_close_fast_retries    = 0;
   g_close_passes          = 0;
   g_close_reject_code     = 0;
   g_close_reject_quiet    = 0;
   g_cycle_stuck_reported  = 0;
   g_cycle_close_cancelled = 0;
   g_grid.BeginBasketClose();
   PrintFormat("GoldGrid: ladder cycle %d closing — %s; %d position(s), %.2f lots, %d order(s) resting, "
               "spread %I64d points", g_cycle.Number(), why, basket.count, basket.volume, g_grid.OurOrders(),
               SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   g_cycle.Set(CYCLE_CLOSING, why);
  }

//--- One pass of the close, paced so a broker that keeps rejecting is not
//--- hammered on every tick; then confirmation; then the next cycle is set
//--- up behind the pause.
void CloseCycle()
  {
   if(g_grid.TotalPositions() > 0 || g_grid.OurOrders() > 0)
     {
      if(!InpAllowTrading)
        {
         NoteGridGate("closing, but AllowTrading is off — nothing is sent");
         return;
        }
      if(NowMs() - g_cycle_close_attempt < CLOSE_RETRY_PACE_MS)
         return;
      g_cycle_close_attempt = NowMs();

      int closes = 0, cancelled = 0;
      int failed = g_grid.CloseBasketPass(g_cycle_close_reason, closes, cancelled);
      g_close_passes++;
      if(g_close_passes == 1)
         g_cycle_close_cancelled = cancelled;   // a retry's cancels are mostly repeats
      if(closes + cancelled > 0)
         PrintFormat("GoldGrid: close pass %d — %d close(s) and %d cancel(s) sent together", g_close_passes, closes,
                     cancelled);
      if(failed > 0)
         PrintFormat("GoldGrid: %d close(s) could not be sent — retrying", failed);
      ReportIfStuck("the close has not completed");
      return;
     }

   if(!g_grid.BasketConfirmedFlat())
     {
      //--- The open list is empty but the history has not shown every close
      //--- yet. Normally a pass or two; a user has to hear about longer.
      ReportIfStuck("the broker's history does not yet confirm every close");
      return;
     }

   double realised = g_grid.ClosedBasketProfit();
   g_ladder_closed_profit += realised;
   PrintFormat("GoldGrid: ladder cycle %d flat — %d position(s) closed for %.2f, %d order(s) cancelled, %s; "
               "cycle %d in %d s", g_cycle.Number(), g_grid.ClosingPositions(), realised, g_cycle_close_cancelled,
               g_cycle_close_reason, g_cycle.Number() + (g_cycle.Anchored() ? 1 : 0),
               g_strategy.grid_cycle_pause_seconds);

   //--- A basket closed under a cycle that never placed a ladder (a position
   //--- that appeared by hand during COOLDOWN, or positions found in RECOVERY
   //--- before any cycle existed) keeps the cycle number: there are no
   //--- comments of this number to retire. A number of 0 is never kept — a
   //--- ladder commented C0 could not be recovered after a restart.
   if(g_cycle.Anchored())
      g_cycle.NextCycle(g_strategy.grid_cycle_pause_seconds);
   else
     {
      if(g_cycle.Number() == 0)
         g_cycle.Begin();
      g_cycle.RestartPause(g_strategy.grid_cycle_pause_seconds);
     }
   g_cycle.Set(CYCLE_COOLDOWN, StringFormat("confirmed flat; pausing %d s", g_strategy.grid_cycle_pause_seconds));
  }

void ReportIfStuck(const string what)
  {
   if(g_cycle.MsInState() < CYCLE_STUCK_REPORT_MS || NowMs() - g_cycle_stuck_reported < CYCLE_STUCK_REPORT_MS)
      return;
   PrintFormat("GoldGrid: cycle %d has been %s for %d min — %s, so nothing new is placed. "
               "Check the account in MetaTrader.", g_cycle.Number(), g_cycle.Name(),
               (int)(g_cycle.MsInState() / 60000), what);
   g_cycle_stuck_reported = NowMs();
  }

//+------------------------------------------------------------------+
//| COOLDOWN. The pause is wall-clock and persisted, so a restart does |
//| not shorten it (and a quiet market does not stretch it).          |
//+------------------------------------------------------------------+
void CooldownCycle()
  {
   //--- Nothing of ours may rest between cycles: an order that appears now
   //--- (a leftover, a duplicate request that landed late, a stray with our
   //--- magic) would be an entry nobody decided on, and it would fill while
   //--- the next ladder is being measured.
   if(InpAllowTrading && g_grid.OurOrders() > 0 && NowMs() - g_cycle_close_attempt >= CLOSE_RETRY_PACE_MS)
     {
      g_cycle_close_attempt = NowMs();
      int withdrawn = g_grid.DeleteAllOrders(true);
      if(withdrawn > 0)
         PrintFormat("GoldGrid: withdrawing %d order(s) of ours that appeared during the pause", withdrawn);
     }

   if(g_cycle.PauseRemaining(g_strategy.grid_cycle_pause_seconds) > 0)
      return;
   //--- The withdrawals above are sent asynchronously: not left until they
   //--- have gone, or the new ladder would be measured against them.
   if(InpAllowTrading && g_grid.OurOrders() > 0)
      return;
   //--- The pause is over, but a new cycle is a new set of entries, and a
   //--- halt or a stopped strategy forbids those. Waiting here rather than in
   //--- PLACING keeps the ladder from being anchored and refused every pass.
   string halt = RiskHaltReason();
   if(halt != "")
     {
      NoteGridGate(StringFormat("pause over, but a risk halt is in force — %s", halt));
      return;
     }
   if(!g_strategy.IsRunning())
     {
      NoteGridGate("pause over, but the strategy is stopped — no new cycle");
      return;
     }
   g_cycle.EndPause();
   if(g_cycle.Number() == 0)
      g_cycle.Begin();                            // never place as cycle 0
   ResetLadderMemory();
   g_cycle.Set(CYCLE_PLACING, StringFormat("pause over — cycle %d", g_cycle.Number()));
  }

//+------------------------------------------------------------------+
//| RECOVERY. Something of ours is on the broker and belongs to no    |
//| cycle. Nothing is placed. Orders of ours are withdrawn (an order  |
//| without a cycle is an entry nobody decided on); positions are     |
//| left to the monitor, which closes the basket at its target like   |
//| any other. Once nothing of ours remains, the loop resumes with a  |
//| new cycle after the pause.                                        |
//+------------------------------------------------------------------+
void RecoverCycle()
  {
   if(InpAllowTrading && g_grid.OurOrders() > 0 && NowMs() - g_cycle_close_attempt >= CLOSE_RETRY_PACE_MS)
     {
      g_cycle_close_attempt = NowMs();
      int cancelled = g_grid.DeleteAllOrders(true);
      if(cancelled > 0)
         PrintFormat("GoldGrid: RECOVERY — withdrawing %d order(s) that belong to no cycle", cancelled);
     }

   if(g_grid.OurOrders() == 0 && g_grid.TotalPositions() == 0)
     {
      if(g_cycle.Number() == 0)
        {
         g_cycle.Begin();
         g_cycle.RestartPause(g_strategy.grid_cycle_pause_seconds);
        }
      else
         g_cycle.NextCycle(g_strategy.grid_cycle_pause_seconds);
      g_cycle.Set(CYCLE_COOLDOWN, StringFormat("recovered — nothing of ours left; cycle %d after the pause",
                                               g_cycle.Number()));
      return;
     }

   ReportIfStuck(StringFormat("%d position(s) of ours belong to no cycle and the basket is below its target",
                              g_grid.TotalPositions()));
  }

//--- The per-run bookkeeping a new or adopted cycle starts with.
void ResetLadderMemory()
  {
   g_ladder_seen_picture = -1;
   g_ladder_checked_ms   = 0;
   g_ladder_skipped      = 0;
   g_ladder_empty_since  = 0;
   g_ladder_gate_note    = "";
  }

//--- Orders and positions in one number, so a fill (one fewer order, one
//--- more position) reads as a change and not as the same total.
int LadderPicture()
  {
   return g_grid.OurOrders() * 100000 + g_grid.TotalPositions();
  }

//--- Close-only mode: risk halts and the basket's exits act, and a close in
//--- progress continues; nothing is placed and no new cycle starts.
void ManageGridCloseOnly()
  {
   if(EnforceRiskHalts())
      return;
   if(!g_cycle.Is(CYCLE_CLOSING) && !g_cycle.Is(CYCLE_INITIALIZING))
     {
      SBasket basket = g_grid.CombinedBasket();
      string  why    = g_grid.BasketExitReason(g_strategy, basket);
      if(why != "" && InpAllowTrading)
         BeginCycleClose(why, basket);
     }
   if(g_cycle.Is(CYCLE_CLOSING))
      CloseCycle();
  }

//--- Prints why the ladder is not being placed, once per change of reason.
//--- The note is also the report's execution reason while it applies — only
//--- in the cycle state and cycle it was set in (GateNoteApplies), so a note
//--- from an earlier state never describes a later one.
void NoteGridGate(const string reason, const bool entry_gate = false)
  {
   g_ladder_gate_state = g_cycle.State();
   g_ladder_gate_cycle = g_cycle.Number();
   g_ladder_gate_entry = entry_gate;
   if(reason == g_ladder_gate_note)
      return;
   PrintFormat("GoldGrid: ladder not placed — %s", reason);
   g_ladder_gate_note = reason;
  }

bool GateNoteApplies()
  {
   return g_ladder_gate_note != "" && g_ladder_gate_state == g_cycle.State() &&
          g_ladder_gate_cycle == g_cycle.Number();
  }

//--- A close or cancel of the basket close that the broker refused. A close
//--- refused outright (a requote, off quotes, a price that moved) leaves a
//--- position open while the price moves, so the next close pass is brought
//--- forward to 500 ms from now instead of the usual 2 s. "Position already
//--- closed" is not a failure: a retry pass can reach a position whose first
//--- close was still executing.
//---
//--- Only a PRICE rejection (requote, price changed, off quotes) earns the
//--- early retry, at most CLOSE_FAST_RETRIES_MAX times per close: those
//--- clear on the next quote. Anything else (no money, dealer reject, too
//--- many requests, market closed) keeps the 2 s pace, so a broker that keeps
//--- refusing is not hammered — "too many requests" in particular would only
//--- feed itself. The log line is throttled: the first of each kind at once,
//--- then at most one every 5 s with a count of those not printed.
void NoteCloseRejection(const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   uint code = result.retcode;
   if(code == TRADE_RETCODE_DONE || code == TRADE_RETCODE_DONE_PARTIAL || code == TRADE_RETCODE_PLACED ||
      code == TRADE_RETCODE_POSITION_CLOSED)
      return;

   bool  cancel = request.action == TRADE_ACTION_REMOVE;
   ulong now    = NowMs();
   if(code != g_close_reject_code || now - g_close_reject_ms >= 5000)
     {
      PrintFormat("GoldGrid: %s #%I64u REJECTED by the broker, retcode %u%s%s",
                  cancel ? "cancel of order" : "close of position", cancel ? request.order : request.position, code,
                  result.comment == "" ? "" : " (" + result.comment + ")",
                  g_close_reject_quiet > 0 ? StringFormat("; %d more rejection(s) since the last line", g_close_reject_quiet) : "");
      g_close_reject_code  = code;
      g_close_reject_ms    = now;
      g_close_reject_quiet = 0;
     }
   else
      g_close_reject_quiet++;

   if(cancel)
      return;
   bool price_moved = code == TRADE_RETCODE_REQUOTE || code == TRADE_RETCODE_PRICE_CHANGED ||
                      code == TRADE_RETCODE_PRICE_OFF;
   if(!price_moved || g_close_fast_retries >= CLOSE_FAST_RETRIES_MAX)
      return;
   ulong pull = CLOSE_RETRY_PACE_MS - CLOSE_RETRY_AFTER_REJECTION_MS;
   if(now > pull && now - g_cycle_close_attempt < pull)
     {
      g_cycle_close_attempt = now - pull;
      g_close_fast_retries++;
     }
  }

//+------------------------------------------------------------------+
//| THE REVERSAL STRATEGY.                                            |
//|                                                                   |
//|   flat        buy stop above, sell stop below, the entry distance |
//|               from the market; the first to fill cancels the other|
//|   buy active  no stop loss; a sell stop trails the trailing       |
//|               distance below the bid, moving up only              |
//|   price turns the sell stop fills; StepState closes the buy       |
//|   sell active mirror image, with a buy stop trailing above        |
//+------------------------------------------------------------------+
void ManageReversal()
  {
   SBasket buys  = g_grid.Basket(POSITION_TYPE_BUY);
   SBasket sells = g_grid.Basket(POSITION_TYPE_SELL);

   //--- Basket exits still apply to the single position.
   if(ExitBasketIfDue(POSITION_TYPE_BUY, buys) || ExitBasketIfDue(POSITION_TYPE_SELL, sells))
      return;

   //--- StepState is closing the old side of a reversal.
   if(g_state.Is(STATE_REVERSING))
      return;

   int held = buys.count + sells.count;

   //--- Just closed at the exit: the opposite stop may be filling this very
   //--- moment. Nothing is touched until it has had time to arrive; after
   //--- that, whatever still rests is withdrawn.
   if(held > 0)
      exit_settling_since = 0;
   else if(exit_settling_since > 0)
     {
      if(NowMs() - exit_settling_since < EXIT_SETTLE_MS)
         return;
      exit_settling_since = 0;
      if(InpAllowTrading)
         g_grid.DeleteAllPendingStops();
     }

   //--- Before the break: flat, nothing resting. After the reopen: no bracket
   //--- until the spread has had time to settle.
   bool   closing = false;
   string guard   = MarketGuardReason(closing);
   if(guard != "" && closing && held == 1 && g_state.IsActive() && InpAllowTrading)
     {
      PrintFormat("GoldGrid: closing the position — %s", guard);
      BeginClose(g_state.Ticket(), guard);
      return;
     }
   if(guard != "" && held == 0)
     {
      NoteGate(POSITION_TYPE_BUY, guard);
      if(InpAllowTrading)
         g_grid.DeleteAllPendingStops();
      return;
     }

   if(held > 0)
     {
      //--- The opposite stop is the position's only exit, so it keeps
      //--- trailing whether or not the strategy is still running. Whether its
      //--- fill becomes a new position is decided when it fills.
      if(held == 1 && g_state.IsActive() && InpAllowTrading)
         KeepOppositeStop(g_state.Is(STATE_BUY_ACTIVE) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL, g_state.Ticket());
      return;
     }

   //--- Flat: bracket the market. An order already resting on a side stays
   //--- where it is and only a missing side is added.
   bool   may_trade = !halted && InpAllowTrading;
   double lot       = EntryLot(g_strategy, _Symbol);
   string reason;
   if(!may_trade ||
      !g_grid.MayOpen(g_strategy, ConfigurationIsFresh(), lot, POSITION_TYPE_BUY, reason, true))
     {
      NoteGate(POSITION_TYPE_BUY, may_trade ? reason : (halted ? halt_reason : "AllowTrading is off"));
      g_grid.DeleteAllPendingStops();
      return;
     }

   //--- Strays and duplicates go at once, cooldown or not: they are never a
   //--- side that is about to fill for us, only a second chance to fill twice.
   g_grid.DeleteStrayOrders();

   //--- A bracket resting through a real spread spike fills at the spike's
   //--- price, so it is withdrawn above twice the limit. Above the limit
   //--- itself, nothing new is placed but a resting side stays.
   string spike = SpreadTooWideReason(true);
   if(spike != "")
     {
      NoteGate(POSITION_TYPE_BUY, spike);
      g_grid.DeleteAllPendingStops();
      return;
     }
   string spread = SpreadTooWideReason();
   if(spread != "")
     {
      NoteGate(POSITION_TYPE_BUY, spread);
      return;
     }

   //--- Reconciled against the broker immediately before any order goes out.
   //--- While a fill settles, or during the cooldown after a close, nothing is
   //--- added — and nothing else is removed, since a resting side may be the
   //--- one that is filling right now.
   string why;
   if(!EntryAllowed(why))
     {
      if(why != "")
         NoteGate(POSITION_TYPE_BUY, why);
      return;
     }
   last_gate_note = "";

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   PlaceBracket(lot, bid, ask);
  }

//+------------------------------------------------------------------+
//| THE INITIAL BRACKET. While flat, exactly one Buy Stop rests the   |
//| entry distance above the ask and one Sell Stop the same distance  |
//| below the bid. The first to fill becomes the only position and    |
//| OnTradeTransaction cancels the other.                             |
//|                                                                   |
//| The comment records the strategy and the distance the bracket was |
//| placed for ("GG:<id>:L1:D<points>"). A resting order whose comment |
//| names a different strategy or distance, whose volume is not the   |
//| current lot size, or that carries a stop loss (placed by an       |
//| earlier build), is stale — the setting was changed, or it is a    |
//| previous session's or position's — and both sides are             |
//| withdrawn and re-placed around the current price. An order whose  |
//| comment carries no GG marker at all (some brokers rewrite them) is |
//| left alone: re-placing on a comment we cannot read would re-place |
//| it on every pass.                                                 |
//+------------------------------------------------------------------+
bool BracketOrderIsStale(const ENUM_POSITION_TYPE side, const string expected, const double lot)
  {
   //--- A volume cannot be modified on a resting order, and the lot size may
   //--- have been changed on the platform since this one was placed.
   double volume = g_grid.PendingStopVolume(side);
   if(volume > 0.0 && MathAbs(volume - lot) > 0.000001)
      return true;
   //--- Every bracket order carries the stop loss its position opens with.
   //--- One placed by an earlier build does not.
   if(volume > 0.0 && !g_grid.PendingStopHasStopLoss(side))
      return true;

   string comment = g_grid.PendingStopComment(side);
   if(comment == "" || comment == expected || StringFind(comment, "GG:") != 0)
      return false;

   //--- The pre-Phase-4 bracket ("GG:<id>:L1") was always placed at the
   //--- trailing distance. It is still correct while the two coincide.
   if(comment == StringFormat("GG:%I64d:L1", g_strategy.id) &&
      g_strategy.entry_distance_points == g_strategy.trailing_stop_points)
      return false;

   return true;
  }

void PlaceBracket(const double lot, const double bid, const double ask)
  {
   int    configured = g_strategy.entry_distance_points;
   string comment    = StringFormat("GG:%I64d:L1:D%d", g_strategy.id, configured);

   //--- 1. Nothing but one Buy Stop and one Sell Stop may rest.
   g_grid.DeleteStrayOrders();

   //--- 2. A bracket placed for another strategy or distance is withdrawn
   //---    whole, so the two sides are always centred on the same price.
   if(BracketOrderIsStale(POSITION_TYPE_BUY, comment, lot) || BracketOrderIsStale(POSITION_TYPE_SELL, comment, lot))
     {
      int removed = g_grid.DeleteAllPendingStops();
      PrintFormat("GoldGrid: withdrew %d stale bracket order(s) — re-placing at %d points, %.2f lots",
                  removed, configured, lot);
      return;
     }

   //--- 3. The broker refuses a stop order closer to the market than its stop
   //---    level. The configured distance is widened to the nearest accepted
   //---    one, and the user told, rather than rejected on every pass.
   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int points      = configured;
   if(points <= stops_level)
     {
      points = stops_level + 1;
      static int warned_for = -1;
      if(warned_for != configured)
         PrintFormat("GoldGrid: entry distance of %d points is inside the broker's minimum of %d — "
                     "bracketing at %d points instead.", configured, stops_level, points);
      warned_for = configured;
     }
   double distance = points * _Point;

   //--- 4. Only a missing side is added. A resting side is never moved while
   //---    flat: it may be the one filling at this very moment.
   //---    Each carries the stop loss its position opens with, so the position
   //---    is protected by the broker from the instant it fills.
   double exit = g_grid.ExitDistance(g_strategy);
   if(g_grid.FindPendingStop(POSITION_TYPE_BUY) == 0)
      g_grid.PlacePendingStop(POSITION_TYPE_BUY, lot, ask + distance, comment,
                              g_grid.EntryStopLoss(POSITION_TYPE_BUY, ask + distance, exit));
   if(g_grid.FindPendingStop(POSITION_TYPE_SELL) == 0)
      g_grid.PlacePendingStop(POSITION_TYPE_SELL, lot, bid - distance, comment,
                              g_grid.EntryStopLoss(POSITION_TYPE_SELL, bid - distance, exit));
  }

//--- Prints why nothing is being opened, once per change of reason.
void NoteGate(const ENUM_POSITION_TYPE type, const string reason)
  {
   string note = StringFormat("%s:%s", type == POSITION_TYPE_BUY ? "buy" : "sell", reason);
   if(note == last_gate_note)
      return;
   PrintFormat("GoldGrid: not opening %s — %s", type == POSITION_TYPE_BUY ? "buy" : "sell", reason);
   last_gate_note = note;
  }

//+------------------------------------------------------------------+
//| Records that money actually moved.                                |
//|                                                                   |
//| Every refusal to trade was already logged with its reason, but an |
//| order that succeeded said nothing at all — so the log described   |
//| only the times the EA did nothing, and was silent on the one      |
//| event a user most needs to be able to reconstruct afterwards.     |
//+------------------------------------------------------------------+
void LogOpen(const ENUM_POSITION_TYPE type, const int level, const double lot)
  {
   PrintFormat("GoldGrid: opened %s level %d, %.2f lots at %.5f (basket now %d positions)",
               type == POSITION_TYPE_BUY ? "BUY" : "SELL", level, lot,
               type == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                         : SymbolInfoDouble(_Symbol, SYMBOL_BID),
               g_grid.Basket(type).count);
  }

//+------------------------------------------------------------------+
//| Reporting. A full snapshot every interval, which is what makes    |
//| ingestion idempotent on the platform side.                        |
//+------------------------------------------------------------------+
void SendReport()
  {
   last_report_at = NowMs();

   string body = BuildReportJson();
   string response;
   ENUM_API_RESULT result = g_api.PostReport(body, response);

   //--- The reply names the strategy's current configuration version. When it
   //--- is not the one held, the configuration changed on the platform — a
   //--- stop, an emergency stop, an edit — and is fetched now rather than at
   //--- the next scheduled refresh.
   if(result == API_OK)
     {
      CJsonParser parser;
      CJsonNode *reply = parser.Parse(response);
      if(CheckPointer(reply) == POINTER_DYNAMIC)
        {
         CJsonNode *version = reply.Get("config_version");
         string current = (CheckPointer(version) != POINTER_INVALID && !version.IsNull())
                          ? version.AsString("") : "";
         delete reply;

         if(current != "" && g_strategy.loaded && current != g_strategy.config_version)
           {
            Print("GoldGrid: configuration changed on the platform — refreshing now");
            RefreshConfiguration();
           }
        }
     }

   if(result == API_UNAUTHORIZED)
     {
      //--- Once only, for the same reason as above.
      if(!halted)
         Alert("GoldGrid: ", g_api.LastError());
      halted = true;
      halt_reason = g_api.LastError();
     }
   else if(result != API_OK)
     {
      PrintFormat("GoldGrid: report failed — %s", g_api.LastError());
     }
  }

//+------------------------------------------------------------------+
string IsoTime(const datetime server_time)
  {
   //--- Timestamps from the terminal (POSITION_TIME, TimeCurrent) are in BROKER
   //--- SERVER time, which is usually not UTC. The platform expects UTC, so the
   //--- server/GMT offset is removed before formatting. Reporting server time
   //--- with a "Z" suffix would put every position hours out.
   int offset = (int)(TimeCurrent() - TimeGMT());
   datetime utc = server_time - offset;

   MqlDateTime parts;
   TimeToStruct(utc, parts);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
                       parts.year, parts.mon, parts.day, parts.hour, parts.min, parts.sec);
  }

//+------------------------------------------------------------------+
string BuildReportJson()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   string json = "{";
   json += "\"strategy_id\":" + IntegerToString(InpStrategyId) + ",";

   json += "\"terminal\":{";
   json += "\"ea_version\":\"" + JsonEscape(ea_version) + "\",";
   json += "\"broker\":\"" + JsonEscape(AccountInfoString(ACCOUNT_COMPANY)) + "\",";
   json += "\"account_login\":\"" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "\",";
   json += "\"symbol\":\"" + JsonEscape(_Symbol) + "\"},";

   json += "\"tick\":{";
   json += "\"bid\":\"" + DoubleToString(bid, digits) + "\",";
   json += "\"ask\":\"" + DoubleToString(ask, digits) + "\",";
   json += "\"spread_points\":" + IntegerToString(spread) + "},";

   //--- What the EA is doing, for the dashboard. Trailing and reversal report
   //--- their state machine (State.mqh); the grid reports its cycle
   //--- (Cycle.mqh) with the figures the Robot state card shows: the cycle
   //--- number, rungs resting and filled, the basket's floating P/L against
   //--- its target, and the seconds of pause left in COOLDOWN. The reversal
   //--- level is the price of the open position's opposite stop, "0" when
   //--- there is none. Figures a category does not have are sent as null.
   string state_name   = g_cycle.Name();
   //--- The cycle's reason names the last transition. While something keeps
   //--- the ladder from being placed (the strategy stopped, trading off, a
   //--- halt), that gate is what the user needs to read next to the state.
   string state_reason = GateNoteApplies() ? g_ladder_gate_note : g_cycle.Reason();
   double level        = 0.0;
   string cycle_json   = "null", resting_json = "null", filled_json = "null",
          basket_json  = "null", pause_json   = "null";
   if(SinglePositionMode())
     {
      state_name   = g_state.Name();
      state_reason = g_state.Reason();
      if(g_strategy.category == CATEGORY_REVERSAL && g_state.IsActive())
         level = g_grid.PendingStopPrice(g_state.Is(STATE_BUY_ACTIVE) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);
     }
   else if(g_strategy.loaded)
     {
      SBasket basket = g_grid.CombinedBasket();
      cycle_json   = IntegerToString(g_cycle.Number());
      resting_json = IntegerToString(g_grid.OurOrders());
      filled_json  = IntegerToString(g_grid.RungPositions(g_cycle.Number()));
      basket_json  = "\"" + DoubleToString(basket.profit, 2) + "\"";
      pause_json   = IntegerToString(g_cycle.Is(CYCLE_COOLDOWN)
                                     ? g_cycle.PauseRemaining(g_strategy.grid_cycle_pause_seconds) : 0);
     }
   json += "\"execution\":{";
   json += "\"state\":\"" + JsonEscape(state_name) + "\",";
   json += "\"reason\":\"" + JsonEscape(state_reason) + "\",";
   json += "\"reversal_level\":\"" + DoubleToString(level, digits) + "\",";
   json += "\"daily_profit\":\"" + DoubleToString(g_grid.TodayProfit(), 2) + "\",";
   json += "\"risk_halt\":\"" + JsonEscape(RiskHaltReason()) + "\",";
   json += "\"cycle\":" + cycle_json + ",";
   json += "\"resting_orders\":" + resting_json + ",";
   json += "\"filled_orders\":" + filled_json + ",";
   json += "\"basket_profit\":" + basket_json + ",";
   json += "\"pause_seconds_left\":" + pause_json + "},";

   //--- All money values are sent as strings so the platform can parse them as
   //--- decimals. Sending them as JSON numbers would invite float rounding.
   json += "\"account\":{";
   json += "\"currency\":\"" + JsonEscape(AccountInfoString(ACCOUNT_CURRENCY)) + "\",";
   json += "\"balance\":\"" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\",";
   json += "\"equity\":\"" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\",";
   json += "\"margin\":\"" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2) + "\",";
   json += "\"free_margin\":\"" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + "\",";
   json += "\"margin_level_percent\":\"" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), 2) + "\"},";

   //--- Positions. Always sent, even when empty: an empty array tells the
   //--- platform everything is closed, which is exactly what we mean here.
   json += "\"positions\":[";
   int written = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(written > 0)
         json += ",";
      written++;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      json += "{";
      json += "\"ticket\":\"" + IntegerToString((long)ticket) + "\",";
      json += "\"direction\":\"" + string(type == POSITION_TYPE_BUY ? "buy" : "sell") + "\",";
      json += "\"grid_level\":" + IntegerToString(LevelFromComment(PositionGetString(POSITION_COMMENT))) + ",";
      json += "\"volume\":\"" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + "\",";
      json += "\"open_price\":\"" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), digits) + "\",";
      json += "\"current_price\":\"" + DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), digits) + "\",";
      //--- The live stop level, which for a trailing strategy is the number the
      //--- user is actually watching. Zero means no stop attached (always, for
      //--- a reversal); the platform reads that as "none" rather than a price.
      json += "\"stop_loss\":\"" + DoubleToString(PositionGetDouble(POSITION_SL), digits) + "\",";
      json += "\"profit\":\"" + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + "\",";
      json += "\"swap\":\"" + DoubleToString(PositionGetDouble(POSITION_SWAP), 2) + "\",";
      json += "\"commission\":\"" + DoubleToString(CGridEngine::PositionCommission(PositionGetInteger(POSITION_IDENTIFIER)), 2) + "\",";
      json += "\"opened_at\":\"" + IsoTime((datetime)PositionGetInteger(POSITION_TIME)) + "\"";
      json += "}";
     }
   json += "],";

   //--- Recently closed positions, from the broker's deal history. The open
   //--- list above carries floating figures that go stale the moment a stop
   //--- fires: a position that vanished between reports would otherwise be
   //--- recorded by the platform at the last price it happened to report,
   //--- not the price the broker actually closed it at. Re-reported for a
   //--- whole window rather than once, deliberately — the report protocol is
   //--- idempotent snapshots, and a close the platform recorded from stale
   //--- data gets corrected the next time it hears from us.
   json += "\"closed_positions\":[";
   int closed_written = 0;
   if(HistorySelect(TimeCurrent() - CLOSED_REPORT_WINDOW_SECONDS, TimeCurrent() + 3600))
     {
      long reported_ids[];
      int  deals = HistoryDealsTotal();

      for(int i = 0; i < deals; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0)
            continue;
         if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
            continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
            continue;

         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
            continue;

         //--- One entry per position, however many deals closed it.
         long position_id = (long)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
         bool already = false;
         for(int k = 0; k < ArraySize(reported_ids); k++)
            if(reported_ids[k] == position_id)
              { already = true; break; }
         if(already)
            continue;
         int n = ArraySize(reported_ids);
         ArrayResize(reported_ids, n + 1);
         reported_ids[n] = position_id;

         //--- The realised numbers are summed across every deal of the
         //--- position that falls inside the window: a partial close is two
         //--- OUT deals, and swap and commission can sit on either side.
         double   profit = 0.0, swap = 0.0, commission = 0.0, close_price = 0.0;
         datetime closed_at = 0;

         for(int j = 0; j < deals; j++)
           {
            ulong d = HistoryDealGetTicket(j);
            if(d == 0)
               continue;
            if((long)HistoryDealGetInteger(d, DEAL_POSITION_ID) != position_id)
               continue;

            swap       += HistoryDealGetDouble(d, DEAL_SWAP);
            commission += HistoryDealGetDouble(d, DEAL_COMMISSION);

            ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
            if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY)
               continue;

            profit += HistoryDealGetDouble(d, DEAL_PROFIT);
            datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
            if(t >= closed_at)
              {
               closed_at   = t;
               close_price = HistoryDealGetDouble(d, DEAL_PRICE);
              }
           }

         if(closed_written > 0)
            json += ",";
         closed_written++;

         //--- The position id is what the platform knows the position by: it
         //--- is the same number PositionGetTicket reported while it was open.
         json += "{";
         json += "\"ticket\":\"" + IntegerToString(position_id) + "\",";
         json += "\"close_price\":\"" + DoubleToString(close_price, digits) + "\",";
         json += "\"profit\":\"" + DoubleToString(profit, 2) + "\",";
         json += "\"swap\":\"" + DoubleToString(swap, 2) + "\",";
         json += "\"commission\":\"" + DoubleToString(commission, 2) + "\",";
         json += "\"closed_at\":\"" + IsoTime(closed_at) + "\"";
         json += "}";
        }
     }
   json += "],";

   //--- Resting orders: a reversal's bracket or trailing stop, a grid's
   //--- ladder. The list is always sent, so the platform clears whatever is
   //--- no longer there. The grid level is the ladder rung (0 for anything
   //--- that is not one).
   json += "\"orders\":[";
   int orders_written = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      string order_type;
      switch((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE))
        {
         case ORDER_TYPE_BUY_STOP:   order_type = "buy_stop";   break;
         case ORDER_TYPE_SELL_STOP:  order_type = "sell_stop";  break;
         case ORDER_TYPE_BUY_LIMIT:  order_type = "buy_limit";  break;
         case ORDER_TYPE_SELL_LIMIT: order_type = "sell_limit"; break;
         default: continue;
        }

      if(orders_written > 0)
         json += ",";
      orders_written++;

      json += "{";
      json += "\"ticket\":\"" + IntegerToString((long)ticket) + "\",";
      json += "\"order_type\":\"" + order_type + "\",";
      json += "\"grid_level\":" + IntegerToString(LevelFromComment(OrderGetString(ORDER_COMMENT))) + ",";
      json += "\"volume\":\"" + DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), 2) + "\",";
      json += "\"price\":\"" + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), digits) + "\",";
      json += "\"placed_at\":\"" + IsoTime((datetime)OrderGetInteger(ORDER_TIME_SETUP)) + "\"";
      json += "}";
     }
   json += "]";

   json += "}";
   return json;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Exits are checked on ticks as well as on the timer so a basket target
   //--- is not missed during a fast move between timer events.
   if(g_strategy.loaded)
      ManageBaskets();

   if(IsTester())
      TesterTick();
  }

//+------------------------------------------------------------------+
//| STRATEGY TESTER HARNESS (Include/GoldGrid/Tester.mqh).            |
//+------------------------------------------------------------------+
int InitTester()
  {
   g_grid.Configure(InpMagicNumber, _Symbol, InpSlippagePoints);
   g_grid.LoadPeakEquity();
   g_state.Configure(InpMagicNumber, _Symbol);
   g_state.Load();
   g_started_ms = NowMs();
   g_cycle.Configure(InpMagicNumber, _Symbol);
   g_cycle.Load();
   last_quote_at = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);

   BuildTesterStrategy(g_strategy, InpTestCategory, InpTestLot, InpTestTrailingPoints, InpTestStepPoints,
                       InpTestEntryPoints, InpTestMaxSpreadPoints, InpTestMaxDailyLoss,
                       InpTestGridSpacingPoints, InpTestGridBuyOrders, InpTestGridSellOrders,
                       InpTestGridTargetMoney, InpTestGridPauseSeconds);
   g_monitor.Configure(InpMagicNumber, _Symbol, g_strategy.category == CATEGORY_REVERSAL);
   g_chaos.Configure(InpMagicNumber, _Symbol, InpChaosEveryMinutes, InpChaosSeed, InpChaosRestartOnly);
   g_grid.SetOrderLimit(InpTestOrderLimit);

   if(!InpAllowTrading)
      Print("GoldGrid: AllowTrading is OFF — the tester run will place no orders.");
   PrintFormat("GoldGrid: TESTER — category %s, lot %.2f, trailing %d, step %d, entry %d, cooldown %d s, "
               "chaos every %d min (seed %d)",
               InpTestCategory == TEST_GRID ? "grid" : InpTestCategory == TEST_TRAILING ? "trailing" : "reversal",
               InpTestLot, InpTestTrailingPoints, g_strategy.trailing_step_points,
               g_strategy.entry_distance_points, InpReentryCooldownSeconds, InpChaosEveryMinutes, InpChaosSeed);

   EventSetTimer(1);
   return INIT_SUCCEEDED;
  }

//--- Everything the EA holds in memory is lost on a real restart; only what
//--- State.mqh persisted survives. This throws away exactly that and loads
//--- the persisted state, as OnInit would.
void SimulateRestart()
  {
   entry_lock_until      = 0;
   recovery_clean_since  = 0;
   last_recovery_attempt = 0;
   reversing_close_at    = 0;
   reversing_flat        = false;
   exit_settling_since   = 0;
   risk_halt_noted       = "";
   last_gate_note        = "";
   g_ladder_seen_picture = -1;
   g_ladder_last_send_ms = 0;
   g_ladder_checked_ms   = 0;
   g_ladder_skipped      = 0;
   g_ladder_empty_since  = 0;
   g_ladder_gate_note    = "";
   g_cycle_close_reason  = "";
   g_grid.ForgetRunState();
   g_cycle_close_attempt = 0;
   g_cycle_stuck_reported = 0;
   g_cycle_close_cancelled = 0;
   ENUM_EXEC_STATE previous = g_state.Load();
   ENUM_CYCLE_STATE previous_cycle = g_cycle.Load();
   if(g_strategy.category == CATEGORY_GRID)
      PrintFormat("GoldGrid: CHAOS restart — cycle %d was %s, now %s", g_cycle.Number(),
                  CycleStateName(previous_cycle), g_cycle.Name());
   else
      PrintFormat("GoldGrid: CHAOS restart — previous state %s, now %s", ExecStateName(previous), g_state.Name());
  }

void TesterTick()
  {
   static int   reversal_entries_at_close = -1;

   //--- The grid. The chaos engine's trade-side events (a manual close, an
   //--- extra position with our magic, a stray order) are carried out by
   //--- Due() itself and land on the ladder like anything a user might do by
   //--- hand; a restart and a tick storm are performed here. The
   //--- single-position invariants below do not apply to it — CheckGrid
   //--- holds the ladder's own.
   if(g_strategy.category == CATEGORY_GRID)
     {
      ENUM_CHAOS_EVENT event = g_chaos.Due(g_monitor, g_strategy.grid_spacing_points);
      if(event == CHAOS_RESTART)
         SimulateRestart();
      else if(event == CHAOS_TICK_STORM)
         for(int i = 0; i < 25; i++)
            ManageBaskets();
      g_monitor.CheckGrid(g_cycle.Number(), g_cycle.Name(), g_cycle.Is(CYCLE_PLACING) || g_cycle.Is(CYCLE_ARMED),
                          g_strategy.max_positions, g_strategy.grid_cycle_pause_seconds, g_strategy.id,
                          g_cycle.PauseUntil());
      return;
     }

   if(SinglePositionMode())
     {
      ENUM_CHAOS_EVENT event = g_chaos.Due(g_monitor, g_strategy.trailing_stop_points);
      if(event == CHAOS_RESTART)
         SimulateRestart();
      else if(event == CHAOS_TICK_STORM)
         for(int i = 0; i < 25; i++)
            ManageBaskets();
      else if(event == CHAOS_MANUAL_CLOSE)
         reversal_entries_at_close = g_state.Entries(STATE_REVERSING);

      //--- A manual close is not the opposite stop filling: it must never reverse.
      if(reversal_entries_at_close >= 0)
        {
         if(g_state.Entries(STATE_REVERSING) > reversal_entries_at_close)
            g_monitor.Fail("a manual close was treated as a reversal");
         if(NowMs() - g_chaos.manual_close_at > 30000)
            reversal_entries_at_close = -1;
        }

      g_monitor.Check(g_grid.TradingAllowed());
     }
  }

//--- The run's verdict, printed where bin/mt5_backtest looks for it. The
//--- return value is the optimisation criterion: fewer violations is better,
//--- so it is negated.
double OnTester()
  {
   int trades = 0;
   if(HistorySelect(0, TimeCurrent() + 1))
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal != 0 && HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
            trades++;
        }

   double closed_trades = TesterStatistics(STAT_TRADES);
   double win_rate      = closed_trades > 0 ? TesterStatistics(STAT_PROFIT_TRADES) / closed_trades * 100.0 : 0.0;
   double change_pct    = g_monitor.first_bid > 0 ? (g_monitor.last_bid - g_monitor.first_bid) / g_monitor.first_bid * 100.0 : 0.0;

   PrintFormat("GoldGrid: TEST SUMMARY | violations=%d | max_positions=%d | trades=%d | reversals=%d | "
               "reversals_flat=%d | max_overlap_ms=%I64u | recoveries=%d | closing=%d | breaches_seen=%d | breaches_repaired=%d | "
               "chaos=%d (manual_close=%d extra_position=%d duplicate_order=%d restart=%d tick_storm=%d) | "
               "net_profit=%.2f | profit_factor=%.2f | win_rate=%.1f | max_drawdown_pct=%.2f | "
               "market_start=%.2f | market_end=%.2f | market_change_pct=%.2f | market_range=%.2f | checks=%d | "
               "cycle=%d | cycle_state=%s | cycles_closed=%d | cycle_recoveries=%d | ladder_max_orders=%d | "
               "ladder_requests=%d | ladder_closed_profit=%.2f | resting_orders=%d | open_positions=%d",
               g_monitor.violations, g_monitor.max_positions, trades, g_state.Reversals(), g_state.ReversalsFlat(),
               g_monitor.max_overlap_ms,
               g_state.Entries(STATE_RECOVERY), g_state.Entries(STATE_CLOSING),
               g_monitor.breaches_seen, g_monitor.breaches_repaired,
               g_chaos.Total(), g_chaos.counts[CHAOS_MANUAL_CLOSE], g_chaos.counts[CHAOS_EXTRA_POSITION],
               g_chaos.counts[CHAOS_DUPLICATE_ORDER], g_chaos.counts[CHAOS_RESTART], g_chaos.counts[CHAOS_TICK_STORM],
               TesterStatistics(STAT_PROFIT), TesterStatistics(STAT_PROFIT_FACTOR), win_rate,
               TesterStatistics(STAT_EQUITYDD_PERCENT),
               g_monitor.first_bid, g_monitor.last_bid, change_pct, g_monitor.high_bid - g_monitor.low_bid,
               g_monitor.checks,
               g_cycle.Number(), g_cycle.Name(), g_cycle.CyclesClosed(), g_cycle.Entries(CYCLE_RECOVERY),
               g_ladder_max_orders, g_ladder_requests, g_ladder_closed_profit, g_grid.OurOrders(),
               g_grid.TotalPositions());
   return -(double)g_monitor.violations;
  }

//+------------------------------------------------------------------+
string DealReasonText(const ENUM_DEAL_REASON reason)
  {
   switch(reason)
     {
      case DEAL_REASON_SL:     return "stop loss";
      case DEAL_REASON_TP:     return "take profit";
      case DEAL_REASON_SO:     return "stop out (margin)";
      case DEAL_REASON_EXPERT: return "EA";
      case DEAL_REASON_CLIENT: return "manual (desktop)";
      case DEAL_REASON_MOBILE: return "manual (mobile)";
      case DEAL_REASON_WEB:    return "manual (web)";
     }
   return "other";
  }

//+------------------------------------------------------------------+
//| Broker-confirmed executions. Fills and closes are acted on the    |
//| moment the broker reports them, instead of up to a second later   |
//| on the next timer pass — the gap in which a spike could fill the  |
//| other side of the bracket too.                                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   //--- The grid's basket close sends its closes and cancels asynchronously,
   //--- so a rejection is not seen at the call: it arrives here. A cancel
   //--- request carries no symbol (CTrade::OrderDelete sets only the order
   //--- and the magic), so an empty symbol counts as ours.
   if(trans.type == TRADE_TRANSACTION_REQUEST)
     {
      bool close_or_cancel = (request.action == TRADE_ACTION_DEAL && request.position != 0 && request.symbol == _Symbol) ||
                             (request.action == TRADE_ACTION_REMOVE && (request.symbol == "" || request.symbol == _Symbol));
      if(request.magic == (ulong)InpMagicNumber && close_or_cancel &&
         g_strategy.category == CATEGORY_GRID && g_cycle.Is(CYCLE_CLOSING))
         NoteCloseRejection(request, result);
      return;
     }

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.symbol != _Symbol)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   ENUM_DEAL_ENTRY  entry  = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   ENUM_DEAL_TYPE   type   = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   int              digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string           side   = type == DEAL_TYPE_BUY ? "BUY" : "SELL";

   if(entry == DEAL_ENTRY_IN)
     {
      PrintFormat("GoldGrid: FILLED %s %.2f lots at %s (position #%I64d)",
                  side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
                  DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PRICE), digits),
                  HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID));

      //--- A rung filled: it joins the cycle's filled set (never placed
      //--- again this cycle, D6), and the basket changed, so its target is
      //--- checked now rather than on the next timer — a fast move can reach
      //--- it between two timer events.
      if(g_strategy.category == CATEGORY_GRID)
        {
         string comment = HistoryDealGetString(trans.deal, DEAL_COMMENT);
         if(IsTester())
            g_monitor.NoteGridFill(CycleFromComment(comment), type, comment,
                                   (ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER));
         g_grid.NoteFillDeal(g_strategy.id, trans.deal);
         //--- A rung that filled while the basket is being closed (its cancel
         //--- arrived too late) is closed at once, not on the next 2 s pass.
         if(g_cycle.Is(CYCLE_CLOSING) && InpAllowTrading)
           {
            g_grid.NoteOpenPositions();
            g_grid.ClosePosition((ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID), g_cycle_close_reason, true);
           }
         ManageBaskets();
         return;
        }

      if(!SinglePositionMode())
         return;

      //--- One-cancels-the-other: the moment one side of the bracket fills,
      //--- the other is withdrawn. (A reversal fill leaves nothing to cancel:
      //--- the order that filled was the only one.) Then a full pass at once,
      //--- not on the next timer: a reversal closes the old side, and the new
      //--- position gets its own opposite stop, without waiting.
      LockEntries(OPEN_COOLDOWN_SECONDS);
      int cancelled = g_grid.DeleteAllPendingStops();
      if(cancelled > 0)
         PrintFormat("GoldGrid: cancelled %d opposite pending order(s) after the fill", cancelled);

      ManageBaskets();
      return;
     }

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      //--- Logged before StepState(), which re-selects the deal history.
      //--- The deal type is the closing side, so a SELL deal closed a buy.
      PrintFormat("GoldGrid: CLOSED %s position #%I64d at %s by %s, P/L %.2f",
                  type == DEAL_TYPE_SELL ? "BUY" : "SELL",
                  HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID),
                  DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PRICE), digits),
                  DealReasonText(reason), HistoryDealGetDouble(trans.deal, DEAL_PROFIT));

      //--- A position of the basket closed: the close advances at once.
      if(g_strategy.category == CATEGORY_GRID)
        {
         ManageBaskets();
         return;
        }

      if(!SinglePositionMode())
         return;

      //--- Recorded here as well as in StepState, so every close counts —
      //--- including those confirmed through CLOSING or RECOVERY.
      g_state.RecordClosedSide(type == DEAL_TYPE_SELL ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
      g_state.RecordClose();
      ManageBaskets();

      if(g_state.Is(STATE_WAITING) && InpReentryCooldownSeconds > 0)
         PrintFormat("GoldGrid: no new entry for %d s after this close", InpReentryCooldownSeconds);
     }
  }
//+------------------------------------------------------------------+

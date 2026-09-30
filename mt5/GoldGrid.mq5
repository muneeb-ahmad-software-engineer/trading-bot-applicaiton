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
//|   * grid     — adds levels as price moves against the basket.     |
//|                With direction "both" the buy and sell baskets run |
//|                independently (hedging account required).          |
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
//|   * No new positions or baskets are opened.                       |
//|   * Existing baskets CONTINUE to be managed — basket take profit, |
//|     stop loss and trailing stops still apply. Abandoning an open  |
//|     basket with no exit would be more dangerous than continuing   |
//|     to manage it.                                                 |
//|   * Nothing is force-closed. Stopping is not "close everything".  |
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
input int    InpTestGridSpacingPoints         = 150;           // Grid spacing (grid only)
input int    InpTestGridLevels                = 5;             // Grid levels (grid only)
input int    InpChaosEveryMinutes             = 0;             // Chaos: inject a failure every N minutes (0 = off)
input int    InpChaosSeed                     = 1;             // Chaos: random seed

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
//--- The open position carries no stop loss. Its exit is a real stop order for
//--- the opposite side, held by the broker and trailed behind price by
//--- TrailOppositeStop (Include/GoldGrid/Grid.mqh). When price turns by the
//--- trailing distance that order fills, and for a moment both sides are open:
//---
//---   *_ACTIVE --opposite stop fills--> REVERSING
//---   REVERSING --old position closed by the EA--> the opposite *_ACTIVE
//---
//--- The EA closes the old position the moment it sees the fill, and the new
//--- one gets its own trailing opposite stop. With the terminal offline the
//--- two stay open together — hedged, so the loss stops growing — until the
//--- EA is back and closes the old one.
//---
//--- When reversing is not allowed at that moment (strategy stopped, risk
//--- halt, platform unreachable) both are closed instead, which leaves the
//--- account flat at the trailing level: the order still did its job as the
//--- position's exit.
ulong    reversing_close_at    = 0;     // last close request sent while REVERSING
bool     reversing_flat        = false; // close both sides instead of keeping the new one
int      REVERSE_RETRY_SECONDS = 2;

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
//| The opposite stop of the one open position: trailed behind price, |
//| alone (nothing rests on the side already held), and — once it is  |
//| in place — the position's leftover stop loss from an earlier      |
//| build removed.                                                    |
//+------------------------------------------------------------------+
void KeepOppositeStop(const ENUM_POSITION_TYPE held_side, const ulong ticket)
  {
   g_grid.DeletePendingStops(held_side);
   g_grid.DeleteStrayOrders();

   double lot = GridLotForLevel(g_strategy, 1, _Symbol);
   if(g_grid.TrailOppositeStop(g_strategy, held_side, lot, StringFormat("GG:%I64d:REV", g_strategy.id)))
      g_grid.RemoveStopLoss(ticket);
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
//--- not — in which case both sides are closed.
string ReversalBlockedReason()
  {
   if(halted)
      return halt_reason;
   if(!InpAllowTrading)
      return "AllowTrading is off";
   if(!g_strategy.IsRunning())
      return "the strategy is stopped";
   if(!ConfigurationIsFresh())
      return "the platform has not answered recently";
   string spread = SpreadTooWideReason(true);
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
            g_state.Set(active, "entry filled", ticket);
         break;

      case STATE_BUY_ACTIVE:
      case STATE_SELL_ACTIVE:
         if(held == 0)
           {
            //--- Closed by something other than a reversal: a take profit, a
            //--- manual close, a stop-out. That is not a signal to enter again
            //--- — the cooldown starts here — and the position's opposite stop
            //--- goes with it.
            g_state.RecordClosedSide(g_state.Is(STATE_BUY_ACTIVE) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
            g_state.RecordClose();
            if(g_strategy.category == CATEGORY_REVERSAL && InpAllowTrading)
               g_grid.DeleteAllPendingStops();
            g_state.Set(STATE_WAITING, StringFormat("#%I64u closed", g_state.Ticket()));
           }
         else if(ticket != g_state.Ticket() || !g_state.Is(active))
            g_state.Set(active, "the open position changed", ticket);
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
      if(!closed_noted)
         Print("GoldGrid: market closed for this symbol — sending nothing until it opens");
      closed_noted = true;
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

   //--- A single-position strategy's close is tracked through CLOSING until
   //--- the broker confirms it, so nothing can open in the meantime.
   int closed = 0;
   if(SinglePositionMode())
     {
      ENUM_POSITION_TYPE held_type;
      ulong ticket = g_grid.OurPosition(held_type);
      if(ticket != 0 && held_type == type && BeginClose(ticket, "basket exit"))
         closed = 1;
     }
   else
      closed = g_grid.CloseBasket(type);

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

   //--- A trailing strategy holds one position; a grid holds as many per
   //--- direction as it has levels.
   int next_level = basket.count + 1;
   if(next_level > g_strategy.LevelsPerDirection())
      return;

   double next_lot = GridLotForLevel(g_strategy, next_level, _Symbol);

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

   //--- The first position of a direction opens at market. For a trailing
   //--- strategy this is the only position it will open until that one closes.
   //---
   //--- This is also the re-entry: once a trailing stop takes a position out,
   //--- the direction is flat again and the next pass opens it afresh. That is
   //--- deliberate — a trailing strategy is meant to keep working the market,
   //--- not to stop after one trade. Each side re-enters on its own, so a buy
   //--- being stopped out does not disturb a sell that is still running.
   if(basket.count == 0)
     {
      //--- A trailing position opens with its stop already attached: it has
      //--- no other exit, so it is never left without one while it waits to
      //--- reach activation.
      int initial_stop = (g_strategy.category != CATEGORY_GRID) ? g_strategy.trailing_stop_points : 0;
      //--- Locked before the request, not after: whatever it returns, the
      //--- next pass must not read the account as flat while it settles.
      if(SinglePositionMode())
         LockEntries(OPEN_COOLDOWN_SECONDS);
      if(g_grid.OpenMarket(type, next_lot, StringFormat("GG:%I64d:L1", g_strategy.id), initial_stop))
        {
         last_open_at[DirectionSlot(type)] = NowMs();
         LogOpen(type, 1, next_lot);
        }
      return;
     }

   //--- Subsequent levels open only once price has travelled a full grid step
   //--- beyond the furthest existing entry.
   double step = g_strategy.grid_spacing_points * _Point;
   double trigger = (type == POSITION_TYPE_BUY)
                    ? basket.worst_price - step
                    : basket.worst_price + step;

   bool reached = (type == POSITION_TYPE_BUY) ? (ask <= trigger) : (bid >= trigger);
   if(!reached)
      return;

   if(g_grid.OpenMarket(type, next_lot, StringFormat("GG:%I64d:L%d", g_strategy.id, next_level)))
     {
      last_open_at[DirectionSlot(type)] = NowMs();
      LogOpen(type, next_level, next_lot);
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
   double lot       = GridLotForLevel(g_strategy, 1, _Symbol);
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
   if(g_grid.PendingStopHasStopLoss(side))
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
   if(g_grid.FindPendingStop(POSITION_TYPE_BUY) == 0)
      g_grid.PlacePendingStop(POSITION_TYPE_BUY, lot, ask + distance, comment);
   if(g_grid.FindPendingStop(POSITION_TYPE_SELL) == 0)
      g_grid.PlacePendingStop(POSITION_TYPE_SELL, lot, bid - distance, comment);
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
   //--- their state machine; a grid reports GRID. The reversal level is the
   //--- price of the open position's opposite stop, "0" when there is none.
   string state_name   = "GRID";
   string state_reason = "";
   double level        = 0.0;
   if(SinglePositionMode())
     {
      state_name   = g_state.Name();
      state_reason = g_state.Reason();
      if(g_strategy.category == CATEGORY_REVERSAL && g_state.IsActive())
         level = g_grid.PendingStopPrice(g_state.Is(STATE_BUY_ACTIVE) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);
     }
   json += "\"execution\":{";
   json += "\"state\":\"" + JsonEscape(state_name) + "\",";
   json += "\"reason\":\"" + JsonEscape(state_reason) + "\",";
   json += "\"reversal_level\":\"" + DoubleToString(level, digits) + "\",";
   json += "\"daily_profit\":\"" + DoubleToString(g_grid.TodayProfit(), 2) + "\",";
   json += "\"risk_halt\":\"" + JsonEscape(RiskHaltReason()) + "\"},";

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

   //--- Resting orders. Only a reversal strategy places any, but the list is
   //--- always sent, so the platform clears whatever is no longer there.
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
//| Grid level is encoded in the order comment as "GG:<id>:L<n>".     |
//+------------------------------------------------------------------+
int LevelFromComment(const string comment)
  {
   int marker = StringFind(comment, ":L");
   if(marker < 0)
      return 0;
   return (int)StringToInteger(StringSubstr(comment, marker + 2));
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
   last_quote_at = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);

   BuildTesterStrategy(g_strategy, InpTestCategory, InpTestLot, InpTestTrailingPoints, InpTestStepPoints,
                       InpTestEntryPoints, InpTestMaxSpreadPoints, InpTestMaxDailyLoss,
                       InpTestGridSpacingPoints, InpTestGridLevels);
   g_monitor.Configure(InpMagicNumber, _Symbol, g_strategy.category == CATEGORY_REVERSAL);
   g_chaos.Configure(InpMagicNumber, _Symbol, InpChaosEveryMinutes, InpChaosSeed);

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
   risk_halt_noted       = "";
   last_gate_note        = "";
   ENUM_EXEC_STATE previous = g_state.Load();
   PrintFormat("GoldGrid: CHAOS restart — previous state %s, now %s", ExecStateName(previous), g_state.Name());
  }

void TesterTick()
  {
   static int   reversal_entries_at_close = -1;

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
               "market_start=%.2f | market_end=%.2f | market_change_pct=%.2f | market_range=%.2f | checks=%d",
               g_monitor.violations, g_monitor.max_positions, trades, g_state.Reversals(), g_state.ReversalsFlat(),
               g_monitor.max_overlap_ms,
               g_state.Entries(STATE_RECOVERY), g_state.Entries(STATE_CLOSING),
               g_monitor.breaches_seen, g_monitor.breaches_repaired,
               g_chaos.Total(), g_chaos.counts[CHAOS_MANUAL_CLOSE], g_chaos.counts[CHAOS_EXTRA_POSITION],
               g_chaos.counts[CHAOS_DUPLICATE_ORDER], g_chaos.counts[CHAOS_RESTART], g_chaos.counts[CHAOS_TICK_STORM],
               TesterStatistics(STAT_PROFIT), TesterStatistics(STAT_PROFIT_FACTOR), win_rate,
               TesterStatistics(STAT_EQUITYDD_PERCENT),
               g_monitor.first_bid, g_monitor.last_bid, change_pct, g_monitor.high_bid - g_monitor.low_bid,
               g_monitor.checks);
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

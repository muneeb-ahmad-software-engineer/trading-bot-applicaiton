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
//| Two strategy categories are supported:                            |
//|   * grid     — adds levels as price moves against the basket.     |
//|   * trailing — one position per direction, managed by a stop that |
//|                follows price in the favourable direction only.    |
//|                                                                   |
//| Both categories run BUY and SELL independently and continuously   |
//| when direction is "both": each side opens on its own, exits on    |
//| its own, and opens again as soon as it is flat. Nobody has to     |
//| restart anything between trades. This requires a HEDGING account  |
//| — on a netting account a buy and a sell on one symbol cancel out, |
//| and the EA refuses the second side rather than fight itself.      |
//| A trailing stop can be configured on EITHER category. The         |
//| category decides how positions are opened, not how they exit.     |
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
#property version   "1.00"
#property description "Grid and trailing-stop EA driven by GoldGrid strategy configuration. Test on a demo account first."

#include "Include/GoldGrid/Api.mqh"
#include "Include/GoldGrid/Strategy.mqh"
#include "Include/GoldGrid/Grid.mqh"

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

//--- State --------------------------------------------------------------
// Globals carry a g_ prefix so that a parameter named `strategy` inside a
// helper cannot silently shadow the one piece of state the whole EA turns on.
// In a program that places orders, reading the wrong `strategy` is not a
// style problem.
CGoldGridApi  g_api;
CGridEngine   g_grid;
SGridStrategy g_strategy;

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
ulong NowMs(void) { return GetTickCount64(); }

ulong    last_report_at = 0;
ulong    last_config_at = 0;
string   halt_reason    = "";     // non-empty means: do not open anything
bool     halted         = false;
string   last_gate_note = "";
string   ea_version     = "1.00";

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

//+------------------------------------------------------------------+
int OnInit()
  {
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

   ManageDirection(POSITION_TYPE_BUY);
   ManageDirection(POSITION_TYPE_SELL);
  }

//+------------------------------------------------------------------+
void ManageDirection(const ENUM_POSITION_TYPE type)
  {
   //--- Skip a direction the strategy does not use.
   if(g_strategy.direction == GRID_BUY_ONLY  && type == POSITION_TYPE_SELL) return;
   if(g_strategy.direction == GRID_SELL_ONLY && type == POSITION_TYPE_BUY)  return;

   SBasket basket = g_grid.Basket(type);

   //--- 1. Exits first. Closing takes precedence over opening, always.
   if(g_grid.ShouldCloseBasket(g_strategy, basket))
     {
      int closed = g_grid.CloseBasket(type);

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
      return;
     }

   //--- 2. Opening is gated.
   if(halted || !InpAllowTrading)
      return;

   //--- A trailing strategy holds one position per direction; a grid holds as
   //--- many as it has levels.
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
      if(g_grid.OpenMarket(type, next_lot, StringFormat("GG:%I64d:L1", g_strategy.id)))
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
   ENUM_API_RESULT result = g_api.PostReport(body);

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
      //--- user is actually watching. Zero means no stop attached; the platform
      //--- reads that as "none" rather than as a price.
      json += "\"stop_loss\":\"" + DoubleToString(PositionGetDouble(POSITION_SL), digits) + "\",";
      json += "\"profit\":\"" + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + "\",";
      json += "\"swap\":\"" + DoubleToString(PositionGetDouble(POSITION_SWAP), 2) + "\",";
      json += "\"commission\":\"" + DoubleToString(CGridEngine::PositionCommission(PositionGetInteger(POSITION_IDENTIFIER)), 2) + "\",";
      json += "\"opened_at\":\"" + IsoTime((datetime)PositionGetInteger(POSITION_TIME)) + "\"";
      json += "}";
     }
   json += "],";

   //--- This EA opens positions at market rather than resting pending orders,
   //--- so the list is always empty. It is still sent, so the platform clears
   //--- anything left over from a previous configuration.
   json += "\"orders\":[]";

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
  }
//+------------------------------------------------------------------+

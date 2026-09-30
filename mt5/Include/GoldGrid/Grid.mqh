//+------------------------------------------------------------------+
//| Grid.mqh                                                          |
//| Grid engine: reads account state, applies the risk gates, and     |
//| manages baskets.                                                  |
//|                                                                   |
//| Only positions and orders carrying this EA's magic number and     |
//| symbol are ever touched. Anything else on the account, placed by  |
//| hand or by another EA, is invisible to this code.                 |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_GRID_MQH
#define GOLDGRID_GRID_MQH

#include <Trade/Trade.mqh>
#include "Strategy.mqh"

//--- Why new orders are currently refused. Shown to the user and reported.
enum ENUM_TRADE_GATE
  {
   GATE_OPEN,
   GATE_NOT_RUNNING,
   GATE_CONFIG_STALE,
   GATE_SPREAD_TOO_WIDE,
   GATE_MAX_POSITIONS,
   GATE_MAX_EXPOSURE,
   GATE_DRAWDOWN,
   GATE_MARGIN_LEVEL,
   //--- On a netting account a symbol holds ONE position. Opening the opposite
   //--- direction does not add a second one, it reduces or reverses the first.
   //--- A both-directions strategy on such an account would spend the day
   //--- cancelling itself out, so it is refused rather than attempted.
   GATE_NETTING_OPPOSITE,
   //--- These four were one value, GATE_MARKET_CLOSED. They have completely
   //--- different fixes — one is a toolbar button, one is a checkbox on the
   //--- EA, one is the broker, one is the clock — and a single message saying
   //--- "market closed or trading disabled" sends people to the wrong one.
   GATE_TERMINAL_ALGO_OFF,
   GATE_EA_TRADING_OFF,
   GATE_ACCOUNT_NO_TRADING,
   GATE_MARKET_CLOSED,
   GATE_EMERGENCY_STOP,
   GATE_DAILY_LOSS
  };

string TradeGateReason(const ENUM_TRADE_GATE gate)
  {
   switch(gate)
     {
      case GATE_OPEN:             return "";
      case GATE_NOT_RUNNING:      return "Strategy is not running";
      case GATE_CONFIG_STALE:     return "Configuration is stale — platform unreachable";
      case GATE_SPREAD_TOO_WIDE:  return "Spread above the configured maximum";
      case GATE_MAX_POSITIONS:    return "Maximum positions reached";
      case GATE_MAX_EXPOSURE:     return "Maximum exposure reached";
      case GATE_DRAWDOWN:         return "Drawdown protection triggered";
      case GATE_MARGIN_LEVEL:     return "Margin level below the configured minimum";
      case GATE_NETTING_OPPOSITE: return "This is a netting account, and the opposite direction is "
                                         "already open — a buy and a sell on one symbol would cancel "
                                         "out. Set the strategy to buy only or sell only, or use a "
                                         "hedging account";
      case GATE_TERMINAL_ALGO_OFF:  return "Algo Trading is switched off in MetaTrader — press the "
                                           "\"Algo Trading\" button in the toolbar";
      case GATE_EA_TRADING_OFF:     return "This EA is not permitted to trade — tick \"Allow Algo Trading\" "
                                           "in its properties";
      case GATE_ACCOUNT_NO_TRADING: return "The broker account does not permit expert trading";
      case GATE_MARKET_CLOSED:      return "Market closed for this symbol";
      case GATE_EMERGENCY_STOP:     return "Emergency stop — everything is being closed; start the strategy "
                                           "again on the platform to clear it";
      case GATE_DAILY_LOSS:         return "Daily loss limit reached — nothing opens until the broker's next "
                                           "trading day";
     }
   return "Unknown";
  }

struct SBasket
  {
   int      count;          // open positions in this direction
   double   volume;         // total lots
   double   profit;         // net of swap and commission
   double   worst_price;    // furthest-out entry, the anchor for the next level
   int      highest_level;
  };

class CGridEngine
  {
private:
   CTrade            m_trade;
   long              m_magic;
   string            m_symbol;
   double            m_peak_equity;
   string            m_peak_key;
   ENUM_TRADE_GATE   m_gate;
   //--- A stop that keeps being rejected would otherwise reprint its reason on
   //--- every tick and bury the rest of the log.
   ulong             m_trail_complaint_at;
   int               m_trail_complaint_code;
   double            m_today_profit;
   ulong             m_today_at;

   bool              IsOurs(void) const
     {
      return PositionGetInteger(POSITION_MAGIC) == m_magic &&
             PositionGetString(POSITION_SYMBOL) == m_symbol;
     }

   //--- Print a recurring trailing problem at most once a minute, and again
   //--- immediately if the reason changes. A broker that rejects a modify
   //--- usually rejects it on every tick, and the log has to stay readable
   //--- enough for the user to find the one line that explains why.
   void              Complain(const int code, const string message)
     {
      //--- Monotonic, for the same reason the report interval is: a throttle
      //--- measured against quote time never expires in a quiet market.
      if(code == m_trail_complaint_code && ClockMs() - m_trail_complaint_at < 60000)
         return;

      m_trail_complaint_code = code;
      m_trail_complaint_at   = ClockMs();
      Print(message);
     }

public:
                     CGridEngine(void)
     {
      m_magic = 0;
      m_peak_equity = 0.0;
      m_gate = GATE_OPEN;
      m_trail_complaint_at = 0;
      m_trail_complaint_code = 0;
      m_today_profit = 0.0;
      m_today_at = 0;
     }

   void              Configure(const long magic, const string symbol, const int slippage_points)
     {
      m_magic    = magic;
      m_symbol   = symbol;
      //--- Keyed per magic number and symbol so two instances do not share a
      //--- drawdown baseline.
      m_peak_key = StringFormat("GoldGrid.peak.%I64d.%s", magic, symbol);
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints(slippage_points);
      m_trade.SetTypeFillingBySymbol(symbol);
      m_trade.SetAsyncMode(false);
      //--- CTrade echoes every request it sends. Live that is the audit
      //--- trail; in the Strategy Tester it is thousands of lines a day that
      //--- bury the ones a run is judged on. Errors are still printed.
      if(IsTester())
         m_trade.LogLevel(LOG_LEVEL_ERRORS);
     }

   ENUM_TRADE_GATE   Gate(void) const { return m_gate; }

   //--- Highest equity seen, the reference point for the drawdown gate.
   //--- Held in a terminal global variable so removing and re-attaching the EA
   //--- does not silently reset drawdown to zero and re-open trading that the
   //--- limit had correctly stopped.
   double            PeakEquity(void) const { return m_peak_equity; }

   void              LoadPeakEquity(void)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);

      if(GlobalVariableCheck(m_peak_key))
        {
         m_peak_equity = GlobalVariableGet(m_peak_key);
         if(m_peak_equity <= 0.0)
            m_peak_equity = equity;
        }
      else
        {
         m_peak_equity = equity;
         GlobalVariableSet(m_peak_key, m_peak_equity);
        }
     }

   //--- Deliberately explicit: used when a user wants to re-baseline drawdown
   //--- after a deposit or withdrawal.
   void              ResetPeakEquity(void)
     {
      m_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(m_peak_key, m_peak_equity);
     }

   void              TrackEquity(void)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_peak_equity)
        {
         m_peak_equity = equity;
         GlobalVariableSet(m_peak_key, m_peak_equity);
        }
     }

   double            DrawdownPercent(void) const
     {
      if(m_peak_equity <= 0.0)
         return 0.0;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity >= m_peak_equity)
         return 0.0;
      return (m_peak_equity - equity) / m_peak_equity * 100.0;
     }

   //--- Collect the basket for one direction.
   SBasket           Basket(const ENUM_POSITION_TYPE type) const
     {
      SBasket basket;
      basket.count = 0;
      basket.volume = 0.0;
      basket.profit = 0.0;
      basket.worst_price = 0.0;
      basket.highest_level = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
            continue;

         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);

         basket.count++;
         basket.volume += PositionGetDouble(POSITION_VOLUME);
         //--- Net of carrying costs. Excluding commission here would make a
         //--- basket look profitable before it actually is, and close early.
         basket.profit += PositionGetDouble(POSITION_PROFIT)
                        + PositionGetDouble(POSITION_SWAP)
                        + PositionCommission(PositionGetInteger(POSITION_IDENTIFIER));

         //--- The anchor for the next level is the entry furthest against us:
         //--- lowest for a buy grid, highest for a sell grid.
         if(basket.worst_price == 0.0)
            basket.worst_price = open_price;
         else if(type == POSITION_TYPE_BUY && open_price < basket.worst_price)
            basket.worst_price = open_price;
         else if(type == POSITION_TYPE_SELL && open_price > basket.worst_price)
            basket.worst_price = open_price;
        }

      basket.highest_level = basket.count;
      return basket;
     }

   int               TotalPositions(void) const
     {
      int count = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if(IsOurs())
            count++;
        }
      return count;
     }

   double            TotalVolume(void) const
     {
      double volume = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if(IsOurs())
            volume += PositionGetDouble(POSITION_VOLUME);
        }
      return volume;
     }

   //+---------------------------------------------------------------+
   //| THE RISK GATE.                                                 |
   //|                                                                |
   //| Every configured limit is checked here, and this runs before   |
   //| every single order. The platform does not enforce any of this. |
   //+---------------------------------------------------------------+
   //--- resting_order: the question is whether a stop order may rest, not
   //--- whether to fill at market now. The spread limit does not apply to that.
   //--- It keeps a market order from filling at a bad price NOW; a stop order
   //--- fills later, at its trigger, and today's spread says nothing about that.
   //--- Applying it anyway was worse than useless: spreads widen exactly when
   //--- price moves fast, so a one-second spike cancelled the bracket in the
   //--- moments it was most likely to be hit. Observed on the demo account, as
   //--- the whole bracket cancelled and re-placed on a single tick.
   bool              MayOpen(const SGridStrategy &strategy, const bool config_is_fresh,
                             const double next_lot, const ENUM_POSITION_TYPE type, string &reason,
                             const bool resting_order = false)
     {
      m_gate = GATE_OPEN;

      if(!config_is_fresh)                       m_gate = GATE_CONFIG_STALE;
      else if(strategy.emergency_stop)           m_gate = GATE_EMERGENCY_STOP;
      else if(DailyLossBreached(strategy))       m_gate = GATE_DAILY_LOSS;
      else if(!strategy.IsRunning())             m_gate = GATE_NOT_RUNNING;
      else if(TradingGate() != GATE_OPEN)        m_gate = TradingGate();
      else if(!AccountIsHedging() && strategy.category == CATEGORY_REVERSAL)
                                                 m_gate = GATE_NETTING_OPPOSITE;
      else if(OppositeWouldNet(type))            m_gate = GATE_NETTING_OPPOSITE;
      else if(!resting_order && SpreadTooWide(strategy))
                                                 m_gate = GATE_SPREAD_TOO_WIDE;
      else if(TotalPositions() >= strategy.max_positions)
                                                 m_gate = GATE_MAX_POSITIONS;
      else if(TotalVolume() + next_lot > strategy.max_exposure_lots + 0.0000001)
                                                 m_gate = GATE_MAX_EXPOSURE;
      else if(DrawdownBreached(strategy))        m_gate = GATE_DRAWDOWN;
      else if(MarginTooLow(strategy))            m_gate = GATE_MARGIN_LEVEL;

      reason = TradeGateReason(m_gate);
      return m_gate == GATE_OPEN;
     }

   //--- Hedging accounts hold a buy basket and a sell basket side by side.
   //--- Netting accounts hold one net position per symbol, so sending the
   //--- opposite direction closes or reverses what is already there instead of
   //--- adding to it. Everything in this EA that counts baskets per direction
   //--- assumes the first arrangement.
   bool              AccountIsHedging(void) const
     {
      return (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
             == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
     }

   bool              OppositeWouldNet(const ENUM_POSITION_TYPE type) const
     {
      if(AccountIsHedging())
         return false;

      ENUM_POSITION_TYPE opposite = (type == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL
                                                                : POSITION_TYPE_BUY;
      return Basket(opposite).count > 0;
     }

   //--- Which permission is missing, in the order a user would check them.
   ENUM_TRADE_GATE   TradingGate(void) const
     {
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
         return GATE_TERMINAL_ALGO_OFF;
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
         return GATE_EA_TRADING_OFF;
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
         return GATE_ACCOUNT_NO_TRADING;

      ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE);
      if(mode != SYMBOL_TRADE_MODE_FULL)
         return GATE_MARKET_CLOSED;

      //--- The trade mode says whether the symbol may be traded at all, not
      //--- whether its session is open now. Without this the EA sent its
      //--- bracket every second all weekend and through gold's daily break,
      //--- and the broker rejected every one with "Market closed" — found by
      //--- the Strategy Tester, where it filled the log.
      if(!TradeSessionOpen())
         return GATE_MARKET_CLOSED;

      return GATE_OPEN;
     }

   //--- Whether the broker's trading session for this symbol is open at the
   //--- current server time. A broker that publishes no session times at all
   //--- for any day is treated as always open, rather than never trading.
   bool              TradeSessionOpen(void) const
     {
      MqlDateTime now;
      TimeToStruct(TimeTradeServer(), now);
      datetime since_midnight = (datetime)(now.hour * 3600 + now.min * 60 + now.sec);

      datetime from, to;
      for(uint i = 0; SymbolInfoSessionTrade(m_symbol, (ENUM_DAY_OF_WEEK)now.day_of_week, i, from, to); i++)
        {
         //--- A session ending at midnight is reported as 24:00.
         if(to == 0 || to <= from)
            to = 86400;
         if(since_midnight >= from && since_midnight < to)
            return true;
        }

      for(int day = 0; day < 7; day++)
         if(SymbolInfoSessionTrade(m_symbol, (ENUM_DAY_OF_WEEK)day, 0, from, to))
            return false;   // sessions exist, and none of today's is open
      return true;          // no session data at all
     }

   //--- Seconds until the current trading session closes, in server time. A
   //--- session that runs on into the next day's without a break reads as
   //--- INT_MAX. False outside every session, or when the broker publishes none.
   //---
   //--- Only the END is taken from the session table. Its start is not to be
   //--- trusted: this broker's table opens gold at 00:00, while the first real
   //--- price arrives at 01:00 (see QUOTE_GAP_SECONDS in GoldGrid.mq5).
   bool              SecondsToSessionClose(int &until_close) const
     {
      MqlDateTime now;
      TimeToStruct(TimeTradeServer(), now);
      int t = now.hour * 3600 + now.min * 60 + now.sec;
      ENUM_DAY_OF_WEEK today    = (ENUM_DAY_OF_WEEK)now.day_of_week;
      ENUM_DAY_OF_WEEK tomorrow = (ENUM_DAY_OF_WEEK)((now.day_of_week + 1) % 7);

      datetime from, to;
      for(uint i = 0; SymbolInfoSessionTrade(m_symbol, today, i, from, to); i++)
        {
         int start = (int)from, end = (int)to;
         if(end == 0 || end <= start)
            end = 86400;   // a session ending at midnight is reported as 24:00
         if(t < start || t >= end)
            continue;

         until_close = end - t;
         if(end == 86400 && SessionStartsAtMidnight(tomorrow))
            until_close = INT_MAX;
         return true;
        }
      return false;
     }

   bool              SessionStartsAtMidnight(const ENUM_DAY_OF_WEEK day) const
     {
      datetime from, to;
      for(uint i = 0; SymbolInfoSessionTrade(m_symbol, day, i, from, to); i++)
         if((int)from == 0)
            return true;
      return false;
     }

   bool              TradingAllowed(void) const { return TradingGate() == GATE_OPEN; }

   bool              SpreadTooWide(const SGridStrategy &strategy) const
     {
      if(!strategy.has_max_spread)
         return false;
      long spread = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      return spread > strategy.max_spread_points;
     }

   bool              DrawdownBreached(const SGridStrategy &strategy) const
     {
      if(!strategy.has_max_drawdown)
         return false;
      return DrawdownPercent() >= strategy.max_drawdown_percent;
     }

   //--- The start of the broker's trading day, in server time. TimeCurrent()
   //--- is the server clock (last quote), which is the clock the broker's day
   //--- — and its daily statements — run on.
   static datetime   TradingDayStart(void)
     {
      datetime now = TimeCurrent();
      return now - (now % 86400);
     }

   //--- Today's result for this EA's positions on this symbol: every deal
   //--- since the start of the trading day (profit, swap and commission —
   //--- entry commissions included), plus the floating result of what is still
   //--- open. What the user sees as "how much has it lost today".
   double            TodayProfit(void)
     {
      //--- Read on every pass and every tick; the day's history does not need
      //--- re-scanning more than twice a second.
      if(m_today_at > 0 && ClockMs() - m_today_at < 500)
         return m_today_profit;

      double total = 0.0;

      if(HistorySelect(TradingDayStart(), TimeCurrent() + 3600))
        {
         int deals = HistoryDealsTotal();
         for(int i = 0; i < deals; i++)
           {
            ulong deal = HistoryDealGetTicket(i);
            if(deal == 0)
               continue;
            if(HistoryDealGetInteger(deal, DEAL_MAGIC) != m_magic ||
               HistoryDealGetString(deal, DEAL_SYMBOL) != m_symbol)
               continue;
            total += HistoryDealGetDouble(deal, DEAL_PROFIT)
                   + HistoryDealGetDouble(deal, DEAL_SWAP)
                   + HistoryDealGetDouble(deal, DEAL_COMMISSION);
           }
        }

      //--- Floating: profit and swap only. Entry commission is already a deal
      //--- of today (or of an earlier day, where it belongs), so counting
      //--- PositionCommission here as well would count it twice.
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }

      m_today_profit = total;
      m_today_at     = ClockMs();
      return total;
     }

   bool              DailyLossBreached(const SGridStrategy &strategy)
     {
      if(!strategy.has_max_daily_loss)
         return false;
      return TodayProfit() <= -strategy.max_daily_loss;
     }

   //--- Closes every position of ours, at market. Returns how many closes
   //--- FAILED. Used by the risk halts, which want everything gone.
   int               CloseAllPositions(const string why)
     {
      ulong tickets[];
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         int n = ArraySize(tickets);
         ArrayResize(tickets, n + 1);
         tickets[n] = ticket;
        }

      int failed = 0;
      for(int i = 0; i < ArraySize(tickets); i++)
         if(!ClosePosition(tickets[i], why))
            failed++;
      return failed;
     }

   bool              MarginTooLow(const SGridStrategy &strategy) const
     {
      if(!strategy.has_min_margin_level)
         return false;
      double level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      //--- With no open positions the broker reports a margin level of 0,
      //--- which must not be read as "dangerously low".
      if(level <= 0.0)
         return false;
      return level < strategy.min_margin_level_percent;
     }

   //--- Basket exits are evaluated per direction, so a buy basket and a sell
   //--- basket close on their own results rather than netting against each
   //--- other.
   bool              ShouldCloseBasket(const SGridStrategy &strategy, const SBasket &basket) const
     {
      if(basket.count == 0)
         return false;
      if(strategy.has_basket_take_profit && basket.profit >= strategy.basket_take_profit)
         return true;
      if(strategy.has_basket_stop_loss && basket.profit <= -strategy.basket_stop_loss)
         return true;
      return false;
     }

   int               CloseBasket(const ENUM_POSITION_TYPE type)
     {
      int closed = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
            continue;

         if(m_trade.PositionClose(ticket))
            closed++;
         else
            PrintFormat("GoldGrid: failed to close #%I64u — %s (%d)",
                        ticket, m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode());
        }
      return closed;
     }

   //--- Our one open position: its ticket, with its side in `type`. 0 when
   //--- flat. With more than one open it returns the first found — callers
   //--- check TotalPositions() first when that matters.
   ulong             OurPosition(ENUM_POSITION_TYPE &type) const
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         return ticket;
        }
      return 0;
     }

   //--- BROKER CONFIRMATION of a close: the position is gone from the open
   //--- list AND the deal history holds the deal that closed it. Either alone
   //--- is not enough — the open list can lag a fill, and a history read can
   //--- lag the list — and a reversal that trusts a guess can end up holding
   //--- both sides.
   //--- `ticket` is checked against the open list, `position_id`
   //--- (POSITION_IDENTIFIER) against the deal history, which is keyed by it.
   bool              PositionConfirmedClosed(const ulong ticket, const long position_id) const
     {
      if(ticket == 0)
         return true;
      if(PositionSelectByTicket(ticket))
         return false;
      if(!HistorySelectByPosition(position_id > 0 ? position_id : (long)ticket))
         return false;

      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0)
            continue;
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
            return true;
        }
      return false;
     }

   //--- Sends a close and reports whether the broker executed it. Execution is
   //--- not the same as confirmation: the caller still waits for
   //--- PositionConfirmedClosed before treating the account as flat.
   bool              ClosePosition(const ulong ticket, const string why)
     {
      if(!PositionSelectByTicket(ticket) || !IsOurs())
         return false;

      string side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell";
      if(m_trade.PositionClose(ticket) && m_trade.ResultRetcode() == TRADE_RETCODE_DONE)
        {
         PrintFormat("GoldGrid: close of %s #%I64u executed (%s)", side, ticket, why);
         return true;
        }
      PrintFormat("GoldGrid: close of %s #%I64u FAILED (%s) — %s (%d)", side, ticket, why,
                  m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode());
      return false;
     }

   //--- ONE-POSITION ENFORCEMENT for the single-position categories. Closes
   //--- every position of ours except the most recently opened one, which is
   //--- the one the strategy most recently decided to hold (a reversal fill,
   //--- or the side of a bracket that triggered last). Returns how many closes
   //--- FAILED — non-zero means the account is still over the limit and no new
   //--- entry may be considered until a later pass gets it back to one.
   int               CloseAllButNewest(void)
     {
      ulong newest_ticket = 0;
      long  newest_time   = -1;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         long opened = PositionGetInteger(POSITION_TIME_MSC);
         if(opened > newest_time)
           {
            newest_time   = opened;
            newest_ticket = ticket;
           }
        }

      int failed = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || ticket == newest_ticket || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;

         string side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell";
         if(m_trade.PositionClose(ticket) && m_trade.ResultRetcode() == TRADE_RETCODE_DONE)
            PrintFormat("GoldGrid: closed extra %s #%I64u — only one position may be open, keeping #%I64u",
                        side, ticket, newest_ticket);
         else
           {
            failed++;
            PrintFormat("GoldGrid: FAILED to close extra %s #%I64u — %s (%d). New entries stay blocked.",
                        side, ticket, m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode());
           }
        }
      return failed;
     }

   //--- MQL5 exposes commission on deals, not on open positions. Summing the
   //--- deals that opened a position is the only way to report it accurately,
   //--- and without it every reported P/L is optimistic by the commission.
   static double     PositionCommission(const long position_id)
     {
      if(!HistorySelectByPosition(position_id))
         return 0.0;

      double commission = 0.0;
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0)
            continue;
         commission += HistoryDealGetDouble(deal, DEAL_COMMISSION);
        }
      return commission;
     }

   //+---------------------------------------------------------------+
   //| THE TRAILING STOP.                                             |
   //|                                                                |
   //| Worked through with the user's own numbers. Gold at $345, a    |
   //| $2 loss margin (200 points), a buy position:                   |
   //|                                                                |
   //|   price reaches $355  ->  stop placed at $353                  |
   //|   price reaches $365  ->  stop moved  to $363                  |
   //|   price falls to $360 ->  stop stays  at $363                  |
   //|                                                                |
   //| A sell is the mirror image: the stop sits ABOVE the market and |
   //| only ever moves down.                                          |
   //|                                                                |
   //| The one invariant: the stop is only ever moved in the          |
   //| favourable direction. A trailing stop that can widen is not a  |
   //| trailing stop, it is a way to lose more than the user agreed   |
   //| to, and every branch below is written so that cannot happen.   |
   //|                                                                |
   //| The stop level ITSELF is the record of the best price seen, so |
   //| nothing is cached: restarting the terminal, or re-attaching    |
   //| the EA, cannot reset a trail that has already ratcheted up.    |
   //|                                                                |
   //| Returns the number of positions whose stop was moved.          |
   //+---------------------------------------------------------------+
   int               ApplyTrailingStops(const SGridStrategy &strategy)
     {
      if(!strategy.has_trailing || strategy.trailing_stop_points <= 0)
         return 0;

      //--- A reversal position carries no stop loss at all: its exit is the
      //--- opposite stop order that TrailOppositeStop keeps behind it.
      if(strategy.category == CATEGORY_REVERSAL)
         return 0;

      //--- Nothing can be modified while the terminal or the account refuses
      //--- trading, and the market has to be open to hold a stop at all.
      if(TradingGate() != GATE_OPEN)
         return 0;

      double point  = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      if(point <= 0.0)
         return 0;

      //--- The broker refuses a stop closer to the market than this. A trail
      //--- tighter than the broker allows is not silently ignored: it is
      //--- widened to the closest level that will actually be accepted, and
      //--- the user is told, because the distance they configured is no
      //--- longer the distance they have.
      double minimum = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      double freeze  = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point;

      double distance   = strategy.trailing_stop_points * point;
      double step       = strategy.trailing_step_points * point;
      double activation = strategy.has_trailing_activation
                          ? strategy.trailing_activation_points * point : 0.0;

      if(minimum > distance)
        {
         Complain(0, StringFormat("GoldGrid: trailing distance of %d points is inside the broker's "
                                  "minimum stop distance of %d points — trailing at the broker's "
                                  "minimum instead.",
                                  strategy.trailing_stop_points,
                                  (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL)));
         distance = minimum;
        }

      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(bid <= 0.0 || ask <= 0.0)
         return 0;

      int moved = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if(!IsOurs())
            continue;

         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double open    = PositionGetDouble(POSITION_PRICE_OPEN);
         double stop    = PositionGetDouble(POSITION_SL);
         double take    = PositionGetDouble(POSITION_TP);

         //--- A position is valued at the price it could be CLOSED at, which
         //--- is the bid for a buy and the ask for a sell. Trailing from the
         //--- wrong side of the spread would place every stop a full spread
         //--- too close and stop the position out early.
         double exit_price = (type == POSITION_TYPE_BUY) ? bid : ask;
         double gain       = (type == POSITION_TYPE_BUY) ? (exit_price - open) : (open - exit_price);

         //--- THE INITIAL STOP. A trailing strategy has no other exit, so a
         //--- position must never sit unprotected while it waits to reach
         //--- activation: in a trend that never turns, that is a loss with no
         //--- floor. The stop goes on at the trailing distance from the entry,
         //--- which caps the loss at exactly the margin the user configured,
         //--- and the ratchet below takes it over once the position activates.
         //---
         //--- Positions normally open with this stop already attached; this is
         //--- the backstop for one that did not — opened by an older EA, or
         //--- whose stop the broker refused at entry.
         if(stop <= 0.0 && strategy.category != CATEGORY_GRID)
           {
            double initial = NormalizeDouble((type == POSITION_TYPE_BUY) ? open - distance
                                                                         : open + distance, digits);

            //--- Already past the level the stop belongs at. The loss is beyond
            //--- what the user agreed to, and a stop cannot be placed on the
            //--- wrong side of the market, so close it now.
            bool breached = (type == POSITION_TYPE_BUY) ? exit_price <= initial
                                                        : exit_price >= initial;
            if(breached)
              {
               if(m_trade.PositionClose(ticket))
                  PrintFormat("GoldGrid: #%I64u (%s) had no stop and was already beyond its "
                              "%s loss margin — closed at %s",
                              ticket, type == POSITION_TYPE_BUY ? "buy" : "sell",
                              DoubleToString(distance, digits), DoubleToString(exit_price, digits));
               else
                  Complain(m_trade.ResultRetcode(),
                           StringFormat("GoldGrid: could not close unprotected #%I64u — %s (%d)",
                                        ticket, m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
               continue;
              }

            if(type == POSITION_TYPE_BUY && initial > exit_price - minimum)
               continue;
            if(type == POSITION_TYPE_SELL && initial < exit_price + minimum)
               continue;
            if(freeze > 0.0 && MathAbs(exit_price - initial) < freeze)
               continue;

            if(m_trade.PositionModify(ticket, initial, take))
              {
               moved++;
               PrintFormat("GoldGrid: initial stop on #%I64u (%s) placed at %s (%s from entry %s)",
                           ticket, type == POSITION_TYPE_BUY ? "buy" : "sell",
                           DoubleToString(initial, digits), DoubleToString(distance, digits),
                           DoubleToString(open, digits));
              }
            else
               Complain(m_trade.ResultRetcode(),
                        StringFormat("GoldGrid: could not place the initial stop on #%I64u at %s — %s (%d)",
                                     ticket, DoubleToString(initial, digits),
                                     m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
            continue;
           }

         if(strategy.has_trailing_activation && gain < activation)
            continue;

         double desired = (type == POSITION_TYPE_BUY)
                          ? exit_price - distance
                          : exit_price + distance;

         desired = NormalizeDouble(desired, digits);
         if(desired <= 0.0)
            continue;

         //--- Too close to the market to be accepted right now. Skipping is
         //--- correct: the existing stop is untouched and the next tick tries
         //--- again from a price that may have moved away.
         if(type == POSITION_TYPE_BUY && desired > exit_price - minimum)
            continue;
         if(type == POSITION_TYPE_SELL && desired < exit_price + minimum)
            continue;

         //--- THE RATCHET. An existing stop is only replaced by one that is
         //--- strictly better for the position, and only once the improvement
         //--- is worth a round trip to the broker.
         bool improves;
         if(stop <= 0.0)
            improves = true;                                  // no stop yet
         else if(type == POSITION_TYPE_BUY)
            improves = (desired - stop) >= step;               // moves up only
         else
            improves = (stop - desired) >= step;               // moves down only

         if(!improves)
            continue;

         //--- Inside the freeze distance the broker rejects modifications
         //--- outright. Attempting it would only produce a failed request.
         if(freeze > 0.0 && MathAbs(exit_price - desired) < freeze)
            continue;

         if(m_trade.PositionModify(ticket, desired, take))
           {
            moved++;
            //--- Live only: a backtest moves stops tens of thousands of times.
            if(!IsTester())
               PrintFormat("GoldGrid: trailing stop on #%I64u (%s) moved to %s (%s away from %s)",
                        ticket, type == POSITION_TYPE_BUY ? "buy" : "sell",
                        DoubleToString(desired, digits),
                        DoubleToString(distance, digits),
                        DoubleToString(exit_price, digits));
           }
         else
           {
            Complain(m_trade.ResultRetcode(),
                     StringFormat("GoldGrid: could not move the trailing stop on #%I64u to %s — %s (%d)",
                                  ticket, DoubleToString(desired, digits),
                                  m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
           }
        }

      return moved;
     }

   //+---------------------------------------------------------------+
   //| PENDING STOP ORDERS, used by the reversal strategy.            |
   //+---------------------------------------------------------------+
   bool              IsOurOrder(void) const
     {
      return OrderGetInteger(ORDER_MAGIC) == m_magic &&
             OrderGetString(ORDER_SYMBOL) == m_symbol;
     }

   static ENUM_ORDER_TYPE StopOrderFor(const ENUM_POSITION_TYPE side)
     {
      return side == POSITION_TYPE_BUY ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
     }

   //--- Our resting stop order that would open `side`, or 0.
   ulong             FindPendingStop(const ENUM_POSITION_TYPE side) const
     {
      ENUM_ORDER_TYPE wanted = StopOrderFor(side);
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket))
            continue;
         if(IsOurOrder() && (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == wanted)
            return ticket;
        }
      return 0;
     }

   //--- Removes our resting stop orders for `side`. Returns how many went.
   int               DeletePendingStops(const ENUM_POSITION_TYPE side)
     {
      int deleted = 0;
      ulong ticket;
      while((ticket = FindPendingStop(side)) != 0)
        {
         if(!m_trade.OrderDelete(ticket))
           {
            Complain(m_trade.ResultRetcode(),
                     StringFormat("GoldGrid: could not delete pending #%I64u — %s (%d)",
                                  ticket, m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
            break;
           }
         deleted++;
        }
      return deleted;
     }

   int               DeleteAllPendingStops(void)
     {
      return DeletePendingStops(POSITION_TYPE_BUY) + DeletePendingStops(POSITION_TYPE_SELL);
     }

   //--- BRACKET HYGIENE. A flat reversal strategy rests exactly one Buy Stop
   //--- and one Sell Stop. Anything else of ours — a second order on the same
   //--- side (a retried request that both succeeded, a previous session's
   //--- leftover) or an order of another type — is deleted, so a single spike
   //--- can never fill more than one entry per side. Returns how many went.
   int               DeleteStrayOrders(void)
     {
      int  deleted  = 0;
      bool seen_buy = false, seen_sell = false;

      //--- Tickets first, deletes after: deleting while walking the order list
      //--- shifts the indices under the loop.
      ulong doomed[];
      for(int i = 0; i < OrdersTotal(); i++)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket) || !IsOurOrder())
            continue;

         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         bool keep = false;
         if(type == ORDER_TYPE_BUY_STOP && !seen_buy)        { seen_buy  = true; keep = true; }
         else if(type == ORDER_TYPE_SELL_STOP && !seen_sell) { seen_sell = true; keep = true; }

         if(!keep)
           {
            int n = ArraySize(doomed);
            ArrayResize(doomed, n + 1);
            doomed[n] = ticket;
           }
        }

      for(int i = 0; i < ArraySize(doomed); i++)
        {
         if(m_trade.OrderDelete(doomed[i]))
           {
            deleted++;
            PrintFormat("GoldGrid: deleted stray/duplicate pending order #%I64u", doomed[i]);
           }
         else
            Complain(m_trade.ResultRetcode(),
                     StringFormat("GoldGrid: could not delete stray pending #%I64u — %s (%d)",
                                  doomed[i], m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
        }
      return deleted;
     }

   //--- The volume of our resting stop for `side`, or 0 if there is none.
   double            PendingStopVolume(const ENUM_POSITION_TYPE side) const
     {
      ulong ticket = FindPendingStop(side);
      if(ticket == 0 || !OrderSelect(ticket))
         return 0.0;
      return OrderGetDouble(ORDER_VOLUME_CURRENT);
     }

   //--- The comment of our resting stop for `side`, or "" if there is none.
   string            PendingStopComment(const ENUM_POSITION_TYPE side) const
     {
      ulong ticket = FindPendingStop(side);
      if(ticket == 0 || !OrderSelect(ticket))
         return "";
      return OrderGetString(ORDER_COMMENT);
     }

   //--- The price of our resting stop for `side`, or 0 if there is none.
   double            PendingStopPrice(const ENUM_POSITION_TYPE side) const
     {
      ulong ticket = FindPendingStop(side);
      if(ticket == 0 || !OrderSelect(ticket))
         return 0.0;
      return OrderGetDouble(ORDER_PRICE_OPEN);
     }

   //--- Whether our resting stop for `side` carries a stop loss of its own.
   //--- Bracket orders placed by builds before the trailing opposite stop did.
   bool              PendingStopHasStopLoss(const ENUM_POSITION_TYPE side) const
     {
      ulong ticket = FindPendingStop(side);
      return ticket != 0 && OrderSelect(ticket) && OrderGetDouble(ORDER_SL) > 0.0;
     }

   //--- Makes sure exactly one stop order that would open `side` rests at
   //--- `price`, with no stop loss: in a reversal strategy the position it
   //--- opens is protected by the opposite stop order instead.
   //---
   //--- Moves an existing order rather than replacing it, so there is never a
   //--- moment with no order in place. Returns true if an order now rests at
   //--- the price.
   bool              PlacePendingStop(const ENUM_POSITION_TYPE side, const double lot, const double price,
                                      const string comment)
     {
      double point  = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      if(point <= 0.0 || price <= 0.0)
         return false;

      double stops_level = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      double entry       = NormalizeDouble(price, digits);

      ulong existing = FindPendingStop(side);
      if(existing != 0 && OrderSelect(existing))
        {
         bool same_price  = MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - entry) < point / 2.0;
         bool no_stop     = OrderGetDouble(ORDER_SL) <= 0.0;
         bool same_volume = MathAbs(OrderGetDouble(ORDER_VOLUME_CURRENT) - lot) < 0.000001;

         if(same_price && no_stop && same_volume)
            return true;

         if(same_volume)
            return ModifyPendingStop(existing, entry);

         //--- A volume cannot be modified; the lot size was changed on the
         //--- platform. Replace it.
         if(!m_trade.OrderDelete(existing))
            return false;
        }

      //--- The broker refuses a stop order too close to, or already through,
      //--- the market. The next pass tries again.
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(side == POSITION_TYPE_BUY  && entry < ask + stops_level) return false;
      if(side == POSITION_TYPE_SELL && entry > bid - stops_level) return false;

      bool ok = (side == POSITION_TYPE_BUY)
                ? m_trade.BuyStop(lot, entry, m_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, comment)
                : m_trade.SellStop(lot, entry, m_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, comment);
      if(ok)
         PrintFormat("GoldGrid: placed %s stop, %.2f lots at %s", side == POSITION_TYPE_BUY ? "BUY" : "SELL",
                     lot, DoubleToString(entry, digits));
      else
         Complain(m_trade.ResultRetcode(),
                  StringFormat("GoldGrid: %s stop at %s rejected — %s (%d)",
                               side == POSITION_TYPE_BUY ? "buy" : "sell", DoubleToString(entry, digits),
                               m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
      return ok;
     }

   //--- Moves a resting stop order to `entry` and strips any stop loss it
   //--- carries.
   bool              ModifyPendingStop(const ulong ticket, const double entry)
     {
      if(m_trade.OrderModify(ticket, entry, 0.0, 0.0, ORDER_TIME_GTC, 0))
         return true;
      Complain(m_trade.ResultRetcode(),
               StringFormat("GoldGrid: could not move pending #%I64u to %s — %s (%d)",
                            ticket, DoubleToString(entry, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
                            m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
      return false;
     }

   //+---------------------------------------------------------------+
   //| THE TRAILING OPPOSITE STOP (reversal strategy).                |
   //|                                                                |
   //| While a BUY is open, one SELL STOP rests the trailing distance |
   //| below the bid, and only ever moves UP as price rises. While a  |
   //| SELL is open, one BUY STOP rests the trailing distance above   |
   //| the ask, and only ever moves DOWN. Gold at $2,000, a buy, a    |
   //| 300-point ($3) distance:                                       |
   //|                                                                |
   //|   buy opens at 2000  ->  sell stop placed at 1997              |
   //|   price reaches 2010 ->  sell stop moved  to 2007              |
   //|   price falls to 2008 -> sell stop stays  at 2007              |
   //|   price falls to 2007 -> sell stop fills: the reversal         |
   //|                                                                |
   //| The order is held by the broker, so it still fills with this   |
   //| terminal offline. `held` is the side of the open position; the |
   //| order is for the other side. Returns true if the order rests   |
   //| where it belongs after this call.                              |
   //+---------------------------------------------------------------+
   bool              TrailOppositeStop(const SGridStrategy &strategy, const ENUM_POSITION_TYPE held,
                                       const double lot, const string comment)
     {
      if(strategy.trailing_stop_points <= 0 || TradingGate() != GATE_OPEN)
         return false;

      double point  = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double bid    = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(point <= 0.0 || bid <= 0.0 || ask <= 0.0)
         return false;

      //--- The broker refuses a stop order closer to the market than this. A
      //--- tighter distance is widened to the closest accepted one, and the
      //--- user is told, because it is no longer the distance they configured.
      double minimum  = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      double freeze   = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point;
      double distance = strategy.trailing_stop_points * point;
      double step     = MathMax(strategy.trailing_step_points, 1) * point;
      if(distance <= minimum)
        {
         Complain(0, StringFormat("GoldGrid: trailing distance of %d points is inside the broker's minimum "
                                  "stop distance of %d points — trailing at the broker's minimum instead.",
                                  strategy.trailing_stop_points,
                                  (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL)));
         distance = minimum + point;
        }

      //--- A sell stop is triggered by the bid, a buy stop by the ask.
      ENUM_POSITION_TYPE opposite = (held == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
      double trigger = (opposite == POSITION_TYPE_SELL) ? bid : ask;
      double desired = NormalizeDouble(opposite == POSITION_TYPE_SELL ? bid - distance : ask + distance, digits);

      ulong existing = FindPendingStop(opposite);
      if(existing != 0 && OrderSelect(existing) &&
         MathAbs(OrderGetDouble(ORDER_VOLUME_CURRENT) - lot) < 0.000001)
        {
         double current = OrderGetDouble(ORDER_PRICE_OPEN);

         //--- THE RATCHET. Only ever towards the market, and only once the
         //--- improvement is worth a round trip to the broker. A stop order
         //--- that could move away would let the position lose more than the
         //--- trailing distance the user agreed to.
         bool improves = (opposite == POSITION_TYPE_SELL) ? desired - current >= step
                                                          : current - desired >= step;
         bool has_stop = OrderGetDouble(ORDER_SL) > 0.0;
         if(!improves && !has_stop)
            return true;
         if(!improves)
            desired = current;

         //--- Inside the freeze distance the broker rejects any modification.
         //--- The order stays where it is — it is about to fill anyway.
         if(freeze > 0.0 && MathAbs(trigger - current) < freeze)
            return true;

         if(!ModifyPendingStop(existing, desired))
            return false;
         if(!IsTester() && improves)
            PrintFormat("GoldGrid: %s stop moved to %s (%s behind %s)",
                        opposite == POSITION_TYPE_SELL ? "sell" : "buy", DoubleToString(desired, digits),
                        DoubleToString(distance, digits), DoubleToString(trigger, digits));
         return true;
        }

      //--- None yet (a new position), or the lot size changed: a fresh order
      //--- at the trailing distance from the market.
      if(!PlacePendingStop(opposite, lot, desired, comment))
         return false;
      PrintFormat("GoldGrid: the %s reverses to %s if price reaches %s",
                  held == POSITION_TYPE_BUY ? "BUY" : "SELL", opposite == POSITION_TYPE_SELL ? "SELL" : "BUY",
                  DoubleToString(desired, digits));
      return true;
     }

   //--- Takes the stop loss off a position. A reversal position opened by an
   //--- earlier build carries one; its exit is now the opposite stop order,
   //--- so the stop loss would only close it without reversing.
   bool              RemoveStopLoss(const ulong ticket)
     {
      if(!PositionSelectByTicket(ticket) || PositionGetDouble(POSITION_SL) <= 0.0)
         return true;
      if(m_trade.PositionModify(ticket, 0.0, PositionGetDouble(POSITION_TP)))
        {
         PrintFormat("GoldGrid: removed the stop loss from #%I64u — the opposite stop order is its exit", ticket);
         return true;
        }
      Complain(m_trade.ResultRetcode(),
               StringFormat("GoldGrid: could not remove the stop loss from #%I64u — %s (%d)",
                            ticket, m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
      return false;
     }

   //--- Our most recently opened position, with its side in `type`. 0 when flat.
   ulong             NewestPosition(ENUM_POSITION_TYPE &type) const
     {
      ulong newest = 0;
      long  newest_time = -1;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         long opened = PositionGetInteger(POSITION_TIME_MSC);
         if(opened > newest_time)
           {
            newest_time = opened;
            newest      = ticket;
            type        = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
           }
        }
      return newest;
     }

   //--- stop_points > 0 attaches a stop that far from the entry in the same
   //--- request, so the position is never open for even one tick without it.
   bool              OpenMarket(const ENUM_POSITION_TYPE type, const double lot, const string comment,
                                const int stop_points = 0)
     {
      double stop = 0.0;
      if(stop_points > 0)
        {
         double point  = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
         int    digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
         double stops_level = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
         double distance = MathMax(stop_points * point, stops_level);
         double entry = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(m_symbol, SYMBOL_ASK)
                                                    : SymbolInfoDouble(m_symbol, SYMBOL_BID);
         if(entry > 0.0)
            stop = NormalizeDouble((type == POSITION_TYPE_BUY) ? entry - distance : entry + distance, digits);
        }

      bool ok = (type == POSITION_TYPE_BUY)
                ? m_trade.Buy(lot, m_symbol, 0.0, stop, 0.0, comment)
                : m_trade.Sell(lot, m_symbol, 0.0, stop, 0.0, comment);

      if(!ok)
         PrintFormat("GoldGrid: order rejected — %s (%d)",
                     m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode());
      return ok;
     }
  };

#endif

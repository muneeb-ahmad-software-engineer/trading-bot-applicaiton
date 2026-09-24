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
   GATE_MARKET_CLOSED
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
      if(code == m_trail_complaint_code && GetTickCount64() - m_trail_complaint_at < 60000)
         return;

      m_trail_complaint_code = code;
      m_trail_complaint_at   = GetTickCount64();
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
   bool              MayOpen(const SGridStrategy &strategy, const bool config_is_fresh,
                             const double next_lot, const ENUM_POSITION_TYPE type, string &reason)
     {
      m_gate = GATE_OPEN;

      if(!config_is_fresh)                       m_gate = GATE_CONFIG_STALE;
      else if(!strategy.IsRunning())             m_gate = GATE_NOT_RUNNING;
      else if(TradingGate() != GATE_OPEN)        m_gate = TradingGate();
      else if(OppositeWouldNet(type))            m_gate = GATE_NETTING_OPPOSITE;
      else if(SpreadTooWide(strategy))           m_gate = GATE_SPREAD_TOO_WIDE;
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

      return GATE_OPEN;
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

   bool              OpenMarket(const ENUM_POSITION_TYPE type, const double lot, const string comment)
     {
      bool ok = (type == POSITION_TYPE_BUY)
                ? m_trade.Buy(lot, m_symbol, 0.0, 0.0, 0.0, comment)
                : m_trade.Sell(lot, m_symbol, 0.0, 0.0, 0.0, comment);

      if(!ok)
         PrintFormat("GoldGrid: order rejected — %s (%d)",
                     m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode());
      return ok;
     }
  };

#endif

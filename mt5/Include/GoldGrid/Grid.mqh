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
   GATE_DAILY_LOSS,
   //--- The basket is at its exit and being closed: nothing new may be
   //--- placed until it is confirmed flat (CGridEngine::BeginBasketClose).
   GATE_BASKET_CLOSING
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
      case GATE_BASKET_CLOSING:     return "The basket is closing — nothing new is placed until it is flat";
     }
   return "Unknown";
  }

struct SBasket
  {
   int      count;          // open positions in this direction
   double   volume;         // total lots
   double   profit;         // net of swap and commission
  };

//+------------------------------------------------------------------+
//| LADDER ORDER COMMENTS: "GG:<strategy id>:C<cycle>:L<level>".      |
//|                                                                   |
//| The comment is how a resting order, and the position it becomes,  |
//| is tied back to its rung of the ladder. The order type says which |
//| side; the level counts outward from the anchor, 1 = nearest. The  |
//| cycle number keeps one cycle's orders apart from the next, so a   |
//| leftover from a previous cycle is recognised and removed rather   |
//| than mistaken for a rung of this one. 31 characters is the        |
//| broker's limit; "GG:123456:C9999:L500" is 20.                     |
//+------------------------------------------------------------------+
string LadderComment(const long strategy_id, const int cycle, const int level)
  {
   return StringFormat("GG:%I64d:C%d:L%d", strategy_id, cycle, level);
  }

//--- The level encoded in an order or position comment, or 0. Also reads
//--- the reversal bracket's "GG:<id>:L1:D<n>" (StringToInteger stops at
//--- the first non-digit).
int LevelFromComment(const string comment)
  {
   int marker = StringFind(comment, ":L");
   if(marker < 0)
      return 0;
   return (int)StringToInteger(StringSubstr(comment, marker + 2));
  }

//--- The cycle encoded in a ladder comment, or 0 for anything else.
int CycleFromComment(const string comment)
  {
   int marker = StringFind(comment, ":C");
   if(marker < 0)
      return 0;
   return (int)StringToInteger(StringSubstr(comment, marker + 2));
  }

//--- The strategy id encoded in any of our comments, or -1.
long StrategyIdFromComment(const string comment)
  {
   if(StringFind(comment, "GG:") != 0)
      return -1;
   return StringToInteger(StringSubstr(comment, 3));
  }

//--- What one PlaceLadder pass found and did, for the log and the report.
struct SLadderReport
  {
   int      capacity;       // rungs this cycle may have at most
   int      resting;        // rungs with an order resting
   int      held;           // rungs that filled and are open positions
   int      skipped;        // rungs the market crossed before they were placed
   int      placed;         // orders accepted this pass
   int      requests;       // orders sent this pass, accepted or not
   string   refused;        // why the pass stopped early: the risk gate, or a broker rejection
   bool     complete;       // nothing left to place

   void     Reset(void)
     {
      capacity = resting = held = skipped = placed = requests = 0;
      refused  = "";
      complete = false;
     }
  };

//+------------------------------------------------------------------+
//| THE BASKET CLOSE'S REQUESTS, per ticket.                          |
//|                                                                   |
//| Every close and cancel goes out asynchronously, and its outcome   |
//| arrives later in OnTradeTransaction. Each ticket is paced on its  |
//| own: one still executing is not sent again, one the broker        |
//| refused is sent again on the next pass. Before, one 2 s pace      |
//| covered the whole basket, so a single refused cancel — the rung   |
//| nearest the price, frozen by the broker — waited 2 s while the    |
//| market ran into it.                                               |
//+------------------------------------------------------------------+
//--- No answer yet: sent again after this.
#define BASKET_RESEND_MS            1000
//--- Executed: the open and order lists are given this long to drop it.
#define BASKET_CONFIRM_WAIT_MS      3000
//--- Refused for a reason the next quote can clear (requote, price
//--- moved, frozen near the market, timeout): sent again this soon, at most
//--- BASKET_FAST_RETRIES_MAX times per ticket, then at BASKET_RESEND_MS so a
//--- broker that keeps refusing is not hammered.
#define BASKET_FAST_RETRY_MS        100
#define BASKET_FAST_RETRIES_MAX     10
//--- Orders per side cancelled AHEAD of the closes: the rungs nearest the
//--- price, the only ones the market can reach while the closes execute.
#define BASKET_NEAR_ORDERS_PER_SIDE 2

struct SCloseRequest
  {
   ulong    ticket;
   bool     is_order;       // a cancel; else a close (a filled order's ticket becomes its position's)
   ulong    due_at;         // ClockMs() from which it may be sent again
   int      rejections;
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
   //--- Ladder bookkeeping. The notes string holds "|<B|S><level>|" for
   //--- every rung of cycle m_ladder_notes_cycle already reported as skipped,
   //--- so each is logged once per cycle. The tester may cap the order limit
   //--- below the broker's.
   int               m_ladder_notes_cycle;
   string            m_ladder_notes;
   int               m_ladder_cap_noted;
   int               m_order_limit_override;
   //--- RUNGS THAT HAVE FILLED THIS CYCLE, as "|<B|S><level>|" keys (D6). A
   //--- rung in this set is never placed again within the cycle, whether
   //--- its position is still open or was closed by hand, by a stop-out, or
   //--- by the chaos engine. Fed by the fill transactions and rebuilt from
   //--- the deal history after a restart.
   int               m_filled_cycle;
   string            m_filled_keys;
   //--- Commission per position id, read from history once: it never changes
   //--- while the position is open, and reading it on every tick for sixty
   //--- positions was thousands of history selects a second.
   long              m_commission_ids[];
   double            m_commission_values[];
   //--- Positions the basket close is accountable for: every one open when
   //--- the close began, plus any that filled while it ran. Flat means each
   //--- of these is confirmed closed in the broker's history.
   ulong             m_closing_tickets[];
   long              m_closing_ids[];
   //--- THE PROTECTED CLOSING STATE: set by the first close pass, cleared
   //--- once the basket is confirmed flat. While set, MayOpen refuses
   //--- everything, so nothing can be placed alongside the close.
   bool              m_closing;
   SCloseRequest     m_requests[];

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

   int               FindRequest(const ulong ticket, const bool is_order) const
     {
      for(int i = 0; i < ArraySize(m_requests); i++)
         if(m_requests[i].ticket == ticket && m_requests[i].is_order == is_order)
            return i;
      return -1;
     }

   int               TrackRequest(const ulong ticket, const bool is_order)
     {
      int i = FindRequest(ticket, is_order);
      if(i >= 0)
         return i;
      i = ArraySize(m_requests);
      ArrayResize(m_requests, i + 1);
      m_requests[i].ticket     = ticket;
      m_requests[i].is_order   = is_order;
      m_requests[i].due_at     = 0;
      m_requests[i].rejections = 0;
      return i;
     }

   bool              RequestDue(const ulong ticket, const bool is_order) const
     {
      int i = FindRequest(ticket, is_order);
      return i < 0 || ClockMs() >= m_requests[i].due_at;
     }

   //--- Our resting orders, nearest the price that triggers them first, each
   //--- with its side. A stop order's distance is signed: one the market has
   //--- already reached reads negative and goes first.
   void              OrdersByReach(ulong &tickets[], bool &buys[]) const
     {
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double distance[];
      ArrayResize(tickets, 0);
      ArrayResize(buys, 0);

      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket) || !IsOurOrder())
            continue;
         ENUM_ORDER_TYPE type  = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         double          price = OrderGetDouble(ORDER_PRICE_OPEN);
         bool            buy   = type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_STOP ||
                                 type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP_LIMIT;
         double          d;
         switch(type)
           {
            case ORDER_TYPE_BUY_STOP:
            case ORDER_TYPE_BUY_STOP_LIMIT:  d = price - ask; break;
            case ORDER_TYPE_SELL_STOP:
            case ORDER_TYPE_SELL_STOP_LIMIT: d = bid - price; break;
            case ORDER_TYPE_BUY_LIMIT:       d = ask - price; break;
            case ORDER_TYPE_SELL_LIMIT:      d = price - bid; break;
            default:                         d = -DBL_MAX;    break;   // nothing of ours, but first if it is
           }

         //--- Insertion into the sorted list; a ladder is tens of orders.
         int n = ArraySize(tickets);
         ArrayResize(tickets, n + 1);
         ArrayResize(buys, n + 1);
         ArrayResize(distance, n + 1);
         int k = n;
         while(k > 0 && distance[k - 1] > d)
           {
            tickets[k]  = tickets[k - 1];
            buys[k]     = buys[k - 1];
            distance[k] = distance[k - 1];
            k--;
           }
         tickets[k]  = ticket;
         buys[k]     = buy;
         distance[k] = d;
        }
     }

   //--- One asynchronous cancel, if due. The terminal must be in async mode.
   //--- True if it went.
   bool              SendCancel(const ulong ticket)
     {
      if(!RequestDue(ticket, true))
         return false;
      int i = TrackRequest(ticket, true);
      m_requests[i].due_at = ClockMs() + BASKET_RESEND_MS;
      if(m_trade.OrderDelete(ticket))
         return true;
      NoteCloseOutcome(ticket, true, m_trade.ResultRetcode());
      Complain((int)m_trade.ResultRetcode(),
               StringFormat("GoldGrid: could not send the cancel of order #%I64u — %s (%d)", ticket,
                            m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
      return false;
     }

   //--- One asynchronous close, if due. The terminal must be in async mode.
   //--- 1 sent, 0 not due (or no longer ours to close), -1 refused at the call.
   int               SendClose(const ulong ticket, const string why)
     {
      if(!RequestDue(ticket, false))
         return 0;
      if(!PositionSelectByTicket(ticket) || !IsOurs())
         return 0;
      int i = TrackRequest(ticket, false);
      m_requests[i].due_at = ClockMs() + BASKET_RESEND_MS;
      if(m_trade.PositionClose(ticket))
         return 1;
      NoteCloseOutcome(ticket, false, m_trade.ResultRetcode());
      Complain((int)m_trade.ResultRetcode(),
               StringFormat("GoldGrid: could not send the close of #%I64u (%s) — %s (%d)", ticket, why,
                            m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
      return -1;
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
      m_ladder_notes_cycle = 0;
      m_ladder_notes = "";
      m_ladder_cap_noted = 0;
      m_order_limit_override = 0;
      m_filled_cycle = 0;
      m_filled_keys = "";
      m_closing = false;
     }

   //--- Everything this object remembers about the current run. A real
   //--- restart loses all of it; the tester's simulated restart calls this so
   //--- it loses the same.
   void              ForgetRunState(void)
     {
      m_ladder_notes_cycle = 0;
      m_ladder_notes = "";
      m_ladder_cap_noted = 0;
      m_filled_cycle = 0;
      m_filled_keys = "";
      ArrayResize(m_closing_tickets, 0);
      ArrayResize(m_closing_ids, 0);
      m_closing = false;
      ArrayResize(m_requests, 0);
      ArrayResize(m_commission_ids, 0);
      ArrayResize(m_commission_values, 0);
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

         basket.count++;
         basket.volume += PositionGetDouble(POSITION_VOLUME);
         //--- Net of carrying costs. Excluding commission here would make a
         //--- basket look profitable before it actually is, and close early.
         basket.profit += PositionGetDouble(POSITION_PROFIT)
                        + PositionGetDouble(POSITION_SWAP)
                        + PositionCommission(PositionGetInteger(POSITION_IDENTIFIER));
        }

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

      if(m_closing)                              m_gate = GATE_BASKET_CLOSING;
      else if(!config_is_fresh)                  m_gate = GATE_CONFIG_STALE;
      else if(strategy.emergency_stop)           m_gate = GATE_EMERGENCY_STOP;
      else if(DailyLossBreached(strategy))       m_gate = GATE_DAILY_LOSS;
      else if(!strategy.IsRunning())             m_gate = GATE_NOT_RUNNING;
      else if(TradingGate() != GATE_OPEN)        m_gate = TradingGate();
      else if(!AccountIsHedging() && (strategy.category == CATEGORY_REVERSAL ||
                                      strategy.category == CATEGORY_GRID))
                                                 m_gate = GATE_NETTING_OPPOSITE;
      else if(OppositeWouldNet(type))            m_gate = GATE_NETTING_OPPOSITE;
      else if(!resting_order && SpreadTooWide(strategy))
                                                 m_gate = GATE_SPREAD_TOO_WIDE;
      else if(TotalPositions() + CommittedOrders(strategy) >= strategy.max_positions)
                                                 m_gate = GATE_MAX_POSITIONS;
      else if(TotalVolume() + CommittedVolume(strategy) + next_lot > strategy.max_exposure_lots + 0.0000001)
                                                 m_gate = GATE_MAX_EXPOSURE;
      else if(DrawdownBreached(strategy))        m_gate = GATE_DRAWDOWN;
      else if(MarginTooLow(strategy))            m_gate = GATE_MARGIN_LEVEL;

      reason = TradeGateReason(m_gate);
      return m_gate == GATE_OPEN;
     }

   //--- A LADDER'S RESTING ORDERS COUNT AGAINST THE LIMITS. Every rung can
   //--- fill, and the limits are promises about the worst case, so a ladder
   //--- of 60 orders with a maximum of 60 positions is full before the first
   //--- fill. A reversal bracket is different: only one of its two orders can
   //--- ever fill (the fill cancels the other), so counting both would refuse
   //--- the bracket on a one-position strategy. Trailing places no orders.
   int               CommittedOrders(const SGridStrategy &strategy) const
     {
      return strategy.category == CATEGORY_GRID ? OurOrders() : 0;
     }

   double            CommittedVolume(const SGridStrategy &strategy) const
     {
      return strategy.category == CATEGORY_GRID ? RestingVolume() : 0.0;
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

   //--- CLOSE-ONLY: the broker allows closing positions (and deleting
   //--- orders) but no new entries — set around contract rollovers and
   //--- incidents. TradingGate() reads it as closed, which is right for
   //--- entries; a basket at its target or under a risk halt must still close.
   bool              OnlyClosesAllowed(void) const
     {
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
         !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
         return false;
      return (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_CLOSEONLY &&
             TradeSessionOpen();
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
   //--- `parallel`: send every close at once instead of waiting for each
   //--- reply before sending the next (see ClosePosition). The grid's basket
   //--- close has its own paced pass (CloseBasketPass); the single-position
   //--- strategies close one position and keep the synchronous path.
   int               CloseAllPositions(const string why, const bool parallel = false)
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
         if(!ClosePosition(tickets[i], why, parallel))
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

   //--- The single position's basket exits (trailing and reversal). The grid
   //--- uses BasketExitReason() on its combined basket instead.
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
   //--- `async`: hand the request to the terminal and return at once
   //--- (OrderSendAsync) instead of waiting for the broker's reply. A
   //--- synchronous close costs a full round trip (about 200 ms on the demo
   //--- server), so a basket of ten closed one after another took two
   //--- seconds while the price moved under the last ones. Sent
   //--- asynchronously, all of them leave within milliseconds and execute
   //--- together. The outcome arrives in OnTradeTransaction; the open list
   //--- and the deal history (BasketConfirmedFlat) are what confirm it.
   bool              ClosePosition(const ulong ticket, const string why, const bool async = false)
     {
      if(!PositionSelectByTicket(ticket) || !IsOurs())
         return false;

      string side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell";
      if(async)
        {
         m_trade.SetAsyncMode(true);
         bool sent = m_trade.PositionClose(ticket);
         uint code = m_trade.ResultRetcode();
         m_trade.SetAsyncMode(false);
         if(sent && (code == TRADE_RETCODE_PLACED || code == TRADE_RETCODE_DONE))
            return true;               // the caller logs one line per pass
        }
      else if(m_trade.PositionClose(ticket) && m_trade.ResultRetcode() == TRADE_RETCODE_DONE)
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

      //--- A reversal position's stop loss is trailed by TrailReversalExit,
      //--- together with the opposite stop order at the same price. A grid
      //--- position has one exit, the combined basket target, and no stop.
      if(strategy.category != CATEGORY_TRAILING)
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
         if(stop <= 0.0)
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
   //--- Every reversal stop order does: the position it opens is protected
   //--- by the broker from the instant it fills. Orders placed by earlier
   //--- builds do not, and are replaced.
   bool              PendingStopHasStopLoss(const ENUM_POSITION_TYPE side) const
     {
      ulong ticket = FindPendingStop(side);
      return ticket != 0 && OrderSelect(ticket) && OrderGetDouble(ORDER_SL) > 0.0;
     }

   //--- The distance a reversal position's exit trails behind price: the
   //--- configured trailing distance, widened just past the broker's minimum
   //--- stop distance when it is inside it (the user is told).
   double            ExitDistance(const SGridStrategy &strategy)
     {
      double point   = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double minimum = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      double distance = strategy.trailing_stop_points * point;
      if(distance <= minimum)
        {
         Complain(0, StringFormat("GoldGrid: trailing distance of %d points is inside the broker's minimum "
                                  "stop distance of %d points — trailing at the broker's minimum instead.",
                                  strategy.trailing_stop_points,
                                  (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL)));
         distance = minimum + point;
        }
      return distance;
     }

   //--- The stop loss a stop order opening `side` at `entry` carries, so the
   //--- position is protected by the broker from its first tick — with the
   //--- terminal offline too. It sits where the trailing exit would first be
   //--- placed: `distance` behind the price the position closes at, which is
   //--- one spread away from the price it opened at.
   double            EntryStopLoss(const ENUM_POSITION_TYPE side, const double entry, const double distance) const
     {
      int    digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double spread = MathMax(SymbolInfoDouble(m_symbol, SYMBOL_ASK) - SymbolInfoDouble(m_symbol, SYMBOL_BID), 0.0);
      return NormalizeDouble(side == POSITION_TYPE_BUY ? entry - spread - distance
                                                       : entry + spread + distance, digits);
     }

   //--- Makes sure exactly one stop order that would open `side` rests at
   //--- `price` with `stop_loss` attached (0 = none).
   //---
   //--- Moves an existing order rather than replacing it, so there is never a
   //--- moment with no order in place. Returns true if an order now rests at
   //--- the price.
   bool              PlacePendingStop(const ENUM_POSITION_TYPE side, const double lot, const double price,
                                      const string comment, const double stop_loss = 0.0)
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
         bool same_stop   = MathAbs(OrderGetDouble(ORDER_SL) - stop_loss) < point / 2.0;
         bool same_volume = MathAbs(OrderGetDouble(ORDER_VOLUME_CURRENT) - lot) < 0.000001;

         if(same_price && same_stop && same_volume)
            return true;

         if(same_volume)
            return ModifyPendingStop(existing, entry, stop_loss);

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
                ? m_trade.BuyStop(lot, entry, m_symbol, stop_loss, 0.0, ORDER_TIME_GTC, 0, comment)
                : m_trade.SellStop(lot, entry, m_symbol, stop_loss, 0.0, ORDER_TIME_GTC, 0, comment);
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

   //--- Moves a resting stop order to `entry`, with `stop_loss` attached
   //--- (0 = none).
   bool              ModifyPendingStop(const ulong ticket, const double entry, const double stop_loss = 0.0)
     {
      if(m_trade.OrderModify(ticket, entry, stop_loss, 0.0, ORDER_TIME_GTC, 0))
         return true;
      Complain(m_trade.ResultRetcode(),
               StringFormat("GoldGrid: could not move pending #%I64u to %s — %s (%d)",
                            ticket, DoubleToString(entry, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
                            m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
      return false;
     }

   //+---------------------------------------------------------------+
   //| THE LADDER (grid strategy).                                    |
   //|                                                                |
   //| A cycle rests `grid_buy_orders` Buy Stops above the anchor and |
   //| `grid_sell_orders` Sell Stops below it, one gap apart. The     |
   //| anchor is the bid/ask at the moment the first rung is placed   |
   //| and does not move for the rest of the cycle, so a rung the     |
   //| market has already crossed is skipped, never chased (D5), and  |
   //| a rung that filled is never put back within the cycle (D6).    |
   //|                                                                |
   //| Everything here is IDEMPOTENT: a pass finds what already rests |
   //| or has filled, and sends only what is missing. Running it a    |
   //| thousand times on a complete ladder sends nothing.             |
   //+---------------------------------------------------------------+

   //--- Strategy Tester only: pretend the broker allows at most `limit`
   //--- resting orders (0 = the broker's real ACCOUNT_LIMIT_ORDERS).
   void              SetOrderLimit(const int limit) { m_order_limit_override = limit; }

   //--- Resting orders on the account with our magic number and symbol.
   int               OurOrders(void) const
     {
      int count = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket != 0 && OrderSelect(ticket) && IsOurOrder())
            count++;
        }
      return count;
     }

   //--- Resting orders on the account that are NOT ours — another EA's, a
   //--- manual one, ours on another symbol. They use up the broker's order
   //--- limit just the same.
   int               ForeignOrders(void) const
     {
      int count = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket != 0 && OrderSelect(ticket) && !IsOurOrder())
            count++;
        }
      return count;
     }

   //--- Lots our resting orders would open if every one of them filled.
   double            RestingVolume(void) const
     {
      double volume = 0.0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket != 0 && OrderSelect(ticket) && IsOurOrder())
            volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
        }
      return volume;
     }

   //--- How many rungs this cycle may have: the configured ladder, cut to
   //--- the maximum-positions ceiling and to what the broker's order limit
   //--- leaves after everything else resting on the account. A cut is
   //--- logged once per cycle, with the number it was cut to.
   int               LadderCapacity(const SGridStrategy &strategy, const int cycle)
     {
      int capacity = MathMin(strategy.LadderSize(), strategy.max_positions);

      int limit = m_order_limit_override > 0 ? m_order_limit_override
                                             : (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
      if(limit > 0)
        {
         int room = MathMax(limit - ForeignOrders(), 0);
         if(room < capacity)
           {
            if(m_ladder_cap_noted != cycle)
               PrintFormat("GoldGrid: the broker allows %d resting orders and %d are already in use by "
                           "other orders on the account, so this cycle's ladder is cut from %d to %d rungs",
                           limit, limit - room, capacity, room);
            m_ladder_cap_noted = cycle;
            capacity = room;
           }
        }
      return capacity;
     }

   //--- Rung 1's offset from the anchor, in points: one gap, unless the gap
   //--- is inside the broker's minimum stop distance — then just past it.
   //--- Fixed when the cycle anchors (the cycle record keeps it), so a stop
   //--- level the broker changes mid-cycle does not move the ladder.
   int               FirstRungPoints(const int gap_points) const
     {
      int stops_level = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      return MathMax(gap_points, stops_level + 1);
     }

   //--- Distance from the anchor to rung `level`: `first` points for rung 1,
   //--- one gap more for each rung after it, so no two rungs are ever closer
   //--- than one gap. `first` <= 0 means "compute it now".
   double            LadderOffset(const int gap_points, const int first_points, const int level) const
     {
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int    first = first_points > 0 ? first_points : FirstRungPoints(gap_points);
      return (first + (level - 1) * (double)gap_points) * point;
     }

   //--- Where rung `level` of `side` rests, given the cycle's anchor.
   double            LadderPrice(const ENUM_POSITION_TYPE side, const int level, const int gap_points,
                                 const int first_points, const double anchor_bid, const double anchor_ask) const
     {
      int    digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double offset = LadderOffset(gap_points, first_points, level);
      return NormalizeDouble(side == POSITION_TYPE_BUY ? anchor_ask + offset : anchor_bid - offset, digits);
     }

   //--- THE FILLED SET.
   static string     RungKey(const ENUM_POSITION_TYPE side, const int level)
     {
      return StringFormat("|%s%d|", side == POSITION_TYPE_BUY ? "B" : "S", level);
     }

   void              NoteFill(const int cycle, const ENUM_POSITION_TYPE side, const int level)
     {
      if(cycle <= 0 || level <= 0)
         return;
      if(m_filled_cycle != cycle)
        {
         m_filled_cycle = cycle;
         m_filled_keys  = "";
        }
      string key = RungKey(side, level);
      if(StringFind(m_filled_keys, key) < 0)
         m_filled_keys += key;
     }

   //--- A fill deal of ours: its comment names the rung (the broker copies
   //--- the order comment to the deal), its type names the side.
   void              NoteFillDeal(const long strategy_id, const ulong deal)
     {
      string comment = HistoryDealGetString(deal, DEAL_COMMENT);
      if(StrategyIdFromComment(comment) != strategy_id)
         return;
      ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         return;
      NoteFill(CycleFromComment(comment), type == DEAL_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL,
               LevelFromComment(comment));
     }

   bool              RungFilled(const int cycle, const ENUM_POSITION_TYPE side, const int level) const
     {
      return m_filled_cycle == cycle && StringFind(m_filled_keys, RungKey(side, level)) >= 0;
     }

   //--- Open positions that are rungs of `cycle`, for the report's "filled".
   int               RungPositions(const int cycle) const
     {
      int count = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket != 0 && PositionSelectByTicket(ticket) && IsOurs() &&
            CycleFromComment(PositionGetString(POSITION_COMMENT)) == cycle)
            count++;
        }
      return count;
     }

   int               FilledCount(const int cycle) const
     {
      if(m_filled_cycle != cycle || m_filled_keys == "")
         return 0;
      int count = 0;
      for(int i = 0; i < StringLen(m_filled_keys); i++)
         if(StringGetCharacter(m_filled_keys, i) == '|')
            count++;
      return count / 2;
     }

   //--- After a restart: every entry deal since the anchor whose comment
   //--- names a rung of `cycle` goes into the set, so a rung that filled and
   //--- was closed by hand before the restart is still not placed again.
   void              RebuildFilled(const long strategy_id, const int cycle, const datetime since)
     {
      m_filled_cycle = cycle;
      m_filled_keys  = "";
      if(since <= 0 || !HistorySelect(since - 60, TimeCurrent() + 60))
         return;
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0 || HistoryDealGetInteger(deal, DEAL_MAGIC) != m_magic)
            continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != m_symbol)
            continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
            continue;
         string comment = HistoryDealGetString(deal, DEAL_COMMENT);
         if(CycleFromComment(comment) != cycle)
            continue;
         NoteFillDeal(strategy_id, deal);
        }
     }

   //--- Our resting order for one rung: by comment first, then — for a
   //--- broker that drops or rewrites comments — by type and price within
   //--- half a point of where the rung belongs. 0 if none rests.
   ulong             FindLadderOrder(const ENUM_POSITION_TYPE side, const string comment, const double price) const
     {
      ENUM_ORDER_TYPE wanted   = StopOrderFor(side);
      double          point    = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      ulong           by_price = 0;

      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket) || !IsOurOrder())
            continue;
         if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != wanted)
            continue;
         if(OrderGetString(ORDER_COMMENT) == comment)
            return ticket;
         if(by_price == 0 && MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) < point / 2.0)
            by_price = ticket;
        }
      return by_price;
     }

   //--- Whether a rung has already filled: one of our open positions OF THAT
   //--- SIDE carries its comment (the broker copies the order comment to the
   //--- position). The side matters: the Buy Stop and the Sell Stop of one
   //--- level share a comment (GG:<id>:C<cycle>:L<level>), so the comment
   //--- alone would make a filled buy rung 1 hide the sell rung 1. For a
   //--- broker that strips comments, a comment-less position of the right
   //--- side opened within half a gap of the rung is taken to be it — a stop
   //--- order fills within points of its price, and no other rung is nearer.
   bool              LadderRungHeld(const ENUM_POSITION_TYPE side, const string comment, const double price,
                                    const int gap_points) const
     {
      double tolerance = gap_points * SymbolInfoDouble(m_symbol, SYMBOL_POINT) / 2.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
            continue;
         if(PositionGetString(POSITION_COMMENT) == comment)
            return true;
         //--- Only a position with NO comment at all: a broker that rewrites
         //--- comments leaves none, while a position that carries another
         //--- comment (a manual trade, a chaos injection) is not a rung.
         if(PositionGetString(POSITION_COMMENT) == "" &&
            MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - price) < tolerance)
            return true;
        }
      return false;
     }

   //--- Rebuilds the cycle number and anchor from what the broker still
   //--- holds, for a restart mid-cycle. Resting ladder orders are the best
   //--- witness: their price is exact. Failing those, a filled rung's open
   //--- price (exact to within slippage) serves. Each side of the anchor is
   //--- derived from its own side's lowest rung when one rests; only a side
   //--- with nothing on the broker is inferred from the other plus the
   //--- current spread. `first_points` is the caller's knowledge of rung 1's
   //--- offset for this cycle (<= 0: compute from today's stop level).
   //--- `since` gets the earliest rung's placing time. Returns false when
   //--- nothing of ours carries a cycle, in which case the caller starts
   //--- afresh.
   bool              RecoverLadder(const SGridStrategy &strategy, const int first_points, int &cycle,
                                   double &anchor_bid, double &anchor_ask, datetime &since) const
     {
      int      best_cycle = 0;
      int      buy_level = 0, sell_level = 0;
      double   ask_from_buys = 0.0, bid_from_sells = 0.0;
      datetime earliest = 0;
      int      gap = strategy.grid_spacing_points;

      //--- Pass 1: the highest cycle number among our orders, else positions.
      for(int pass = 0; pass < 2 && best_cycle == 0; pass++)
        {
         int total = pass == 0 ? OrdersTotal() : PositionsTotal();
         for(int i = total - 1; i >= 0; i--)
           {
            string comment;
            if(pass == 0)
              {
               ulong ticket = OrderGetTicket(i);
               if(ticket == 0 || !OrderSelect(ticket) || !IsOurOrder())
                  continue;
               comment = OrderGetString(ORDER_COMMENT);
              }
            else
              {
               ulong ticket = PositionGetTicket(i);
               if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
                  continue;
               comment = PositionGetString(POSITION_COMMENT);
              }
            int c = CycleFromComment(comment);
            if(c > best_cycle && LevelFromComment(comment) > 0 && StrategyIdFromComment(comment) == strategy.id)
               best_cycle = c;
           }
        }
      if(best_cycle == 0)
         return false;

      //--- Pass 2: for that cycle, the lowest rung on each side, orders first
      //--- (exact) and positions only for a side with no order resting.
      for(int pass = 0; pass < 2; pass++)
        {
         int total = pass == 0 ? OrdersTotal() : PositionsTotal();
         for(int i = total - 1; i >= 0; i--)
           {
            string comment; bool buy; double price; datetime placed;
            if(pass == 0)
              {
               ulong ticket = OrderGetTicket(i);
               if(ticket == 0 || !OrderSelect(ticket) || !IsOurOrder())
                  continue;
               comment = OrderGetString(ORDER_COMMENT);
               buy     = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_STOP;
               price   = OrderGetDouble(ORDER_PRICE_OPEN);
               placed  = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
              }
            else
              {
               ulong ticket = PositionGetTicket(i);
               if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
                  continue;
               comment = PositionGetString(POSITION_COMMENT);
               buy     = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
               price   = PositionGetDouble(POSITION_PRICE_OPEN);
               placed  = (datetime)PositionGetInteger(POSITION_TIME);
              }
            if(CycleFromComment(comment) != best_cycle || StrategyIdFromComment(comment) != strategy.id)
               continue;
            int level = LevelFromComment(comment);
            if(level <= 0)
               continue;
            if(earliest == 0 || placed < earliest)
               earliest = placed;

            double offset = LadderOffset(gap, first_points, level);
            if(buy)
              {
               //--- An order beats a position (pass 0 before pass 1); within
               //--- a pass the lowest level, whose offset depends least on
               //--- the gap.
               if(buy_level == 0 || (pass == 0 && level < buy_level) ||
                  (pass == 1 && buy_level < 0 && level < -buy_level))
                 {
                  ask_from_buys = price - offset;
                  buy_level     = pass == 0 ? level : -level;
                 }
              }
            else
              {
               if(sell_level == 0 || (pass == 0 && level < sell_level) ||
                  (pass == 1 && sell_level < 0 && level < -sell_level))
                 {
                  bid_from_sells = price + offset;
                  sell_level     = pass == 0 ? level : -level;
                 }
              }
           }
         //--- A side witnessed by an order is final; positions are only
         //--- consulted for a side with no order.
         if(pass == 0)
           {
            if(buy_level > 0 && sell_level > 0)
               break;
           }
        }

      double spread = MathMax(SymbolInfoDouble(m_symbol, SYMBOL_ASK) - SymbolInfoDouble(m_symbol, SYMBOL_BID), 0.0);
      if(buy_level != 0 && sell_level == 0)  bid_from_sells = ask_from_buys - spread;
      if(sell_level != 0 && buy_level == 0)  ask_from_buys  = bid_from_sells + spread;

      int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      cycle      = best_cycle;
      anchor_bid = NormalizeDouble(bid_from_sells, digits);
      anchor_ask = NormalizeDouble(ask_from_buys, digits);
      since      = earliest;
      return anchor_bid > 0.0 && anchor_ask > 0.0;
     }

   //--- LADDER HYGIENE. A grid rests ladder orders of the current cycle and
   //--- nothing else. Any order of ours that is not one — a previous
   //--- cycle's leftover, a rung sent twice, an order without a ladder
   //--- comment — is deleted, so no rung can ever fill twice. Returns how
   //--- many went.
   int               DeleteLadderStrays(const SGridStrategy &strategy, const int cycle)
     {
      ulong  doomed[];
      string seen = "|";

      for(int i = 0; i < OrdersTotal(); i++)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket) || !IsOurOrder())
            continue;

         string comment = OrderGetString(ORDER_COMMENT);
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         int    level = LevelFromComment(comment);
         bool   keep  = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP) &&
                        StrategyIdFromComment(comment) == strategy.id &&
                        CycleFromComment(comment) == cycle && level > 0 &&
                        level <= (type == ORDER_TYPE_BUY_STOP ? strategy.grid_buy_orders : strategy.grid_sell_orders);
         if(keep)
           {
            string key = StringFormat("%s%d|", type == ORDER_TYPE_BUY_STOP ? "B" : "S", level);
            if(StringFind(seen, "|" + key) >= 0)
               keep = false;              // the same rung twice
            else
               seen += key;
           }

         if(!keep)
           {
            int n = ArraySize(doomed);
            ArrayResize(doomed, n + 1);
            doomed[n] = ticket;
           }
        }

      int deleted = 0;
      for(int i = 0; i < ArraySize(doomed); i++)
        {
         if(m_trade.OrderDelete(doomed[i]))
           {
            deleted++;
            PrintFormat("GoldGrid: deleted order #%I64u — not a rung of ladder cycle %d", doomed[i], cycle);
           }
         else
            Complain(m_trade.ResultRetcode(),
                     StringFormat("GoldGrid: could not delete order #%I64u — %s (%d)",
                                  doomed[i], m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
        }
      return deleted;
     }

   //--- One pass over the ladder. Rungs are visited nearest-first, buy and
   //--- sell alternating, so a ladder cut short by the capacity or by the
   //--- request budget is balanced around the market. Each rung is left
   //--- alone if it rests or has filled, skipped (and said so once) if the
   //--- market has crossed it, and otherwise placed — through the risk gate,
   //--- at most `max_requests` per pass so one pass never floods the broker.
   //--- Returns true when nothing remains to place.
   bool              PlaceLadder(const SGridStrategy &strategy, const bool config_is_fresh, const int cycle,
                                 const double anchor_bid, const double anchor_ask, const int first_points,
                                 const int max_requests, SLadderReport &report)
     {
      report.Reset();
      if(m_ladder_notes_cycle != cycle)
        {
         m_ladder_notes_cycle = cycle;
         m_ladder_notes = "";
        }

      report.capacity = LadderCapacity(strategy, cycle);

      double point       = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int    digits      = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double stops_level = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      double bid         = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask         = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double lot         = EntryLot(strategy, m_symbol);
      int    rungs       = MathMax(strategy.grid_buy_orders, strategy.grid_sell_orders);
      int    requests    = 0;
      int    slots       = 0;

      for(int level = 1; level <= rungs; level++)
        {
         for(int s = 0; s < 2; s++)
           {
            ENUM_POSITION_TYPE side = (s == 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
            if(level > (side == POSITION_TYPE_BUY ? strategy.grid_buy_orders : strategy.grid_sell_orders))
               continue;
            if(slots >= report.capacity)
              {
               report.complete = true;
               return true;
              }
            slots++;

            string comment = LadderComment(strategy.id, cycle, level);
            double price   = LadderPrice(side, level, strategy.grid_spacing_points, first_points, anchor_bid, anchor_ask);

            if(FindLadderOrder(side, comment, price) != 0) { report.resting++; continue; }
            //--- Filled this cycle — open, or closed since by anything other
            //--- than the cycle's own close (D6). Never placed again.
            if(RungFilled(cycle, side, level) ||
               LadderRungHeld(side, comment, price, strategy.grid_spacing_points))
                                                            { report.held++;    continue; }

            //--- The market is past this rung (or inside the broker's stop
            //--- distance of it): a stop order there would be rejected, and
            //--- the anchor does not move. Said once; the rung stays empty
            //--- for the rest of the cycle. Judged on the price NOW: a pass
            //--- of synchronous sends lasts about two seconds, and a price
            //--- read at its start is stale by its end.
            bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
            ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
            bool crossed = (side == POSITION_TYPE_BUY) ? price <= ask + stops_level : price >= bid - stops_level;
            if(crossed)
              {
               report.skipped++;
               string key = StringFormat("|%s%d|", side == POSITION_TYPE_BUY ? "B" : "S", level);
               if(StringFind(m_ladder_notes, key) < 0)
                 {
                  m_ladder_notes += key;
                  PrintFormat("GoldGrid: ladder %s rung %d at %s skipped — the market (%s/%s) is already past it",
                              side == POSITION_TYPE_BUY ? "BUY" : "SELL", level, DoubleToString(price, digits),
                              DoubleToString(bid, digits), DoubleToString(ask, digits));
                 }
               continue;
              }

            if(requests >= max_requests)
               return false;             // the rest on the next pass

            //--- Each send waits for the broker (~200 ms), and nothing else
            //--- runs meanwhile — the basket monitor included. A rung that
            //--- filled while this pass ran can take the basket to its exit;
            //--- the pass stops there, and the monitor closes it on the very
            //--- next tick instead of after the rest of the pass.
            if(requests > 0 && TotalPositions() > 0)
              {
               SBasket basket_now = CombinedBasket();
               if(BasketExitReason(strategy, basket_now) != "")
                  return false;
              }

            string reason;
            if(!MayOpen(strategy, config_is_fresh, lot, side, reason, true))
              {
               report.refused = reason;
               return false;
              }

            requests++;
            report.requests++;
            bool ok = (side == POSITION_TYPE_BUY)
                      ? m_trade.BuyStop(lot, price, m_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, comment)
                      : m_trade.SellStop(lot, price, m_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, comment);
            if(!ok)
              {
               //--- Reported as a refusal so the caller paces the retry: a
               //--- broker that rejects deterministically (price inside its
               //--- stop level, a server-side order limit, no margin for the
               //--- pending order) would otherwise see the same request on
               //--- every tick.
               report.refused = StringFormat("the broker rejected %s rung %d at %s — %s (%d)",
                                             side == POSITION_TYPE_BUY ? "buy" : "sell", level,
                                             DoubleToString(price, digits),
                                             m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode());
               Complain(m_trade.ResultRetcode(), "GoldGrid: ladder " + report.refused);
               return false;             // retried next pass
              }
            report.placed++;
            PrintFormat("GoldGrid: placed ladder %s rung %d, %.2f lots at %s (cycle %d)",
                        side == POSITION_TYPE_BUY ? "BUY" : "SELL", level, lot, DoubleToString(price, digits), cycle);
           }
        }

      report.complete = true;
      return true;
     }

   //+---------------------------------------------------------------+
   //| THE COMBINED BASKET (grid strategy).                           |
   //|                                                                |
   //| Every open position of ours, buys and sells together, is one   |
   //| basket with one exit: its combined floating profit — net of    |
   //| swap and commission — reaching the target. (A basket stop loss |
   //| is optional, D3.) Resting orders have no profit and take no    |
   //| part in the decision; they are cancelled when the basket       |
   //| closes.                                                        |
   //+---------------------------------------------------------------+
   SBasket           CombinedBasket(void)
     {
      SBasket basket;
      basket.count = 0;
      basket.volume = 0.0;
      basket.profit = 0.0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         basket.count++;
         basket.volume += PositionGetDouble(POSITION_VOLUME);
         basket.profit += PositionGetDouble(POSITION_PROFIT)
                        + PositionGetDouble(POSITION_SWAP)
                        + CachedCommission(PositionGetInteger(POSITION_IDENTIFIER));
        }
      if(basket.count == 0)
        {
         ArrayResize(m_commission_ids, 0);
         ArrayResize(m_commission_values, 0);
        }
      return basket;
     }

   double            CachedCommission(const long position_id)
     {
      for(int i = 0; i < ArraySize(m_commission_ids); i++)
         if(m_commission_ids[i] == position_id)
            return m_commission_values[i];
      double commission = PositionCommission(position_id);
      int n = ArraySize(m_commission_ids);
      ArrayResize(m_commission_ids, n + 1);
      ArrayResize(m_commission_values, n + 1);
      m_commission_ids[n]    = position_id;
      m_commission_values[n] = commission;
      return commission;
     }

   //--- Why the basket must close now, or "" to keep holding. The target is
   //--- checked first: a basket exactly at both (impossible with sane
   //--- settings) closes as a win.
   string            BasketExitReason(const SGridStrategy &strategy, const SBasket &basket) const
     {
      if(basket.count == 0)
         return "";
      if(strategy.has_basket_take_profit && basket.profit >= strategy.basket_take_profit)
         return StringFormat("combined profit %.2f reached the %.2f target", basket.profit, strategy.basket_take_profit);
      if(strategy.has_basket_stop_loss && basket.profit <= -strategy.basket_stop_loss)
         return StringFormat("combined loss %.2f reached the %.2f basket stop loss", basket.profit, strategy.basket_stop_loss);
      return "";
     }

   //--- Deletes every resting order of ours, whatever its type. Returns how
   //--- many went; a failure is logged (rate-limited) and retried by the
   //--- caller's next pass.
   //--- `parallel`: every cancel sent at once (OrderSendAsync), as for the
   //--- basket's closes. A 50-rung ladder cancelled one reply at a time
   //--- takes seconds, during which a rung can still fill.
   int               DeleteAllOrders(const bool parallel = false)
     {
      ulong doomed[];
      for(int i = 0; i < OrdersTotal(); i++)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket) || !IsOurOrder())
            continue;
         int n = ArraySize(doomed);
         ArrayResize(doomed, n + 1);
         doomed[n] = ticket;
        }

      int deleted = 0;
      if(parallel)
         m_trade.SetAsyncMode(true);
      for(int i = 0; i < ArraySize(doomed); i++)
        {
         if(m_trade.OrderDelete(doomed[i]))
            deleted++;
         else
            Complain(m_trade.ResultRetcode(),
                     StringFormat("GoldGrid: could not cancel order #%I64u — %s (%d)",
                                  doomed[i], m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
        }
      if(parallel)
         m_trade.SetAsyncMode(false);
      return deleted;
     }

   //--- Starts a basket close: enters the protected closing state, forgets
   //--- the previous close's positions and requests, and notes the ones
   //--- open now.
   void              BeginBasketClose(void)
     {
      m_closing = true;
      ArrayResize(m_closing_tickets, 0);
      ArrayResize(m_closing_ids, 0);
      ArrayResize(m_requests, 0);
      NoteOpenPositions();
     }

   //--- Leaves the protected closing state: the basket is confirmed flat.
   void              EndBasketClose(void)
     {
      m_closing = false;
      ArrayResize(m_requests, 0);
     }

   bool              IsClosing(void) const { return m_closing; }

   //--- Adds every open position of ours not yet on the closing list. Called
   //--- on each close pass, so a rung that fills while the basket is being
   //--- closed is closed and accounted for too.
   void              NoteOpenPositions(void)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         bool known = false;
         for(int k = 0; k < ArraySize(m_closing_tickets) && !known; k++)
            known = m_closing_tickets[k] == ticket;
         if(known)
            continue;
         int n = ArraySize(m_closing_tickets);
         ArrayResize(m_closing_tickets, n + 1);
         ArrayResize(m_closing_ids, n + 1);
         m_closing_tickets[n] = ticket;
         m_closing_ids[n]     = PositionGetInteger(POSITION_IDENTIFIER);
        }
     }

   int               ClosingPositions(void) const { return ArraySize(m_closing_tickets); }

   //--- The broker's answer to one of the close's requests, from
   //--- OnTradeTransaction (or the terminal's own refusal at the call).
   //--- Decides when that ticket may be sent again.
   void              NoteCloseOutcome(const ulong ticket, const bool is_order, const uint code)
     {
      if(!m_closing || ticket == 0)
         return;
      int i = TrackRequest(ticket, is_order);
      ulong now = ClockMs();

      if(code == TRADE_RETCODE_DONE || code == TRADE_RETCODE_PLACED || code == TRADE_RETCODE_POSITION_CLOSED)
        {
         m_requests[i].due_at = now + BASKET_CONFIRM_WAIT_MS;
         return;
        }
      //--- Part of the volume closed: the rest goes on the next pass.
      if(code == TRADE_RETCODE_DONE_PARTIAL)
        {
         m_requests[i].due_at = now;
         return;
        }

      m_requests[i].rejections++;
      bool transient = code == TRADE_RETCODE_REQUOTE || code == TRADE_RETCODE_PRICE_CHANGED ||
                       code == TRADE_RETCODE_PRICE_OFF || code == TRADE_RETCODE_FROZEN ||
                       code == TRADE_RETCODE_TIMEOUT || code == TRADE_RETCODE_LOCKED ||
                       code == TRADE_RETCODE_CONNECTION || code == TRADE_RETCODE_REJECT;
      m_requests[i].due_at = now + (transient && m_requests[i].rejections <= BASKET_FAST_RETRIES_MAX
                                    ? BASKET_FAST_RETRY_MS : BASKET_RESEND_MS);
     }

   //--- One pass of the close. Sends only what is due — a ticket whose
   //--- request is still executing is left alone (see SCloseRequest) — so it
   //--- runs on every tick, timer and transaction without flooding the
   //--- broker. In this order, all asynchronously:
   //---
   //---   1. cancels for the orders IN REACH: the nearest
   //---      BASKET_NEAR_ORDERS_PER_SIDE on each side. Price has to cross
   //---      those before any other, so they are the only orders that can
   //---      fill while the closes execute.
   //---   2. every close.
   //---   3. cancels for every other order.
   //---
   //--- The broker works through requests in the order they arrive. Closes
   //--- first (as before) put the cancels behind every close, so a basket of
   //--- 16 left the nearest rung live for all 16 executions — exactly while
   //--- the price that carried the basket to its target kept moving into it.
   //--- Cancels first put 40 resting orders ahead of the closes. Two per side
   //--- costs the closes two cancels, and takes away the only rungs that
   //--- could still fill. A rung that fills anyway is closed the moment its
   //--- fill arrives (OnTradeTransaction) and on every pass after.
   //---
   //--- Returns how many closes could not be sent; `closes` and `cancelled`
   //--- get how many requests went.
   int               CloseBasketPass(const string why, int &closes, int &cancelled)
     {
      m_closing = true;   // also after a restart that found the record CLOSING
      NoteOpenPositions();
      closes    = 0;
      cancelled = 0;
      int failed = 0;

      ulong orders[];
      bool  buys[];
      OrdersByReach(orders, buys);
      int  n = ArraySize(orders);
      bool sent_early[];
      ArrayResize(sent_early, n);
      ArrayInitialize(sent_early, false);

      m_trade.SetAsyncMode(true);

      int near_buy = 0, near_sell = 0;
      for(int i = 0; i < n; i++)
        {
         if((buys[i] ? near_buy : near_sell) >= BASKET_NEAR_ORDERS_PER_SIDE)
            continue;
         if(buys[i]) near_buy++; else near_sell++;
         sent_early[i] = true;
         if(SendCancel(orders[i]))
            cancelled++;
        }

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         int sent = SendClose(ticket, why);
         if(sent > 0)
            closes++;
         else if(sent < 0)
            failed++;
        }

      for(int i = 0; i < n; i++)
         if(!sent_early[i] && SendCancel(orders[i]))
            cancelled++;

      m_trade.SetAsyncMode(false);
      return failed;
     }

   //--- A rung that filled while the basket is closing: its close goes out
   //--- now, from the fill's transaction, not on the next pass.
   void              CloseFillNow(const ulong ticket, const string why)
     {
      NoteOpenPositions();
      m_trade.SetAsyncMode(true);
      SendClose(ticket, why);
      m_trade.SetAsyncMode(false);
     }

   //--- Positions of ours that are rungs of a cycle EARLIER than `cycle`:
   //--- an order of the closed basket that filled after its cancel was sent,
   //--- or that the order list had not shown yet. An entry nobody decided on
   //--- — the closed cycle's target is already banked — so it is closed at
   //--- once rather than left to the next basket. Returns how many closed.
   int               CloseStaleRungs(const long strategy_id, const int cycle)
     {
      ulong doomed[];
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurs())
            continue;
         string comment = PositionGetString(POSITION_COMMENT);
         int    c       = CycleFromComment(comment);
         if(c <= 0 || c >= cycle || LevelFromComment(comment) <= 0 || StrategyIdFromComment(comment) != strategy_id)
            continue;
         int n = ArraySize(doomed);
         ArrayResize(doomed, n + 1);
         doomed[n] = ticket;
        }

      int closed = 0;
      for(int i = 0; i < ArraySize(doomed); i++)
         if(ClosePosition(doomed[i], "a rung of an earlier cycle filled after its basket closed"))
            closed++;
      return closed;
     }

   //--- TRULY FLAT: nothing of ours open, nothing of ours resting, and every
   //--- position the close was accountable for confirmed closed in the deal
   //--- history — the same standard as PositionConfirmedClosed, applied to
   //--- the whole basket. An open list that merely lags a fill is not flat.
   bool              BasketConfirmedFlat(void) const
     {
      if(TotalPositions() > 0 || OurOrders() > 0)
         return false;
      for(int i = 0; i < ArraySize(m_closing_tickets); i++)
         if(!PositionConfirmedClosed(m_closing_tickets[i], m_closing_ids[i]))
            return false;
      return true;
     }

   //--- What the closed basket made, from the broker's deal history: the
   //--- closing deals' profit, swap and commission for every position the
   //--- close was accountable for. (Opening deals carry the entry commission,
   //--- which is counted too.)
   double            ClosedBasketProfit(void) const
     {
      double total = 0.0;
      for(int i = 0; i < ArraySize(m_closing_ids); i++)
        {
         long id = m_closing_ids[i] > 0 ? m_closing_ids[i] : (long)m_closing_tickets[i];
         if(!HistorySelectByPosition(id))
            continue;
         for(int k = HistoryDealsTotal() - 1; k >= 0; k--)
           {
            ulong deal = HistoryDealGetTicket(k);
            if(deal == 0)
               continue;
            total += HistoryDealGetDouble(deal, DEAL_PROFIT)
                   + HistoryDealGetDouble(deal, DEAL_SWAP)
                   + HistoryDealGetDouble(deal, DEAL_COMMISSION);
           }
        }
      return total;
     }

   //+---------------------------------------------------------------+
   //| THE TRAILING EXIT (reversal strategy).                         |
   //|                                                                |
   //| The open position's exit is one price, held by the broker in   |
   //| two forms:                                                     |
   //|                                                                |
   //|   * the position's own STOP LOSS, which closes it, and         |
   //|   * a STOP ORDER for the other side at the same price, which   |
   //|     opens the reversal.                                        |
   //|                                                                |
   //| Both trigger on the same quote (a buy's stop loss and a sell   |
   //| stop on the bid, a sell's stop loss and a buy stop on the ask),|
   //| so at the exit price the broker closes the old position and    |
   //| opens the new one on the same tick. Nothing waits for this EA: |
   //| not a busy terminal, not a slow platform call, not a terminal  |
   //| that is offline. Before, the position had no stop loss and was |
   //| only closed once the EA saw the reversal fill — seconds later  |
   //| when the terminal was busy, hours later when it was offline.   |
   //|                                                                |
   //| Gold at $2,000, a buy, a 300-point ($3) distance:              |
   //|                                                                |
   //|   buy opens at 2000  ->  exit (SL + sell stop) at 1997         |
   //|   price reaches 2010 ->  exit moved to 2007                    |
   //|   price falls to 2008 -> exit stays at 2007                    |
   //|   price falls to 2007 -> buy closed, sell opened: the reversal |
   //|                                                                |
   //| THE RATCHET: the exit only ever moves towards the market. It   |
   //| starts from the tighter of the position's stop loss and the    |
   //| resting order, so neither can ever be moved back.              |
   //|                                                                |
   //| `reverse` false keeps the stop loss only and withdraws the     |
   //| order: the position still exits at the same price, flat.       |
   //| Returns true if the position's stop loss is at the exit.       |
   //+---------------------------------------------------------------+
   bool              TrailReversalExit(const SGridStrategy &strategy, const ENUM_POSITION_TYPE held,
                                       const ulong ticket, const double lot, const string comment,
                                       const bool reverse)
     {
      if(strategy.trailing_stop_points <= 0 || TradingGate() != GATE_OPEN)
         return false;
      if(!PositionSelectByTicket(ticket))
         return false;

      double point  = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double bid    = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(point <= 0.0 || bid <= 0.0 || ask <= 0.0)
         return false;

      bool   is_buy  = held == POSITION_TYPE_BUY;
      double stop    = PositionGetDouble(POSITION_SL);
      double take    = PositionGetDouble(POSITION_TP);
      double minimum = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      double freeze  = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point;
      double distance = ExitDistance(strategy);
      double step     = MathMax(strategy.trailing_step_points, 1) * point;

      //--- A buy closes at the bid, a sell at the ask; the exit trails that.
      double market  = is_buy ? bid : ask;
      double desired = NormalizeDouble(is_buy ? bid - distance : ask + distance, digits);

      ENUM_POSITION_TYPE opposite = is_buy ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
      ulong  existing = FindPendingStop(opposite);
      double resting  = (existing != 0 && OrderSelect(existing)) ? OrderGetDouble(ORDER_PRICE_OPEN) : 0.0;

      //--- Where the exit already is: the tighter of the two.
      double exit = stop;
      if(resting > 0.0 && (exit <= 0.0 || (is_buy ? resting > exit : resting < exit)))
         exit = resting;
      bool moved = exit <= 0.0 || (is_buy ? desired - exit >= step : exit - desired >= step);
      if(moved)
         exit = desired;
      exit = NormalizeDouble(exit, digits);

      //--- 1. The stop loss — the part that closes the position. Inside the
      //--- broker's freeze or minimum distance it cannot be changed; the
      //--- position is about to reach its exit anyway.
      bool stop_at_exit = stop > 0.0 && MathAbs(stop - exit) < point / 2.0;
      bool modifiable   = (is_buy ? market - exit : exit - market) >= minimum &&
                          (freeze <= 0.0 || MathAbs(market - exit) >= freeze);
      if(!stop_at_exit && modifiable)
        {
         if(m_trade.PositionModify(ticket, exit, take))
           {
            stop_at_exit = true;
            if(stop <= 0.0)
               PrintFormat("GoldGrid: %s #%I64u stop loss set at %s — the broker closes it there",
                           is_buy ? "BUY" : "SELL", ticket, DoubleToString(exit, digits));
           }
         else
            Complain(m_trade.ResultRetcode(),
                     StringFormat("GoldGrid: could not set the stop loss of #%I64u to %s — %s (%d)",
                                  ticket, DoubleToString(exit, digits),
                                  m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode()));
        }

      //--- 2. The stop order — the part that opens the reversal, at the same
      //--- price, carrying the new position's first stop loss.
      if(!reverse)
        {
         if(existing != 0)
            DeletePendingStops(opposite);
        }
      else
        {
         double resting_sl = existing != 0 && OrderSelect(existing) ? OrderGetDouble(ORDER_SL) : 0.0;
         bool   in_place   = existing != 0 && MathAbs(resting - exit) < point / 2.0 && resting_sl > 0.0;
         bool   frozen     = existing != 0 && freeze > 0.0 && MathAbs(market - resting) < freeze;
         if(!in_place && !frozen && modifiable)
           {
            double new_sl = EntryStopLoss(opposite, exit, distance);
            if(existing == 0)
              {
               if(PlacePendingStop(opposite, lot, exit, comment, new_sl))
                  PrintFormat("GoldGrid: the %s reverses to %s at %s", is_buy ? "BUY" : "SELL",
                              is_buy ? "SELL" : "BUY", DoubleToString(exit, digits));
              }
            else
               PlacePendingStop(opposite, lot, exit, comment, new_sl);
           }
        }

      if(moved && stop > 0.0 && stop_at_exit && !IsTester())
         PrintFormat("GoldGrid: exit moved to %s (%s behind %s)", DoubleToString(exit, digits),
                     DoubleToString(distance, digits), DoubleToString(market, digits));
      return stop_at_exit;
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

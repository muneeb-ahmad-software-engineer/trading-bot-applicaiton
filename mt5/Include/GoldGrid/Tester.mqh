//+------------------------------------------------------------------+
//| Tester.mqh                                                        |
//| Strategy Tester support: a configuration built from inputs (the   |
//| tester cannot reach the platform — WebRequest is unavailable      |
//| there), an invariant monitor that checks the refactor's           |
//| acceptance criteria on every tick, and a chaos engine that        |
//| injects the failure cases the criteria are about.                 |
//|                                                                   |
//| None of this runs outside the tester.                             |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_TESTER_MQH
#define GOLDGRID_TESTER_MQH

#include <Trade/Trade.mqh>
#include "Strategy.mqh"

enum ENUM_TEST_CATEGORY { TEST_GRID, TEST_TRAILING, TEST_REVERSAL };

//+------------------------------------------------------------------+
//| The strategy the tester runs, from the EA's tester inputs.        |
//+------------------------------------------------------------------+
void BuildTesterStrategy(SGridStrategy &out, const ENUM_TEST_CATEGORY category, const double lot,
                         const int trailing_points, const int step_points, const int entry_points,
                         const int max_spread_points, const double max_daily_loss,
                         const int grid_spacing_points, const int grid_levels)
  {
   out.loaded   = true;
   out.id       = 0;
   out.name     = "Strategy Tester";
   out.symbol   = _Symbol;
   out.status   = "running";
   out.category = category == TEST_GRID ? CATEGORY_GRID
                : category == TEST_TRAILING ? CATEGORY_TRAILING : CATEGORY_REVERSAL;
   out.direction = GRID_BOTH;

   out.grid_spacing_points = grid_spacing_points;
   out.grid_levels         = category == TEST_GRID ? grid_levels : 0;
   out.initial_lot         = lot;
   out.lot_mode            = LOT_FIXED;
   out.lot_multiplier      = 1.0;

   out.has_trailing               = trailing_points > 0;
   out.trailing_stop_points       = trailing_points;
   out.has_trailing_activation    = false;
   out.trailing_activation_points = 0;
   out.trailing_step_points       = MathMax(1, MathMin(step_points, trailing_points));
   out.entry_distance_points      = entry_points > 0 ? entry_points : trailing_points;

   out.has_basket_take_profit = false;
   out.basket_take_profit     = 0.0;
   out.has_basket_stop_loss   = false;
   out.basket_stop_loss       = 0.0;

   out.max_positions        = category == TEST_GRID ? MathMax(grid_levels * 2, 1) : 1;
   out.max_exposure_lots    = 1000.0;
   out.has_max_drawdown     = false;
   out.max_drawdown_percent = 0.0;
   out.has_min_margin_level = false;
   out.min_margin_level_percent = 0.0;
   out.has_max_spread       = max_spread_points > 0;
   out.max_spread_points    = max_spread_points;
   out.has_max_daily_loss   = max_daily_loss > 0.0;
   out.max_daily_loss       = max_daily_loss;
   out.emergency_stop       = false;
   out.config_version       = "tester";
   out.fetched_at           = ClockMs();
  }

//+------------------------------------------------------------------+
//| THE INVARIANT MONITOR.                                            |
//|                                                                   |
//| Checks the acceptance criteria of trailing-strategy-refactoring.md|
//| for a single-position strategy, and counts every breach:          |
//|   1. never more than one position (so never a buy and a sell)     |
//|   2. no pending order rests while a position is open (the OCO)    |
//|   3. never more than one pending stop per side                    |
//|   4. a position's stop never moves backwards                      |
//|                                                                   |
//| A breach the chaos engine caused on purpose is expected: what is  |
//| tested is that the EA repairs it within the grace period. A       |
//| breach nobody injected is a violation the moment it is seen.      |
//+------------------------------------------------------------------+
class CInvariantMonitor
  {
private:
   long              m_magic;
   string            m_symbol;

   ulong             m_injected_at;       // last deliberate breach by the chaos engine
   ulong             m_breach_since;
   bool              m_breach_reported;
   ulong             m_pending_open_since;
   ulong             m_duplicate_since;

   ulong             m_sl_tickets[];
   double            m_sl_levels[];

   void              Violation(const string what)
     {
      violations++;
      PrintFormat("GoldGrid: INVARIANT VIOLATION #%d — %s", violations, what);
     }

   bool              Ours(void) const
     {
      return PositionGetInteger(POSITION_MAGIC) == m_magic && PositionGetString(POSITION_SYMBOL) == m_symbol;
     }

   //--- Criterion 4, per position: remembers each stop and flags any move
   //--- in the unfavourable direction.
   void              CheckStop(const ulong ticket, const ENUM_POSITION_TYPE type, const double stop)
     {
      if(stop <= 0.0)
         return;
      for(int i = 0; i < ArraySize(m_sl_tickets); i++)
        {
         if(m_sl_tickets[i] != ticket)
            continue;
         double previous = m_sl_levels[i];
         bool backwards = (type == POSITION_TYPE_BUY) ? stop < previous - _Point / 2.0
                                                      : stop > previous + _Point / 2.0;
         if(backwards)
            Violation(StringFormat("stop of #%I64u moved backwards, %s -> %s", ticket,
                                   DoubleToString(previous, _Digits), DoubleToString(stop, _Digits)));
         m_sl_levels[i] = stop;
         return;
        }
      int n = ArraySize(m_sl_tickets);
      ArrayResize(m_sl_tickets, n + 1);
      ArrayResize(m_sl_levels, n + 1);
      m_sl_tickets[n] = ticket;
      m_sl_levels[n]  = stop;
     }

public:
   int               violations;
   int               max_positions;
   int               breaches_injected;
   int               breaches_seen;      // times more than one position was actually open
   int               breaches_repaired;
   int               checks;

   //--- What the market did over the run, for comparing periods.
   double            first_bid;
   double            last_bid;
   double            high_bid;
   double            low_bid;

                     CInvariantMonitor(void)
     {
      m_magic = 0;
      m_injected_at = 0;
      m_breach_since = 0;
      m_breach_reported = false;
      m_pending_open_since = 0;
      m_duplicate_since = 0;
      violations = 0;
      max_positions = 0;
      breaches_injected = 0;
      breaches_seen = 0;
      breaches_repaired = 0;
      checks = 0;
      first_bid = 0.0;
      last_bid = 0.0;
      high_bid = 0.0;
      low_bid = 0.0;
     }

   void              Configure(const long magic, const string symbol) { m_magic = magic; m_symbol = symbol; }

   //--- A breach detected by a check outside this class.
   void              Fail(const string what) { Violation(what); }

   //--- The chaos engine calls this just before it breaks something on purpose.
   void              ExpectBreach(void) { m_injected_at = ClockMs(); breaches_injected++; }

   void              Check(void)
     {
      checks++;
      ulong now = ClockMs();
      int   positions = 0;

      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      if(bid > 0.0)
        {
         if(first_bid == 0.0) { first_bid = bid; high_bid = bid; low_bid = bid; }
         last_bid = bid;
         high_bid = MathMax(high_bid, bid);
         low_bid  = MathMin(low_bid, bid);
        }

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket) || !Ours())
            continue;
         positions++;
         CheckStop(ticket, (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_SL));
        }
      if(positions > max_positions)
         max_positions = positions;

      int buy_stops = 0, sell_stops = 0, others = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket))
            continue;
         if(OrderGetInteger(ORDER_MAGIC) != m_magic || OrderGetString(ORDER_SYMBOL) != m_symbol)
            continue;
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type == ORDER_TYPE_BUY_STOP)       buy_stops++;
         else if(type == ORDER_TYPE_SELL_STOP) sell_stops++;
         else                                  others++;
        }

      bool injected_recently = m_injected_at > 0 && now - m_injected_at < 60000;

      //--- 1. One position.
      if(positions > 1)
        {
         if(m_breach_since == 0)
           {
            m_breach_since = now;
            m_breach_reported = false;
            breaches_seen++;
            if(!injected_recently)
              {
               Violation(StringFormat("%d positions open, not injected", positions));
               m_breach_reported = true;
              }
           }
         else if(!m_breach_reported && now - m_breach_since > 60000)
           {
            Violation(StringFormat("injected breach (%d positions) not repaired within 60 s", positions));
            m_breach_reported = true;
           }
        }
      else if(m_breach_since > 0)
        {
         if(!m_breach_reported)
            breaches_repaired++;
         m_breach_since = 0;
        }

      //--- 2. Nothing rests while a position is open. A fill and the cancel of
      //--- its partner are one transaction apart, so a few seconds are allowed.
      if(positions > 0 && buy_stops + sell_stops + others > 0)
        {
         if(m_pending_open_since == 0)
            m_pending_open_since = now;
         else if(now - m_pending_open_since > 5000)
           {
            Violation(StringFormat("%d pending order(s) resting beside an open position",
                                   buy_stops + sell_stops + others));
            m_pending_open_since = 0;
           }
        }
      else
         m_pending_open_since = 0;

      //--- 3. One stop per side, nothing else.
      if(buy_stops > 1 || sell_stops > 1 || others > 0)
        {
         if(m_duplicate_since == 0)
            m_duplicate_since = now;
         else if(now - m_duplicate_since > 5000)
           {
            Violation(StringFormat("stray/duplicate pending orders: %d buy stop(s), %d sell stop(s), %d other",
                                   buy_stops, sell_stops, others));
            m_duplicate_since = 0;
           }
        }
      else
         m_duplicate_since = 0;
     }
  };

//+------------------------------------------------------------------+
//| THE CHAOS ENGINE. On a seeded schedule, one of:                   |
//+------------------------------------------------------------------+
enum ENUM_CHAOS_EVENT
  {
   CHAOS_NONE,
   CHAOS_MANUAL_CLOSE,     // someone closes the position by hand: must NOT reverse
   CHAOS_EXTRA_POSITION,   // a second position appears: RECOVERY must repair it
   CHAOS_DUPLICATE_ORDER,  // a stray pending order appears: must be deleted
   CHAOS_RESTART,          // the EA restarts mid-flight: must reconcile, not guess
   CHAOS_TICK_STORM        // the same tick delivered many times: nothing may double
  };

string ChaosName(const ENUM_CHAOS_EVENT event)
  {
   switch(event)
     {
      case CHAOS_MANUAL_CLOSE:    return "manual close";
      case CHAOS_EXTRA_POSITION:  return "extra position";
      case CHAOS_DUPLICATE_ORDER: return "duplicate pending order";
      case CHAOS_RESTART:         return "EA restart";
      case CHAOS_TICK_STORM:      return "tick storm";
     }
   return "none";
  }

class CChaosEngine
  {
private:
   CTrade            m_trade;
   long              m_magic;
   string            m_symbol;
   int               m_every_seconds;
   datetime          m_next_at;

   ulong             OurPosition(ENUM_POSITION_TYPE &type) const
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic || PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         return ticket;
        }
      return 0;
     }

public:
   int               counts[6];
   ulong             manual_close_at;

                     CChaosEngine(void)
     {
      m_magic = 0;
      m_every_seconds = 0;
      m_next_at = 0;
      manual_close_at = 0;
      ArrayInitialize(counts, 0);
     }

   void              Configure(const long magic, const string symbol, const int every_minutes, const int seed)
     {
      m_magic  = magic;
      m_symbol = symbol;
      m_every_seconds = every_minutes * 60;
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetTypeFillingBySymbol(symbol);
      MathSrand(seed);
     }

   bool              Enabled(void) const { return m_every_seconds > 0; }

   int               Total(void) const
     {
      int total = 0;
      for(int i = 1; i < 6; i++)
         total += counts[i];
      return total;
     }

   //--- Which event is due now, if any. The trade-side events are carried
   //--- out here; restart and tick storm need the EA's own state, so the
   //--- caller performs those.
   ENUM_CHAOS_EVENT  Due(CInvariantMonitor &monitor, const int trailing_points)
     {
      if(!Enabled())
         return CHAOS_NONE;

      datetime now = TimeCurrent();
      if(m_next_at == 0)
         m_next_at = now + m_every_seconds;
      if(now < m_next_at)
         return CHAOS_NONE;
      //--- Jittered, so events do not always land on the same phase of a trade.
      m_next_at = now + m_every_seconds / 2 + MathRand() % MathMax(m_every_seconds, 1);

      ENUM_CHAOS_EVENT event = (ENUM_CHAOS_EVENT)(1 + MathRand() % 5);
      ENUM_POSITION_TYPE type = POSITION_TYPE_BUY;
      ulong ticket = OurPosition(type);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);

      //--- An event that has nothing to act on becomes one that does.
      if(event == CHAOS_MANUAL_CLOSE && ticket == 0)
         event = CHAOS_EXTRA_POSITION;

      switch(event)
        {
         case CHAOS_MANUAL_CLOSE:
            PrintFormat("GoldGrid: CHAOS — manual close of #%I64u", ticket);
            manual_close_at = ClockMs();
            m_trade.PositionClose(ticket);
            break;

         case CHAOS_EXTRA_POSITION:
           {
            ENUM_POSITION_TYPE extra = (ticket != 0 && type == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
            PrintFormat("GoldGrid: CHAOS — injecting an extra %s position", extra == POSITION_TYPE_BUY ? "BUY" : "SELL");
            monitor.ExpectBreach();
            double lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
            if(extra == POSITION_TYPE_BUY) m_trade.Buy(lot, m_symbol, 0.0, 0.0, 0.0, "CHAOS");
            else                           m_trade.Sell(lot, m_symbol, 0.0, 0.0, 0.0, "CHAOS");
            break;
           }

         case CHAOS_DUPLICATE_ORDER:
           {
            double lot   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
            double level = NormalizeDouble(ask + 4 * trailing_points * _Point, _Digits);
            PrintFormat("GoldGrid: CHAOS — injecting a stray buy stop at %s", DoubleToString(level, _Digits));
            m_trade.BuyStop(lot, level, m_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "CHAOS");
            break;
           }

         case CHAOS_RESTART:
            Print("GoldGrid: CHAOS — simulating an EA restart");
            break;

         case CHAOS_TICK_STORM:
            Print("GoldGrid: CHAOS — tick storm (same tick handled 25 times)");
            break;
        }

      counts[(int)event]++;
      return event;
     }
  };

#endif

//+------------------------------------------------------------------+
//| Strategy.mqh                                                      |
//| The strategy configuration fetched from the platform, and the     |
//| risk checks applied before any order is placed.                   |
//|                                                                   |
//| IMPORTANT: the platform stores these limits but does not enforce  |
//| them. Enforcement happens here, in the EA, because this is the    |
//| only code that can refuse to send an order. If you modify this    |
//| file, you are modifying the only thing standing between a         |
//| configuration and the account.                                    |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_STRATEGY_MQH
#define GOLDGRID_STRATEGY_MQH

#include "Json.mqh"
#include "Clock.mqh"

enum ENUM_GRID_DIRECTION { GRID_BOTH, GRID_BUY_ONLY, GRID_SELL_ONLY };

//--- What the strategy does with the market. A grid rests a ladder of stop
//--- orders on both sides of the market and closes everything that filled on
//--- one combined profit target (being rebuilt — grid-strategy-plan.md). A
//--- trailing strategy holds one position and manages it with its stop.
//---
//--- A reversal strategy is always on exactly one side. The position's stop and
//--- a stop order for the opposite side sit at the same price and trail
//--- together, so when price turns by the distance the broker closes the one
//--- and opens the other — even if this terminal is offline at that moment.
enum ENUM_STRATEGY_CATEGORY { CATEGORY_GRID, CATEGORY_TRAILING, CATEGORY_REVERSAL };

struct SGridStrategy
  {
   bool               loaded;
   long               id;
   string             name;
   string             symbol;
   string             status;            // draft / running / stopped

   ENUM_STRATEGY_CATEGORY category;
   ENUM_GRID_DIRECTION direction;
   //--- Grid: a ladder of resting stop orders. Buy Stops rest above the
   //--- market and Sell Stops below it, each one `grid_spacing_points` further
   //--- out than the last. Everything that fills is closed together when the
   //--- combined profit reaches basket_take_profit; the ladder is then
   //--- re-placed after grid_cycle_pause_seconds.
   int                grid_spacing_points;
   int                grid_buy_orders;
   int                grid_sell_orders;
   int                grid_cycle_pause_seconds;
   double             initial_lot;           // the lot of every order

   //--- Trailing stop. The distance is the loss margin the user accepts giving
   //--- back from the best price the position has seen.
   bool               has_trailing;
   int                trailing_stop_points;
   bool               has_trailing_activation;
   int                trailing_activation_points;
   int                trailing_step_points;

   //--- Reversal only: how far from the market the flat Buy Stop / Sell Stop
   //--- bracket rests. The platform sends the effective value (the trailing
   //--- distance when the user left it blank).
   int                entry_distance_points;

   bool               has_basket_take_profit;
   double             basket_take_profit;
   bool               has_basket_stop_loss;
   double             basket_stop_loss;

   int                max_positions;
   double             max_exposure_lots;
   bool               has_max_drawdown;
   double             max_drawdown_percent;
   bool               has_min_margin_level;
   double             min_margin_level_percent;
   bool               has_max_spread;
   int                max_spread_points;

   //--- Realised + floating loss for the broker's trading day, in account
   //--- currency, at which everything is closed until the next day.
   bool               has_max_daily_loss;
   double             max_daily_loss;
   //--- Set by the platform's emergency stop: close everything, open nothing.
   bool               emergency_stop;

   //--- Identifies this exact configuration. A report response naming a
   //--- different one makes the EA re-fetch at once.
   string             config_version;

   //--- ClockMs() (Clock.mqh), NOT a wall clock.
   //--- Staleness has to keep elapsing while the market is closed and no
   //--- quotes are arriving, which a server-time clock does not do.
   ulong              fetched_at;

   bool               IsRunning(void) const { return status == "running"; }

   //--- How many orders one grid cycle places in total.
   int                LadderSize(void) const { return grid_buy_orders + grid_sell_orders; }
  };

//+------------------------------------------------------------------+
//| Populate a strategy from a parsed API response.                   |
//| Returns false if anything essential is missing, rather than       |
//| defaulting it: a zero grid spacing or lot size must never be      |
//| inferred.                                                         |
//+------------------------------------------------------------------+
bool ParseStrategy(CJsonNode *root, SGridStrategy &out, string &error)
  {
   out.loaded = false;
   error = "";

   CJsonNode *s = JsonPath(root, "strategy");
   if(CheckPointer(s) == POINTER_INVALID)
     {
      error = "Response contained no strategy.";
      return false;
     }

   CJsonNode *id_node = s.Get("id");
   if(CheckPointer(id_node) == POINTER_INVALID)
     {
      error = "Strategy had no id.";
      return false;
     }

   out.id     = (long)id_node.AsDouble(0);
   out.name   = s.Get("name")   != NULL ? s.Get("name").AsString("")   : "";
   out.symbol = s.Get("symbol") != NULL ? s.Get("symbol").AsString("") : "";
   out.status = s.Get("status") != NULL ? s.Get("status").AsString("") : "";
   out.config_version = s.Get("config_version") != NULL ? s.Get("config_version").AsString("") : "";

   string category = s.Get("category") != NULL ? s.Get("category").AsString("grid") : "grid";
   if(category == "trailing")      out.category = CATEGORY_TRAILING;
   else if(category == "reversal") out.category = CATEGORY_REVERSAL;
   else                            out.category = CATEGORY_GRID;

   string direction = s.Get("direction") != NULL ? s.Get("direction").AsString("both") : "both";
   if(direction == "buy")       out.direction = GRID_BUY_ONLY;
   else if(direction == "sell") out.direction = GRID_SELL_ONLY;
   else                         out.direction = GRID_BOTH;

   CJsonNode *grid = s.Get("grid");
   if(CheckPointer(grid) == POINTER_INVALID)
     {
      error = "Strategy had no grid configuration.";
      return false;
     }

   //--- The grid keys are null for a trailing or reversal strategy. They are
   //--- read the same way regardless and land as zero, which the
   //--- category-aware checks below then either demand or ignore.
   out.grid_spacing_points      = grid.Get("spacing_points")      != NULL ? grid.Get("spacing_points").AsInt(0)      : 0;
   out.grid_buy_orders          = grid.Get("buy_stop_orders")     != NULL ? grid.Get("buy_stop_orders").AsInt(0)     : 0;
   out.grid_sell_orders         = grid.Get("sell_stop_orders")    != NULL ? grid.Get("sell_stop_orders").AsInt(0)    : 0;
   out.grid_cycle_pause_seconds = grid.Get("cycle_pause_seconds") != NULL ? grid.Get("cycle_pause_seconds").AsInt(0) : 0;
   out.initial_lot              = grid.Get("initial_lot")         != NULL ? grid.Get("initial_lot").AsDouble(0)      : 0.0;

   //--- Trailing stop. Absent or null means the EA trails nothing, which is a
   //--- valid configuration for a grid and an invalid one for a trailing
   //--- strategy — checked below with the rest of the refusals.
   out.has_trailing               = false;
   out.trailing_stop_points       = 0;
   out.has_trailing_activation    = false;
   out.trailing_activation_points = 0;
   out.trailing_step_points       = 0;

   CJsonNode *trailing = s.Get("trailing");
   if(CheckPointer(trailing) != POINTER_INVALID)
     {
      CJsonNode *distance = trailing.Get("stop_points");
      if(CheckPointer(distance) != POINTER_INVALID && !distance.IsNull())
        {
         out.has_trailing         = true;
         out.trailing_stop_points = distance.AsInt(0);
        }

      CJsonNode *activation = trailing.Get("activation_points");
      if(CheckPointer(activation) != POINTER_INVALID && !activation.IsNull())
        {
         out.has_trailing_activation    = true;
         out.trailing_activation_points = activation.AsInt(0);
        }

      CJsonNode *step = trailing.Get("step_points");
      if(CheckPointer(step) != POINTER_INVALID && !step.IsNull())
         out.trailing_step_points = step.AsInt(0);
     }

   //--- A platform that predates the field sends no "entry" at all; that is
   //--- the old behaviour, a bracket at the trailing distance, and is filled in
   //--- below once the trailing distance is known to be valid.
   out.entry_distance_points = 0;
   CJsonNode *entry = s.Get("entry");
   if(CheckPointer(entry) != POINTER_INVALID)
     {
      CJsonNode *entry_distance = entry.Get("distance_points");
      if(CheckPointer(entry_distance) != POINTER_INVALID && !entry_distance.IsNull())
         out.entry_distance_points = entry_distance.AsInt(0);
     }

   CJsonNode *basket = s.Get("basket");
   out.has_basket_take_profit = false;
   out.has_basket_stop_loss   = false;
   out.basket_take_profit     = 0.0;
   out.basket_stop_loss       = 0.0;
   if(CheckPointer(basket) != POINTER_INVALID)
     {
      CJsonNode *tp = basket.Get("take_profit");
      if(CheckPointer(tp) != POINTER_INVALID && !tp.IsNull())
        { out.has_basket_take_profit = true; out.basket_take_profit = tp.AsDouble(0); }

      CJsonNode *sl = basket.Get("stop_loss");
      if(CheckPointer(sl) != POINTER_INVALID && !sl.IsNull())
        { out.has_basket_stop_loss = true; out.basket_stop_loss = sl.AsDouble(0); }
     }

   CJsonNode *risk = s.Get("risk");
   if(CheckPointer(risk) == POINTER_INVALID)
     {
      error = "Strategy had no risk configuration.";
      return false;
     }

   out.max_positions     = risk.Get("max_positions")     != NULL ? risk.Get("max_positions").AsInt(0)        : 0;
   out.max_exposure_lots = risk.Get("max_exposure_lots") != NULL ? risk.Get("max_exposure_lots").AsDouble(0) : 0.0;

   CJsonNode *drawdown = risk.Get("max_drawdown_percent");
   out.has_max_drawdown = (CheckPointer(drawdown) != POINTER_INVALID && !drawdown.IsNull());
   out.max_drawdown_percent = out.has_max_drawdown ? drawdown.AsDouble(0) : 0.0;

   CJsonNode *margin = risk.Get("min_margin_level_percent");
   out.has_min_margin_level = (CheckPointer(margin) != POINTER_INVALID && !margin.IsNull());
   out.min_margin_level_percent = out.has_min_margin_level ? margin.AsDouble(0) : 0.0;

   CJsonNode *spread = risk.Get("max_spread_points");
   out.has_max_spread = (CheckPointer(spread) != POINTER_INVALID && !spread.IsNull());
   out.max_spread_points = out.has_max_spread ? spread.AsInt(0) : 0;

   CJsonNode *daily = risk.Get("max_daily_loss");
   out.has_max_daily_loss = (CheckPointer(daily) != POINTER_INVALID && !daily.IsNull());
   out.max_daily_loss = out.has_max_daily_loss ? daily.AsDouble(0) : 0.0;
   if(out.has_max_daily_loss && out.max_daily_loss <= 0.0)
     { error = "Maximum daily loss must be greater than zero."; return false; }

   //--- Absent (an older platform) means no emergency, not an unusable
   //--- configuration.
   CJsonNode *emergency = risk.Get("emergency_stop");
   out.emergency_stop = (CheckPointer(emergency) != POINTER_INVALID && !emergency.IsNull())
                        ? emergency.AsBool(false) : false;

   //--- Refuse a configuration that cannot be traded safely rather than
   //--- substituting defaults for missing values.
   if(out.initial_lot <= 0.0)       { error = "Entry lot size must be greater than zero."; return false; }
   if(out.max_positions <= 0)       { error = "Maximum positions must be greater than zero."; return false; }
   if(out.max_exposure_lots <= 0.0) { error = "Maximum exposure must be greater than zero."; return false; }

   if(out.category == CATEGORY_GRID)
     {
      if(out.grid_spacing_points <= 0) { error = "Grid spacing must be greater than zero."; return false; }
      if(out.grid_buy_orders < 0 || out.grid_sell_orders < 0)
        { error = "Grid order counts cannot be negative."; return false; }
      if(out.LadderSize() <= 0)
        { error = "A grid needs at least one Buy Stop or Sell Stop order."; return false; }
      //--- The ladder is the most the cycle can ever hold, so a ceiling below
      //--- it is a configuration that contradicts itself. The platform refuses
      //--- it too; this is the copy that can actually stop an order.
      if(out.LadderSize() > out.max_positions)
        { error = "The grid ladder has more orders than maximum positions allows."; return false; }
      //--- The basket target is the ladder's only exit. Without it every fill
      //--- would stay open until something else — the daily loss, the user —
      //--- closed it.
      if(!out.has_basket_take_profit || out.basket_take_profit <= 0.0)
        { error = "A grid must have a basket take profit."; return false; }
      if(out.grid_cycle_pause_seconds <= 0)
        { error = "The grid's pause between cycles must be at least one second."; return false; }

      //--- A grid position has one exit, the basket target. Whatever trailing
      //--- settings arrive are not applied to it.
      out.has_trailing               = false;
      out.trailing_stop_points       = 0;
      out.has_trailing_activation    = false;
      out.trailing_activation_points = 0;
      out.trailing_step_points       = 0;
     }
   else
     {
      //--- A trailing strategy has no other exit. Running one with no distance
      //--- would open a position and then never close it.
      if(!out.has_trailing || out.trailing_stop_points <= 0)
        { error = "A trailing strategy must have a trailing distance."; return false; }

      //--- The opposite order trails from the moment a position opens. An
      //--- activation would leave the position with a stop that never moves
      //--- and an opposite order that never follows it.
      if(out.category == CATEGORY_REVERSAL)
        {
         out.has_trailing_activation    = false;
         out.trailing_activation_points = 0;

         if(out.entry_distance_points <= 0)
            out.entry_distance_points = out.trailing_stop_points;
        }
     }

   if(out.has_trailing)
     {
      if(out.trailing_stop_points <= 0)
        { error = "Trailing distance must be greater than zero."; return false; }

      //--- Without a minimum step the EA would ask the broker to modify the
      //--- position on nearly every tick, and be throttled or rejected for it.
      if(out.trailing_step_points <= 0)
         out.trailing_step_points = 1;
      if(out.trailing_step_points > out.trailing_stop_points)
         out.trailing_step_points = out.trailing_stop_points;
     }

   out.fetched_at = ClockMs();
   out.loaded = true;
   return true;
  }

//+------------------------------------------------------------------+
//| The lot every order opens with, normalised to the broker's volume |
//| step and clamped to its min/max.                                  |
//+------------------------------------------------------------------+
double EntryLot(const SGridStrategy &strategy, const string symbol)
  {
   double lot = strategy.initial_lot;

   double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lot_step > 0.0)
      lot = MathFloor(lot / lot_step + 0.0000001) * lot_step;

   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;

   //--- Guard against floating point dust in the volume value.
   return NormalizeDouble(lot, 2);
  }

#endif

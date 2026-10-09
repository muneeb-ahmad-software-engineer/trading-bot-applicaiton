//+------------------------------------------------------------------+
//| Cycle.mqh                                                         |
//| The grid's cycle: which step of the loop the EA is in, which      |
//| cycle this is, where its ladder is anchored, and until when it    |
//| pauses between cycles — persisted so a terminal restart resumes   |
//| the same cycle instead of starting a second one over it.          |
//|                                                                   |
//|   INITIALIZING ─reconcile─▶ PLACING ─ladder complete─▶ ARMED      |
//|        │                      ▲                          │ target  |
//|        │                      │ pause elapsed            ▼         |
//|        │                   COOLDOWN ◀─confirmed flat─ CLOSING      |
//|        └─unexplained broker state────────────────────▶ RECOVERY   |
//|                                                                   |
//| Like State.mqh for the single-position categories, this records   |
//| what the EA was DOING. The broker stays the source of truth for   |
//| what is OPEN: INITIALIZING compares the two, and when they cannot |
//| be reconciled the state is RECOVERY and nothing new is placed.    |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_CYCLE_MQH
#define GOLDGRID_CYCLE_MQH

#include "Clock.mqh"

enum ENUM_CYCLE_STATE
  {
   CYCLE_INITIALIZING,     // comparing the persisted cycle with the broker after a start
   CYCLE_PLACING,          // the ladder is being placed; fills may already happen
   CYCLE_ARMED,            // the ladder is complete; watching the basket
   CYCLE_CLOSING,          // the target was reached; closing positions and cancelling orders
   CYCLE_COOLDOWN,         // flat; waiting out the pause before the next cycle
   CYCLE_RECOVERY,         // something of ours on the broker belongs to no cycle; nothing is placed
   CYCLE_STATE_COUNT
  };

string CycleStateName(const ENUM_CYCLE_STATE state)
  {
   switch(state)
     {
      case CYCLE_INITIALIZING: return "INITIALIZING";
      case CYCLE_PLACING:      return "PLACING";
      case CYCLE_ARMED:        return "ARMED";
      case CYCLE_CLOSING:      return "CLOSING";
      case CYCLE_COOLDOWN:     return "COOLDOWN";
      case CYCLE_RECOVERY:     return "RECOVERY";
     }
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
//| Persisted in terminal global variables                            |
//| GoldGrid.<magic>.<symbol>.cycle.{state,number,anchor_bid,         |
//| anchor_ask,anchor_at,gap,buy,sell,first,pause_until}, written     |
//| through to disk on every change (a restart is as likely to be a   |
//| crash as a clean exit) and touched once an hour, because the      |
//| terminal deletes a global variable untouched for four weeks.      |
//|                                                                   |
//| THE LADDER'S SHAPE — gap, rung counts and the first rung's offset |
//| — is snapshotted when the cycle anchors. A setting changed on the |
//| platform mid-cycle applies to the NEXT cycle: a ladder measured   |
//| with one gap and completed with another would have rungs in the   |
//| wrong places, and a count reduced mid-cycle would have rungs      |
//| deleted from under a live basket.                                 |
//|                                                                   |
//| The pause is wall-clock (TimeGMT): GetTickCount64 starts again    |
//| from zero with the terminal, and a pause measured with it would   |
//| be cancelled by every restart.                                    |
//+------------------------------------------------------------------+
class CCycleState
  {
private:
   string            m_prefix;
   ENUM_CYCLE_STATE  m_state;
   string            m_reason;        // why the current state was entered
   ulong             m_entered_ms;    // monotonic, for timeouts within one run
   ENUM_CYCLE_STATE  m_previous;      // the state the record held before Load()
   int               m_number;        // this cycle's number; 0 = no cycle yet
   double            m_anchor_bid;    // the ladder's anchor; 0 = not anchored yet
   double            m_anchor_ask;
   datetime          m_anchor_at;     // server time of the anchor, for history lookups
   int               m_gap;           // the ladder's shape at the anchor (see above)
   int               m_buy;
   int               m_sell;
   int               m_first;         // rung 1's offset in points
   double            m_lot;           // the lot every rung of this cycle carries
   datetime          m_pause_until;   // GMT; 0 = not pausing
   ulong             m_touched_ms;

   //--- This run only, for the Strategy Tester summary.
   int               m_entries[CYCLE_STATE_COUNT];
   int               m_cycles_closed;

   string            Key(const string name) const { return m_prefix + name; }

   void              Save(void)
     {
      GlobalVariableSet(Key("state"),       (double)m_state);
      GlobalVariableSet(Key("number"),      (double)m_number);
      GlobalVariableSet(Key("anchor_bid"),  m_anchor_bid);
      GlobalVariableSet(Key("anchor_ask"),  m_anchor_ask);
      GlobalVariableSet(Key("anchor_at"),   (double)m_anchor_at);
      GlobalVariableSet(Key("gap"),         (double)m_gap);
      GlobalVariableSet(Key("buy"),         (double)m_buy);
      GlobalVariableSet(Key("sell"),        (double)m_sell);
      GlobalVariableSet(Key("first"),       (double)m_first);
      GlobalVariableSet(Key("lot"),         m_lot);
      GlobalVariableSet(Key("pause_until"), (double)m_pause_until);
      m_touched_ms = ClockMs();
      if(!IsTester())
         GlobalVariablesFlush();
     }

   void              ClearAnchor(void)
     {
      m_anchor_bid = 0.0;
      m_anchor_ask = 0.0;
      m_anchor_at  = 0;
      m_gap = m_buy = m_sell = m_first = 0;
      m_lot = 0.0;
     }

public:
                     CCycleState(void)
     {
      m_state         = CYCLE_INITIALIZING;
      m_previous      = CYCLE_INITIALIZING;
      m_reason        = "";
      m_entered_ms    = 0;
      m_number        = 0;
      ClearAnchor();
      m_pause_until   = 0;
      m_touched_ms    = 0;
      ArrayInitialize(m_entries, 0);
      m_cycles_closed = 0;
     }

   void              Configure(const long magic, const string symbol)
     {
      m_prefix = StringFormat("GoldGrid.%I64d.%s.cycle.", magic, symbol);
     }

   //--- Restores the persisted cycle. The state itself always restarts at
   //--- INITIALIZING: what the EA was doing is returned for the log, and the
   //--- broker's actual orders and positions decide what happens next.
   ENUM_CYCLE_STATE  Load(void)
     {
      ENUM_CYCLE_STATE previous = CYCLE_INITIALIZING;
      if(GlobalVariableCheck(Key("state")))
         previous = (ENUM_CYCLE_STATE)(int)GlobalVariableGet(Key("state"));
      if(GlobalVariableCheck(Key("number")))
         m_number = (int)GlobalVariableGet(Key("number"));
      if(GlobalVariableCheck(Key("anchor_bid")))
         m_anchor_bid = GlobalVariableGet(Key("anchor_bid"));
      if(GlobalVariableCheck(Key("anchor_ask")))
         m_anchor_ask = GlobalVariableGet(Key("anchor_ask"));
      if(GlobalVariableCheck(Key("anchor_at")))
         m_anchor_at = (datetime)GlobalVariableGet(Key("anchor_at"));
      if(GlobalVariableCheck(Key("gap")))
         m_gap = (int)GlobalVariableGet(Key("gap"));
      if(GlobalVariableCheck(Key("buy")))
         m_buy = (int)GlobalVariableGet(Key("buy"));
      if(GlobalVariableCheck(Key("sell")))
         m_sell = (int)GlobalVariableGet(Key("sell"));
      if(GlobalVariableCheck(Key("first")))
         m_first = (int)GlobalVariableGet(Key("first"));
      if(GlobalVariableCheck(Key("lot")))
         m_lot = GlobalVariableGet(Key("lot"));
      if(GlobalVariableCheck(Key("pause_until")))
         m_pause_until = (datetime)GlobalVariableGet(Key("pause_until"));

      m_previous   = previous;
      m_state      = CYCLE_INITIALIZING;
      m_reason     = "EA started";
      m_entered_ms = ClockMs();
      return previous;
     }

   ENUM_CYCLE_STATE  State(void)        const { return m_state; }
   //--- What the record said the EA was doing when it last ran. INITIALIZING
   //--- acts on it: a CLOSING that was interrupted is resumed, not forgotten.
   ENUM_CYCLE_STATE  Previous(void)     const { return m_previous; }
   datetime          AnchorAt(void)     const { return m_anchor_at; }
   int               Gap(void)          const { return m_gap; }
   int               BuyRungs(void)     const { return m_buy; }
   int               SellRungs(void)    const { return m_sell; }
   int               FirstPoints(void)  const { return m_first; }
   double            Lot(void)          const { return m_lot; }
   string            Name(void)         const { return CycleStateName(m_state); }
   string            Reason(void)       const { return m_reason; }
   int               Number(void)       const { return m_number; }
   double            AnchorBid(void)    const { return m_anchor_bid; }
   double            AnchorAsk(void)    const { return m_anchor_ask; }
   bool              Anchored(void)     const { return m_anchor_bid > 0.0 && m_anchor_ask > 0.0; }
   datetime          PauseUntil(void)   const { return m_pause_until; }
   ulong             MsInState(void)    const { return ClockMs() - m_entered_ms; }
   bool              Is(const ENUM_CYCLE_STATE state) const { return m_state == state; }
   int               Entries(const ENUM_CYCLE_STATE state) const { return m_entries[(int)state]; }
   int               CyclesClosed(void) const { return m_cycles_closed; }

   //--- Every transition is logged with its reason: a state machine that
   //--- changes silently cannot be reconstructed from the journal afterwards.
   void              Set(const ENUM_CYCLE_STATE state, const string reason)
     {
      if(state == m_state)
         return;
      PrintFormat("GoldGrid: cycle %d %s -> %s (%s)", m_number, CycleStateName(m_state), CycleStateName(state), reason);
      m_entries[(int)state]++;
      m_state      = state;
      m_reason     = reason;
      m_entered_ms = ClockMs();
      Save();
     }

   //--- The ladder's anchor, fixed from the first rung sent until the cycle
   //--- ends (D5). Persisted, so a restart places the remaining rungs where
   //--- the first ones were measured from.
   void              Anchor(const double bid, const double ask, const int gap, const int buy, const int sell,
                            const int first, const double lot)
     {
      if(bid <= 0.0 || ask <= 0.0)
         return;
      m_anchor_bid = bid;
      m_anchor_ask = ask;
      m_anchor_at  = TimeCurrent();
      m_gap   = gap;
      m_buy   = buy;
      m_sell  = sell;
      m_first = first;
      m_lot   = lot;
      Save();
     }

   //--- Adopts a cycle found on the broker (its number from the order
   //--- comments, its anchor from their prices) when the persisted record
   //--- disagrees or is missing. The broker wins outright: the record is a
   //--- note of what this EA was doing, the orders are what is at stake.
   //--- The shape comes from the caller's best knowledge (the record's if it
   //--- had one for this number, else the strategy's).
   void              Adopt(const int number, const double bid, const double ask, const int gap, const int buy,
                           const int sell, const int first, const double lot, const datetime since)
     {
      m_number     = number;
      m_anchor_bid = bid;
      m_anchor_ask = ask;
      m_anchor_at  = since;
      m_gap   = gap;
      m_buy   = buy;
      m_sell  = sell;
      m_first = first;
      m_lot   = lot;
      Save();
     }

   //--- Keeps the record alive: the terminal deletes a global variable that
   //--- has not been touched for four weeks, and a long ARMED cycle might
   //--- otherwise never write.
   void              Touch(void)
     {
      if(ClockMs() - m_touched_ms >= 3600000)
         Save();
     }

   //--- Starts the first cycle ever.
   void              Begin(void)
     {
      if(m_number > 0)
         return;
      m_number     = 1;
      ClearAnchor();
      Save();
     }

   //--- The cycle ended, flat: the next one gets the next number, no anchor
   //--- yet, and the pause in front of it. The number only ever grows by one,
   //--- which the tester's invariant monitor checks.
   void              NextCycle(const int pause_seconds)
     {
      m_number++;
      m_cycles_closed++;
      ClearAnchor();
      m_pause_until = TimeGMT() + MathMax(pause_seconds, 0);
      Save();
     }

   //--- A close that was not a cycle's: something of ours appeared while no
   //--- ladder was anchored (a position injected by hand) and was closed at
   //--- target. The number is kept — no ladder was placed under it — and
   //--- only the pause starts again.
   void              RestartPause(const int pause_seconds)
     {
      m_pause_until = TimeGMT() + MathMax(pause_seconds, 0);
      Save();
     }

   void              EndPause(void)
     {
      if(m_pause_until == 0)
         return;
      m_pause_until = 0;
      Save();
     }

   //--- Seconds of pause left, 0 when none. `configured` guards against the
   //--- PC clock having stepped backwards since the pause was set (an NTP
   //--- correction, a manual change): a pause that claims to be longer than
   //--- it was ever configured for is treated as over rather than locking
   //--- the strategy out for however far the clock jumped.
   long              PauseRemaining(const int configured) const
     {
      if(m_pause_until == 0)
         return 0;
      long remaining = (long)(m_pause_until - TimeGMT());
      if(remaining <= 0)
         return 0;
      if(remaining > (long)configured + 60)
         return 0;
      return remaining;
     }
  };

#endif

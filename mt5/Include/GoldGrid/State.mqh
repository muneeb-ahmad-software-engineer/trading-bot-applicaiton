//+------------------------------------------------------------------+
//| State.mqh                                                         |
//| Execution state of a single-position strategy (trailing and       |
//| reversal), persisted so a terminal restart resumes where it left  |
//| off instead of guessing.                                          |
//|                                                                   |
//| The state is a record of what the EA was DOING. It never replaces |
//| the broker as the source of truth for what is OPEN: every pass    |
//| reconciles it against the actual positions, and when the two      |
//| disagree in a way that cannot be explained, the state becomes     |
//| RECOVERY and nothing new is opened.                               |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_STATE_MQH
#define GOLDGRID_STATE_MQH

#include "Clock.mqh"

enum ENUM_EXEC_STATE
  {
   STATE_INITIALIZING,     // reconciling with the broker after start or restart
   STATE_WAITING,          // flat; an entry may be placed
   STATE_BUY_ACTIVE,       // exactly one buy open
   STATE_SELL_ACTIVE,      // exactly one sell open
   STATE_REVERSING,        // the opposite stop filled; the old position is being closed
   STATE_CLOSING,          // a close was sent; waiting for the broker to confirm it
   STATE_RECOVERY,         // broker state unexpected or unconfirmed; nothing is opened
   STATE_COUNT
  };

string ExecStateName(const ENUM_EXEC_STATE state)
  {
   switch(state)
     {
      case STATE_INITIALIZING:     return "INITIALIZING";
      case STATE_WAITING:          return "WAITING";
      case STATE_BUY_ACTIVE:       return "BUY_ACTIVE";
      case STATE_SELL_ACTIVE:      return "SELL_ACTIVE";
      case STATE_REVERSING:        return "REVERSING";
      case STATE_CLOSING:          return "CLOSING";
      case STATE_RECOVERY:         return "RECOVERY";
     }
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
//| Persisted in terminal global variables, keyed per magic number    |
//| and symbol so two instances never read each other's state.        |
//|                                                                   |
//| Times that must survive a restart are wall-clock seconds          |
//| (TimeGMT), not GetTickCount64 — that counter starts again from    |
//| zero with the terminal, and a cooldown measured with it would be  |
//| silently cancelled by every restart.                              |
//+------------------------------------------------------------------+
class CExecutionState
  {
private:
   string            m_prefix;
   ENUM_EXEC_STATE   m_state;
   string            m_reason;          // why the current state was entered
   ulong             m_entered_ms;      // monotonic, for timeouts within one run
   ulong             m_ticket;          // the position the state refers to, if any
   //--- The same position's POSITION_IDENTIFIER. The ticket can change under a
   //--- position on some brokers (a swap charged by re-opening it, for
   //--- one), but the identifier never does, and it is what the deal history
   //--- is keyed by — so every history lookup uses this, not the ticket.
   long              m_position_id;
   datetime          m_last_close_gmt;  // last close of one of our positions
   int               m_last_side;       // side of the last closed position: -1 none, 0 buy, 1 sell

   //--- Counters for this run only (not persisted), read by the Strategy
   //--- Tester summary and the invariant checks.
   int               m_entries[STATE_COUNT]; // times each state was entered
   int               m_reversals;       // REVERSING -> *_ACTIVE: the old side closed, the new one held
   int               m_reversals_flat;  // REVERSING -> WAITING: reversing was not allowed, both closed

   string            Key(const string name) const { return m_prefix + name; }

   void              Save(void)
     {
      GlobalVariableSet(Key("state"),      (double)m_state);
      GlobalVariableSet(Key("ticket"),     (double)m_ticket);
      GlobalVariableSet(Key("position_id"), (double)m_position_id);
      GlobalVariableSet(Key("last_close"), (double)m_last_close_gmt);
      GlobalVariableSet(Key("last_side"),  (double)m_last_side);
      //--- Written through to disk now, not at terminal shutdown: the restart
      //--- this exists for is as likely to be a crash as a clean exit. (The
      //--- tester's global variables are throwaway; flushing them on every
      //--- transition would only slow a backtest down.)
      if(!IsTester())
         GlobalVariablesFlush();
     }

public:
                     CExecutionState(void)
     {
      m_state          = STATE_INITIALIZING;
      m_reason         = "";
      m_entered_ms     = 0;
      m_ticket         = 0;
      m_position_id    = 0;
      m_last_close_gmt = 0;
      m_last_side      = -1;
      ArrayInitialize(m_entries, 0);
      m_reversals      = 0;
      m_reversals_flat = 0;
     }

   void              Configure(const long magic, const string symbol)
     {
      m_prefix = StringFormat("GoldGrid.%I64d.%s.", magic, symbol);
     }

   //--- Restores what was persisted. The state itself always restarts at
   //--- INITIALIZING — what the EA was doing before the restart is logged for
   //--- context, but only the broker's current positions decide what happens
   //--- next.
   ENUM_EXEC_STATE   Load(void)
     {
      ENUM_EXEC_STATE previous = STATE_INITIALIZING;
      if(GlobalVariableCheck(Key("state")))
         previous = (ENUM_EXEC_STATE)(int)GlobalVariableGet(Key("state"));
      if(GlobalVariableCheck(Key("ticket")))
         m_ticket = (ulong)GlobalVariableGet(Key("ticket"));
      if(GlobalVariableCheck(Key("position_id")))
         m_position_id = (long)GlobalVariableGet(Key("position_id"));
      if(GlobalVariableCheck(Key("last_close")))
         m_last_close_gmt = (datetime)GlobalVariableGet(Key("last_close"));
      if(GlobalVariableCheck(Key("last_side")))
         m_last_side = (int)GlobalVariableGet(Key("last_side"));

      m_state      = STATE_INITIALIZING;
      m_reason     = "EA started";
      m_entered_ms = ClockMs();
      return previous;
     }

   ENUM_EXEC_STATE   State(void)       const { return m_state; }
   string            Name(void)        const { return ExecStateName(m_state); }
   string            Reason(void)      const { return m_reason; }
   ulong             Ticket(void)      const { return m_ticket; }
   long              PositionId(void)  const { return m_position_id; }
   datetime          LastCloseGmt(void) const { return m_last_close_gmt; }
   ulong             MsInState(void)   const { return ClockMs() - m_entered_ms; }
   bool              Is(const ENUM_EXEC_STATE state) const { return m_state == state; }
   bool              IsActive(void)    const { return m_state == STATE_BUY_ACTIVE || m_state == STATE_SELL_ACTIVE; }
   int               Entries(const ENUM_EXEC_STATE state) const { return m_entries[(int)state]; }
   int               Reversals(void)   const { return m_reversals; }
   int               ReversalsFlat(void) const { return m_reversals_flat; }

   //--- Every transition is logged with its reason: a state machine that
   //--- changes silently cannot be reconstructed from the journal afterwards.
   void              Set(const ENUM_EXEC_STATE state, const string reason, const ulong ticket = 0)
     {
      if(state == m_state && ticket == m_ticket)
         return;

      PrintFormat("GoldGrid: state %s -> %s (%s)", ExecStateName(m_state), ExecStateName(state), reason);

      if(state != m_state)
        {
         m_entries[(int)state]++;
         if(m_state == STATE_REVERSING && (state == STATE_BUY_ACTIVE || state == STATE_SELL_ACTIVE))
            m_reversals++;
         if(m_state == STATE_REVERSING && state == STATE_WAITING)
            m_reversals_flat++;
        }

      //--- The identifier is read while the position is still open. A state
      //--- that refers to a position that has already closed (a RECOVERY over
      //--- an unconfirmed close) passes the same ticket again, and keeps the
      //--- identifier recorded while it was open.
      if(ticket == 0)
         m_position_id = 0;
      else if(PositionSelectByTicket(ticket))
         m_position_id = PositionGetInteger(POSITION_IDENTIFIER);
      else if(ticket != m_ticket)
         m_position_id = (long)ticket;   // never seen open: the best guess there is

      m_state      = state;
      m_reason     = reason;
      m_ticket     = ticket;
      m_entered_ms = ClockMs();
      Save();
     }

   void              RecordClose(void)
     {
      m_last_close_gmt = TimeGMT();
      Save();
     }

   //--- -1 when no position has closed yet, otherwise the ENUM_POSITION_TYPE
   //--- value of the one that closed last.
   int               LastSide(void) const { return m_last_side; }

   void              RecordClosedSide(const ENUM_POSITION_TYPE side)
     {
      m_last_side = (int)side;
      Save();
     }

   //--- Seconds since the last close, across restarts. Large when there has
   //--- never been one.
   long              SecondsSinceClose(void) const
     {
      if(m_last_close_gmt <= 0)
         return LONG_MAX;
      long elapsed = (long)(TimeGMT() - m_last_close_gmt);
      //--- The PC clock stepped backwards since the close (an NTP correction,
      //--- a manual change). Counting that as "no time has passed" would lock
      //--- entries out for however far the clock jumped; treat it as elapsed.
      return elapsed < 0 ? LONG_MAX : elapsed;
     }
  };

#endif

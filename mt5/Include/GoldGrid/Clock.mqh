//+------------------------------------------------------------------+
//| Clock.mqh                                                         |
//| The one clock every interval and timeout in the EA is measured    |
//| with.                                                             |
//|                                                                   |
//| Live: GetTickCount64(), milliseconds since the terminal started.  |
//| Monotonic, and unaffected by quotes stopping over a weekend, the  |
//| system clock being changed, or a DST boundary.                    |
//|                                                                   |
//| Strategy Tester: simulated time. GetTickCount64() there is still  |
//| REAL time, while simulated days pass in real seconds — so a 3 s   |
//| settling lock would span hours of simulated market and a 15 s     |
//| confirmation timeout would never expire. Every timeout would be   |
//| wrong in the one place they are meant to be tested.               |
//+------------------------------------------------------------------+
#ifndef GOLDGRID_CLOCK_MQH
#define GOLDGRID_CLOCK_MQH

bool IsTester(void)
  {
   return (bool)MQLInfoInteger(MQL_TESTER);
  }

ulong ClockMs(void)
  {
   if(IsTester())
      return (ulong)TimeCurrent() * 1000;
   return GetTickCount64();
  }

#endif

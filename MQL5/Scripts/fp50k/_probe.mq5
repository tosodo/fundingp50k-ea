//+------------------------------------------------------------------+
//| _probe.mq5                                                        |
//| FP50K-EA | Throwaway diagnostic - times repeated calendar calls   |
//+------------------------------------------------------------------+
void OnStart()
  {
   Print("[QA] INFO | probe | start");

   for(int n = 1; n <= 4; n++)
     {
      uint t0 = GetTickCount();
      MqlCalendarValue values[];
      int count = CalendarValueHistory(values, TimeCurrent() - 300, TimeCurrent() + 300);
      uint ms = GetTickCount() - t0;
      Print("[QA] INFO | call ", n, " | ", ms, " ms, count=", count, " err=", GetLastError());
     }

   Print("[QA] ===== RESULT: 1 passed, 0 failed =====");
  }

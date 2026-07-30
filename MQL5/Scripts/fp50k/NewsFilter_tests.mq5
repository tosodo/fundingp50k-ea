//+------------------------------------------------------------------+
//| NewsFilter_tests.mq5                                              |
//| FP50K-EA | Sprint 3 Unit Tests                                    |
//| Tests: currency matching, blackout window, cache behaviour        |
//+------------------------------------------------------------------+
#property script_show_inputs

#include <fp50k\NewsFilter.mqh>

int test_count  = 0;
int test_passed = 0;
int test_failed = 0;

void Check(string name, bool passed, string detail = "")
  {
   test_count++;
   if(passed)
     {
      test_passed++;
      Print("[QA] PASS | ", name, " | ", detail);
     }
   else
     {
      test_failed++;
      Print("[QA] FAIL | ", name, " | ", detail);
     }
  }

void Info(string label, string value)
  {
   Print("[QA] INFO | ", label, " | ", value);
  }

void OnStart()
  {
   Print("=== FP50K-EA | NewsFilter Unit Tests ===");

   CNewsFilter nf;

//--- GROUP 1: Constants
   Check("NEWS_BLOCK_MINUTES == 5",   NEWS_BLOCK_MINUTES  == 5);
   Check("Refresh interval is 60s",   NEWS_REFRESH_SECS   == 60);
   Check("Lookback is one hour",      NEWS_LOOKBACK_SECS  == 3600);
   Check("Lookahead is four hours",   NEWS_LOOKAHEAD_SECS == 4 * 3600);
   Check("Lookahead exceeds the refresh interval",
         NEWS_LOOKAHEAD_SECS > NEWS_REFRESH_SECS,
         "a refresh must never be able to miss an approaching event");

//--- GROUP 2: Currency matching against a symbol
   Check("USD matches EURUSD (quote side)", nf.CurrencyMatchesSymbol("USD", "EURUSD"));
   Check("EUR matches EURUSD (base side)",  nf.CurrencyMatchesSymbol("EUR", "EURUSD"));
   Check("GBP matches GBPUSD",              nf.CurrencyMatchesSymbol("GBP", "GBPUSD"));
   Check("USD matches GBPUSD",              nf.CurrencyMatchesSymbol("USD", "GBPUSD"));
   Check("JPY does not match EURUSD",       nf.CurrencyMatchesSymbol("JPY", "EURUSD") == false);
   Check("GBP does not match EURUSD",       nf.CurrencyMatchesSymbol("GBP", "EURUSD") == false);
   Check("Empty currency matches nothing",  nf.CurrencyMatchesSymbol("", "EURUSD") == false);
   Check("Short symbol matches nothing",    nf.CurrencyMatchesSymbol("USD", "EUR") == false);

//--- GROUP 3: The blackout window is symmetric around the event
   datetime t0 = D'2026.07.30 13:30:00';

   Check("Exactly at the event is blacked out",
         nf.IsWithinWindow(t0, t0, 5));
   Check("1 min before is blacked out",
         nf.IsWithinWindow(t0 - 60, t0, 5));
   Check("1 min after is blacked out",
         nf.IsWithinWindow(t0 + 60, t0, 5));
   Check("Exactly 5 min before is still blacked out (boundary)",
         nf.IsWithinWindow(t0 - 300, t0, 5));
   Check("Exactly 5 min after is still blacked out (boundary)",
         nf.IsWithinWindow(t0 + 300, t0, 5));
   Check("5 min 1 sec before is clear",
         nf.IsWithinWindow(t0 - 301, t0, 5) == false);
   Check("5 min 1 sec after is clear",
         nf.IsWithinWindow(t0 + 301, t0, 5) == false);
   Check("An hour away is clear",
         nf.IsWithinWindow(t0 + 3600, t0, 5) == false);
   Check("A zero buffer blocks nothing",
         nf.IsWithinWindow(t0, t0, 0) == false);
   Check("A negative buffer blocks nothing",
         nf.IsWithinWindow(t0, t0, -5) == false);
   Check("A wider buffer catches what a narrow one misses",
         nf.IsWithinWindow(t0 + 600, t0, 5) == false &&
         nf.IsWithinWindow(t0 + 600, t0, 15) == true);

//--- GROUP 4: End-to-end blackout, driven by an injected event.
//    The live calendar cannot be relied on to have an event happening right
//    now, so the only deterministic way to test the blocking path is to seed
//    one. This is the safety-critical case: it must block.
   CNewsFilter seeded;
   seeded.ClearCache();
   datetime now = TimeCurrent();

   seeded.InjectEvent(now, "TEST Non-Farm Payrolls", "USD");
   Check("Seeded cache holds one event", seeded.CachedEventCount() == 1);

   Check("Event on USD blocks EURUSD right now",
         seeded.IsBlackedOut("EURUSD", 5) == true);
   Check("Event on USD blocks GBPUSD too",
         seeded.IsBlackedOut("GBPUSD", 5) == true);
   Check("Event on USD does not block EURGBP",
         seeded.IsBlackedOut("EURGBP", 5) == false,
         "neither leg is USD");
   Check("Blocking records which event was responsible",
         seeded.LastBlockEvent() == "TEST Non-Farm Payrolls",
         seeded.LastBlockEvent());

//--- An event well outside the window must not block
   CNewsFilter distant;
   distant.ClearCache();
   distant.InjectEvent(now + 3600, "TEST Distant Event", "USD");
   Check("An event an hour out does not block a 5 min window",
         distant.IsBlackedOut("EURUSD", 5) == false);
   Check("...but does block a 90 min window",
         distant.IsBlackedOut("EURUSD", 90) == true,
         "confirms the buffer parameter is actually applied");

//--- The pre-news close uses a tighter buffer than the entry gate. Verify the
//    two genuinely differ, or the 3-minute close would be doing nothing.
   CNewsFilter edge;
   edge.ClearCache();
   edge.InjectEvent(now + 240, "TEST Four Minutes Out", "USD");   // 4 min away
   Check("4 min out: entry gate (5 min) blocks",
         edge.IsBlackedOut("EURUSD", 5) == true);
   Check("4 min out: pre-news close (3 min) does not yet fire",
         edge.IsBlackedOut("EURUSD", 3) == false);

//--- GROUP 5: NextEvent reports the soonest upcoming match
   CNewsFilter upcoming;
   upcoming.ClearCache();
   upcoming.InjectEvent(now + 7200, "TEST Later",   "USD");
   upcoming.InjectEvent(now + 1800, "TEST Sooner",  "USD");
   upcoming.InjectEvent(now - 1800, "TEST Past",    "USD");
   upcoming.InjectEvent(now + 900,  "TEST Not Ours","JPY");

   datetime nt = 0;
   string   nn = "";
   bool found = upcoming.NextEvent("EURUSD", nt, nn);

   Check("NextEvent finds an upcoming event", found);
   Check("NextEvent picks the soonest, not the first stored",
         nn == "TEST Sooner", nn);
   Check("NextEvent ignores events already past", nt > now);
   Check("NextEvent ignores currencies we do not trade",
         nn != "TEST Not Ours");

   datetime nt2 = 0;
   string   nn2 = "";
   Check("NextEvent reports nothing for an unrelated pair",
         upcoming.NextEvent("AUDCAD", nt2, nn2) == false);
   Check("A failed NextEvent leaves its outputs empty",
         nt2 == 0 && nn2 == "");

//--- GROUP 6: The live calendar, and the speed that matters
   CNewsFilter live;
   Check("Init() returns true", live.Init());
   Info("High-impact events cached (4h window)",
        IntegerToString(live.CachedEventCount()));
   Check("Init() stamps the refresh time", live.LastRefresh() > 0);

// A cache of zero is ambiguous on its own: it means either a genuinely quiet
// window, or a calendar connection that has silently stopped returning
// anything. Those look identical from the outside and have very different
// consequences - a dead calendar means the EA would trade straight through a
// red-folder release with no blackout at all. Query the raw feed directly so
// the run reports which it is, and assert the connection itself is alive.
   MqlCalendarValue raw[];
   int raw_count = CalendarValueHistory(raw, TimeCurrent() - NEWS_LOOKBACK_SECS,
                                             TimeCurrent() + NEWS_LOOKAHEAD_SECS);
   int high_count = 0;
   for(int i = 0; i < raw_count; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(raw[i].event_id, ev)) continue;
      if(ev.importance == CALENDAR_IMPORTANCE_HIGH) high_count++;
     }
   Info("Raw calendar events in the same window (all importances)",
        IntegerToString(raw_count));
   Info("...of which high-impact", IntegerToString(high_count));

   Check("Calendar feed is alive (returns events of some importance)",
         raw_count > 0,
         "zero here means the calendar database is missing or disconnected, "
         "not that the week is quiet");
   Check("Cache captured every high-impact event the feed reported",
         live.CachedEventCount() == high_count,
         StringFormat("cached=%d feed=%d", live.CachedEventCount(), high_count));

// The blackout check runs on the pre-trade path AND on every tick with an open
// position. CalendarValueHistory() costs ~2s cold and ~90s on a terminal
// downloading the calendar for the first time - if either ever landed here,
// this is the test that catches it.
   uint t_start = GetTickCount();
   for(int i = 0; i < 200; i++)
     {
      live.IsBlackedOut("EURUSD", 5);
      live.IsBlackedOut("GBPUSD", 3);
     }
   uint elapsed = GetTickCount() - t_start;
   Info("400 blackout checks took", IntegerToString(elapsed) + " ms");
   Check("Blackout checks stay off the slow calendar path (400 under 500ms)",
         elapsed < 500, IntegerToString(elapsed) + " ms");

// Alternating symbols must not each force a re-fetch. This was a real design
// trap: filtering by currency at fetch time would put the slow call back on
// the hot path whenever an EA traded two pairs.
   datetime refreshed_before = live.LastRefresh();
   for(int i = 0; i < 20; i++)
     {
      live.IsBlackedOut("EURUSD", 5);
      live.IsBlackedOut("GBPUSD", 5);
      live.IsBlackedOut("USDJPY", 5);
     }
   Check("Alternating symbols does not trigger a re-fetch",
         live.LastRefresh() == refreshed_before,
         "cache is symbol-independent by design");

//--- Summary
   Print("[QA] ===== RESULT: ", test_passed, " passed, ", test_failed, " failed =====");
  }

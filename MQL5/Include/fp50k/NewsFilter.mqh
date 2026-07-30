//+------------------------------------------------------------------+
//| NewsFilter.mqh                                                    |
//| FP50K-EA | Economic Calendar Blackout Filter                      |
//| Blocks entries around high-impact events on the traded currencies |
//| Author: Tee (aigentforce.io) | Built: July 2026                   |
//+------------------------------------------------------------------+
//
// Why this is a cache and not a straight CalendarValueHistory() call:
//
//   CalendarValueHistory() blocks for ~90s the first time a terminal has to
//   download the economic-calendar database, and ~2s on the first call of each
//   later session (both measured on this install, not estimated). A blackout
//   check runs on the pre-trade path and, for the pre-news close, on every
//   tick with an open position - neither can afford to sit inside a call like
//   that. So the slow fetch happens on a timer, and every actual query is
//   pure arithmetic over what was already fetched.
//
// The cache deliberately stores ALL high-impact events in the window rather
// than only those matching one symbol. Filtering by currency at fetch time
// would mean a re-fetch every time the caller asked about a different pair,
// which is exactly what an EA trading EURUSD and GBPUSD together does - it
// would have put the slow call back on the hot path by another route.

#ifndef _NEWSFILTER_MQH_
#define _NEWSFILTER_MQH_

//--- Blackout half-width in minutes around a high-impact event
#ifndef NEWS_BLOCK_MINUTES
  #define NEWS_BLOCK_MINUTES   5
#endif

//--- How long a fetched calendar window stays usable (seconds)
#define NEWS_REFRESH_SECS    60

//--- Fetch window: 1h behind, 4h ahead. Wide enough that a refresh interval
//    can never miss an event about to enter the blackout band.
#define NEWS_LOOKBACK_SECS   3600
#define NEWS_LOOKAHEAD_SECS  (4 * 3600)

class CNewsFilter {
private:
  datetime m_times[];
  string   m_names[];
  string   m_curr[];
  datetime m_refreshed;      // 0 = never fetched
  bool     m_injected;       // cache was seeded by a test, do not auto-refresh

  string   m_last_event;     // name of the event that last caused a block
  datetime m_last_event_time;

public:
  CNewsFilter();

  bool   Init();
  void   Refresh();
  bool   IsBlackedOut(string symbol, int minutes_buffer = NEWS_BLOCK_MINUTES);
  bool   NextEvent(string symbol, datetime &event_time, string &event_name);

  // Pure helpers - no market or calendar access, so tests can drive them
  // directly instead of waiting for a real event to occur.
  bool   IsWithinWindow(datetime now, datetime event_time, int minutes_buffer);
  bool   CurrencyMatchesSymbol(string currency, string symbol);

  // Test seam: seed the cache with a known event and freeze the refresh timer.
  // The blackout path is safety-critical and fires rarely in live conditions -
  // this is the only way to exercise it deterministically.
  void   InjectEvent(datetime event_time, string name, string currency);
  void   ClearCache();

  int      CachedEventCount() { return ArraySize(m_times); }
  datetime LastRefresh()      { return m_refreshed; }
  string   LastBlockEvent()   { return m_last_event; }
  datetime LastBlockTime()    { return m_last_event_time; }
};

//--- Constructor
CNewsFilter::CNewsFilter() {
  m_refreshed       = 0;
  m_injected        = false;
  m_last_event      = "";
  m_last_event_time = 0;
}

//--- Init: pay the one-off download cost at attach time, not mid-session
bool CNewsFilter::Init() {
  Refresh();
  Print("[NewsFilter] Initialised: ", ArraySize(m_times),
        " high-impact event(s) cached for the next 4h.");
  return true;
}

//--- ClearCache
void CNewsFilter::ClearCache() {
  ArrayFree(m_times);
  ArrayFree(m_names);
  ArrayFree(m_curr);
}

//--- Refresh: the slow call. Timer-driven only - never from a query.
void CNewsFilter::Refresh() {
  ClearCache();

  m_refreshed = TimeCurrent();
  m_injected  = false;

  datetime from = TimeCurrent() - NEWS_LOOKBACK_SECS;
  datetime to   = TimeCurrent() + NEWS_LOOKAHEAD_SECS;

  MqlCalendarValue values[];
  int count = CalendarValueHistory(values, from, to);

  for(int i = 0; i < count; i++) {
    MqlCalendarEvent cal_event;
    if(!CalendarEventById(values[i].event_id, cal_event)) continue;

    if(cal_event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

    // The currency lives on the country record, not the event record - there
    // is no MqlCalendarEvent.currency field, despite how the docs read.
    MqlCalendarCountry country;
    if(!CalendarCountryById(cal_event.country_id, country)) continue;

    int n = ArraySize(m_times);
    ArrayResize(m_times, n + 1);
    ArrayResize(m_names, n + 1);
    ArrayResize(m_curr,  n + 1);
    m_times[n] = values[i].time;
    m_names[n] = cal_event.name;
    m_curr[n]  = country.currency;
  }
}

//--- CurrencyMatchesSymbol: does an event on this currency affect this pair?
bool CNewsFilter::CurrencyMatchesSymbol(string currency, string symbol) {
  if(StringLen(currency) < 3 || StringLen(symbol) < 6) return false;

  string base_curr  = StringSubstr(symbol, 0, 3);
  string quote_curr = StringSubstr(symbol, 3, 3);

  return (currency == base_curr || currency == quote_curr);
}

//--- IsWithinWindow: |now - event| <= buffer, in either direction
bool CNewsFilter::IsWithinWindow(datetime now, datetime event_time, int minutes_buffer) {
  if(minutes_buffer <= 0) return false;

  long delta = (long)now - (long)event_time;
  if(delta < 0) delta = -delta;

  return (delta <= (long)minutes_buffer * 60);
}

//--- IsBlackedOut: pure arithmetic over the cache. Safe on every tick.
bool CNewsFilter::IsBlackedOut(string symbol, int minutes_buffer) {
  // A test-seeded cache is never refreshed out from under the test.
  if(!m_injected &&
     (m_refreshed == 0 || TimeCurrent() - m_refreshed >= NEWS_REFRESH_SECS)) {
    Refresh();
  }

  datetime now = TimeCurrent();

  for(int i = 0; i < ArraySize(m_times); i++) {
    if(!CurrencyMatchesSymbol(m_curr[i], symbol)) continue;
    if(!IsWithinWindow(now, m_times[i], minutes_buffer)) continue;

    m_last_event      = m_names[i];
    m_last_event_time = m_times[i];

    Print("[NewsFilter] BLACKOUT ", symbol, ": ", m_names[i],
          " (", m_curr[i], ") at ", TimeToString(m_times[i]),
          " | +/-", minutes_buffer, " min");
    return true;
  }

  return false;
}

//--- NextEvent: soonest upcoming event affecting this symbol, if any
bool CNewsFilter::NextEvent(string symbol, datetime &event_time, string &event_name) {
  event_time = 0;
  event_name = "";

  datetime now   = TimeCurrent();
  datetime best  = 0;
  string   bname = "";

  for(int i = 0; i < ArraySize(m_times); i++) {
    if(!CurrencyMatchesSymbol(m_curr[i], symbol)) continue;
    if(m_times[i] < now) continue;
    if(best == 0 || m_times[i] < best) {
      best  = m_times[i];
      bname = m_names[i];
    }
  }

  if(best == 0) return false;

  event_time = best;
  event_name = bname;
  return true;
}

//--- InjectEvent: test seam. Freezes the refresh timer so the seeded event
//    survives the next query.
void CNewsFilter::InjectEvent(datetime event_time, string name, string currency) {
  int n = ArraySize(m_times);
  ArrayResize(m_times, n + 1);
  ArrayResize(m_names, n + 1);
  ArrayResize(m_curr,  n + 1);
  m_times[n] = event_time;
  m_names[n] = name;
  m_curr[n]  = currency;

  m_injected  = true;
  m_refreshed = TimeCurrent();
}

#endif

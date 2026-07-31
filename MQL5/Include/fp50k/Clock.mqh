//+------------------------------------------------------------------+
//| Clock.mqh                                                         |
//| FP50K-EA | Broker clock / UTC reconciliation                      |
//| One definition of "what time is it in UTC", shared by every       |
//| module that has a session boundary to enforce                     |
//+------------------------------------------------------------------+
//
// Every session boundary in this project is written in UTC - the Asian range
// (00:00-07:00), the London gate (07:00-17:00), the Friday flatten (20:00).
// Bar timestamps and TimeCurrent(), however, arrive in BROKER SERVER time.
// Reconciling the two needs the offset between them, and the obvious way to
// get it is TimeCurrent() - TimeGMT().
//
// That is correct live and WRONG inside the Strategy Tester.
//
// Measured on this install, 2026-07-31, from the tester's own log:
//
//   [FP50K] CLOCK | server=2025.01.01 00:00:00 gmt=2025.01.01 00:00:00 offset=0h
//
// In the tester TimeGMT() returns the server clock, so the subtraction yields
// zero and every "UTC" window silently becomes a SERVER-time window. On a
// GMT+2/+3 broker that shifts the Asian session by two to three hours. Nothing
// errors. The backtest simply measures different hours than the code claims,
// and reports the result with full confidence. That defect applied to every
// backtest this project ran before the date above, breakout rounds included.
//
// Hence: the offset is injectable. Live it is auto-detected as before; for a
// backtest it must be supplied, and callers that fail to supply it are warned
// rather than quietly given the wrong session.
//
// This deliberately does NOT compute daylight-saving transitions. The daily
// reset keys off the broker's own date rollover, and on an EET/EEST server
// midnight is 17:00 New York in both DST regimes because the European and US
// clocks shift together. Hand-rolled DST arithmetic would replace something
// true by construction with something that has to be maintained and can drift.

#ifndef _FP50K_CLOCK_MQH_
#define _FP50K_CLOCK_MQH_

//--- Sentinel meaning "work it out from the terminal"
#define FP_UTC_OFFSET_AUTO  -9999

int  g_fp_utc_offset_hours = FP_UTC_OFFSET_AUTO;
bool g_fp_broker_eu_dst    = false;

//+------------------------------------------------------------------+
//| European summer time                                              |
//+------------------------------------------------------------------+
//
// A single fixed offset is not enough for a one-year backtest. This broker
// (FundingPips-SIM1, measured +3h on 2026-07-31) runs EET in winter and EEST in
// summer, so a constant 3 is an hour wrong from November to March - five months
// of a twelve-month run, on a strategy whose entire premise is which hours the
// Asian session covers.
//
// The EU rule is fixed and simple, unlike the US one: summer time runs from the
// LAST Sunday in March to the LAST Sunday in October, switching at 01:00 UTC.
// (The US switches on different weekends, which is why hand-rolled US DST code
// is a common source of one-hour drift. This project does not need it - see the
// header note on why the daily reset needs no DST arithmetic at all.)

//--- Day-of-month of the last Sunday. March and October both have 31 days.
int FpLastSundayOfMonth(int year, int month) {
  MqlDateTime dt;
  dt.year = year; dt.mon = month; dt.day = 31;
  dt.hour = 0;    dt.min = 0;     dt.sec = 0;
  dt.day_of_week = 0; dt.day_of_year = 0;

  datetime t = StructToTime(dt);
  TimeToStruct(t, dt);

  // day_of_week is 0 for Sunday, so subtracting it walks back to the last one.
  return 31 - dt.day_of_week;
}

//--- Is European summer time in force at this moment?
//
//    The argument is broker server time, not UTC. Using UTC would be circular -
//    converting to UTC is what needs the answer. The two differ by two or three
//    hours, so the verdict is only ambiguous within a few hours of the two
//    switchover instants each year, which is a handful of bars out of a year
//    and cannot move a result the way a permanent one-hour shift does.
bool FpEuDstActive(datetime server_time) {
  MqlDateTime dt;
  TimeToStruct(server_time, dt);

  if(dt.mon < 3  || dt.mon > 10) return false;   // Nov-Feb: winter
  if(dt.mon > 3  && dt.mon < 10) return true;    // Apr-Sep: summer

  int last_sunday = FpLastSundayOfMonth(dt.year, dt.mon);

  if(dt.mon == 3)   // March: summer starts on the last Sunday
    return (dt.day > last_sunday || (dt.day == last_sunday && dt.hour >= 1));

  // October: summer ends on the last Sunday
  return (dt.day < last_sunday || (dt.day == last_sunday && dt.hour < 1));
}

//--- Treat the configured offset as a WINTER baseline, adding an hour through
//    European summer time. This is what an EET/EEST broker actually does.
void FpSetBrokerEuDst(bool on) { g_fp_broker_eu_dst = on; }
bool FpBrokerEuDst()           { return g_fp_broker_eu_dst; }

//--- Override the offset, in whole hours ahead of UTC (EET = 2, EEST = 3).
void FpSetUtcOffsetHours(int hours) { g_fp_utc_offset_hours = hours; }

//--- Whether an override is currently in force.
bool FpUtcOffsetIsOverridden() { return (g_fp_utc_offset_hours != FP_UTC_OFFSET_AUTO); }

//--- What the terminal thinks the offset is. Reliable live, zero in the tester.
int FpUtcOffsetDetectedSecs() { return (int)(TimeCurrent() - TimeGMT()); }

//--- Seconds the broker server clock leads UTC, honouring any override.
//    With EU DST enabled the override is the WINTER offset and an hour is added
//    through European summer time.
int FpUtcOffsetSecs() {
  if(!FpUtcOffsetIsOverridden()) return FpUtcOffsetDetectedSecs();

  int hours = g_fp_utc_offset_hours;
  if(g_fp_broker_eu_dst && FpEuDstActive(TimeCurrent())) hours += 1;
  return hours * 3600;
}

//--- Now, in UTC, whatever the server clock happens to say.
datetime FpNowUtc() { return TimeCurrent() - FpUtcOffsetSecs(); }

#endif

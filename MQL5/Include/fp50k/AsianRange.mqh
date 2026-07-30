//+------------------------------------------------------------------+
//| AsianRange.mqh                                                    |
//| FP50K-EA | Asian Range Calculator                                 |
//| Marks 00:00-07:00 UTC session high/low                            |
//| London open breakout + retest detection                           |
//+------------------------------------------------------------------+

#ifndef _ASIANRANGE_MQH_
#define _ASIANRANGE_MQH_

//--- Session bounds (UTC)
#define ASIAN_START_HOUR   0    // 00:00 UTC
#define ASIAN_END_HOUR     7    // 07:00 UTC

//--- Range quality filters (pips)
#define MIN_RANGE_PIPS     10   // Ignore days with a tiny range - no edge
#define MAX_RANGE_PIPS     80   // Ignore gap/spike days - stop would be too wide
#define RETEST_TOLERANCE   3    // How close price must hold to the broken level

class CAsianRange {
private:
  double   m_high;         // Asian session highest high
  double   m_low;          // Asian session lowest low
  double   m_range_pips;   // Range size in pips
  bool     m_range_valid;  // Within MIN/MAX bounds
  bool     m_range_set;    // Today's range has been calculated
  datetime m_range_date;   // UTC date the range was set (for daily reset)
  string   m_symbol;       // Symbol this instance tracks

  double   PipSize(string symbol);
  datetime UtcDayStart();
  int      ServerUtcOffset();

public:
  CAsianRange();

  bool   Init(string symbol);
  void   Reset();
  void   OnNewBar(string symbol);
  void   CalculateRange(string symbol);

  bool   IsBreakoutUp(double close_price);
  bool   IsBreakoutDown(double close_price);
  bool   IsRetestHold(double current_price, bool was_breakout_up);

  double GetRangeHigh()  { return m_high; }
  double GetRangeLow()   { return m_low; }
  double GetRangePips()  { return m_range_pips; }
  bool   IsRangeValid()  { return m_range_valid; }
  bool   IsRangeSet()    { return m_range_set; }

  double GetTargetUp(double rr_ratio = 2.0);
  double GetTargetDown(double rr_ratio = 2.0);

  string ToString();
};

//--- Constructor
CAsianRange::CAsianRange() {
  m_symbol = "";
  Reset();
}

//--- Init: bind this instance to a symbol
bool CAsianRange::Init(string symbol) {
  m_symbol = symbol;
  Reset();
  Print("[AsianRange] Initialized for ", symbol);
  return true;
}

//--- Reset: clear today's range
void CAsianRange::Reset() {
  m_high        = 0.0;
  m_low         = 0.0;
  m_range_pips  = 0.0;
  m_range_valid = false;
  m_range_set   = false;
  m_range_date  = 0;
}

//--- PipSize: one pip in price terms (JPY pairs quote to 3 decimals, others 5)
double CAsianRange::PipSize(string symbol) {
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if(point <= 0.0) return 0.0;

  if(StringFind(symbol, "JPY") >= 0) return point * 100.0;
  return point * 10.0;
}

//--- ServerUtcOffset: seconds the broker's server clock leads UTC.
//    Bar timestamps come back in server time but the Asian session is defined
//    in UTC, so the two must be reconciled before any hour comparison.
int CAsianRange::ServerUtcOffset() {
  return (int)(TimeCurrent() - TimeGMT());
}

//--- UtcDayStart: today's 00:00 UTC
datetime CAsianRange::UtcDayStart() {
  MqlDateTime gmt;
  TimeToStruct(TimeGMT(), gmt);
  gmt.hour = 0;
  gmt.min  = 0;
  gmt.sec  = 0;
  return StructToTime(gmt);
}

//--- OnNewBar: call on each new H1 bar
void CAsianRange::OnNewBar(string symbol) {
  datetime today = UtcDayStart();

  // New UTC day - throw away yesterday's range
  if(m_range_date != today) {
    Reset();
    m_range_date = today;
  }

  MqlDateTime gmt;
  TimeToStruct(TimeGMT(), gmt);

  // Once the Asian session has closed, measure it (once per day)
  if(gmt.hour >= ASIAN_END_HOUR && !m_range_set) {
    CalculateRange(symbol);
  }
}

//--- CalculateRange: scan H1 bars inside [00:00, 07:00) UTC
void CAsianRange::CalculateRange(string symbol) {
  double pip = PipSize(symbol);
  if(pip <= 0.0) {
    Print("[AsianRange] ERROR: cannot resolve pip size for ", symbol);
    return;
  }

  int      offset    = ServerUtcOffset();
  datetime day_start = UtcDayStart();

  // Window boundaries converted into broker server time
  datetime win_start = day_start + ASIAN_START_HOUR * 3600 + offset;
  datetime win_end   = day_start + ASIAN_END_HOUR   * 3600 + offset;

  double hi = 0.0, lo = 0.0;
  int    bars_found = 0;

  // 200 H1 bars back covers a full day plus weekend gaps
  for(int shift = 0; shift < 200; shift++) {
    datetime bar_time = iTime(symbol, PERIOD_H1, shift);
    if(bar_time <= 0) break;

    // Walked past the start of the window - nothing older can qualify
    if(bar_time < win_start) break;

    if(bar_time >= win_end) continue;

    double bar_high = iHigh(symbol, PERIOD_H1, shift);
    double bar_low  = iLow(symbol, PERIOD_H1, shift);
    if(bar_high <= 0.0 || bar_low <= 0.0) continue;

    if(bars_found == 0) {
      hi = bar_high;
      lo = bar_low;
    } else {
      if(bar_high > hi) hi = bar_high;
      if(bar_low  < lo) lo = bar_low;
    }
    bars_found++;
  }

  if(bars_found == 0) {
    Print("[AsianRange] ", symbol, ": no H1 bars found in 00:00-07:00 UTC window - range unset");
    return;
  }

  m_high        = hi;
  m_low         = lo;
  m_range_pips  = (hi - lo) / pip;
  m_range_valid = (m_range_pips >= MIN_RANGE_PIPS && m_range_pips <= MAX_RANGE_PIPS);
  m_range_set   = true;
  m_range_date  = day_start;

  Print("[AsianRange] ", symbol, ": High=", DoubleToString(m_high, _Digits),
        " Low=", DoubleToString(m_low, _Digits),
        " Range=", DoubleToString(m_range_pips, 1), "pips",
        " Bars=", bars_found,
        " Valid=", (m_range_valid ? "true" : "false"));
}

//--- IsBreakoutUp: closed above the Asian high
bool CAsianRange::IsBreakoutUp(double close_price) {
  if(!m_range_valid) return false;
  return (close_price > m_high);
}

//--- IsBreakoutDown: closed below the Asian low
bool CAsianRange::IsBreakoutDown(double close_price) {
  if(!m_range_valid) return false;
  return (close_price < m_low);
}

//--- IsRetestHold: price pulled back to the broken level but held the break
bool CAsianRange::IsRetestHold(double current_price, bool was_breakout_up) {
  if(!m_range_valid) return false;

  double pip = PipSize(m_symbol);
  if(pip <= 0.0) return false;

  double tolerance = RETEST_TOLERANCE * pip;

  if(was_breakout_up) {
    // Still above the high, but within tolerance of it
    return (current_price > m_high && current_price - m_high <= tolerance);
  }

  // Still below the low, but within tolerance of it
  return (current_price < m_low && m_low - current_price <= tolerance);
}

//--- GetTargetUp: long take-profit, rr_ratio multiples of the range above the high
double CAsianRange::GetTargetUp(double rr_ratio) {
  double pip = PipSize(m_symbol);
  if(pip <= 0.0) return 0.0;
  return m_high + (m_range_pips * rr_ratio * pip);
}

//--- GetTargetDown: short take-profit, rr_ratio multiples of the range below the low
double CAsianRange::GetTargetDown(double rr_ratio) {
  double pip = PipSize(m_symbol);
  if(pip <= 0.0) return 0.0;
  return m_low - (m_range_pips * rr_ratio * pip);
}

//--- ToString: one-line summary for logging
string CAsianRange::ToString() {
  return StringFormat("AsianRange[%s] high=%s low=%s range=%.1fpips set=%s valid=%s",
                      m_symbol,
                      DoubleToString(m_high, _Digits),
                      DoubleToString(m_low, _Digits),
                      m_range_pips,
                      (m_range_set   ? "true" : "false"),
                      (m_range_valid ? "true" : "false"));
}

#endif

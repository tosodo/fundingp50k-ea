//+------------------------------------------------------------------+
//| SignalEngine.mqh                                                  |
//| FP50K-EA | Signal Engine                                          |
//| Wires AsianRange with an H4 trend filter                          |
//| Returns a structured signal - never self-executes                 |
//+------------------------------------------------------------------+

#ifndef _SIGNALENGINE_MQH_
#define _SIGNALENGINE_MQH_

#include "AsianRange.mqh"

//--- Trend states
#define TREND_BULL        1
#define TREND_BEAR       -1
#define TREND_AMBIGUOUS   0

//--- H4 trend filter
#define H4_MA_PERIOD     50

//--- Stop placed this far beyond the far side of the range
#define SL_BUFFER_PIPS    2.0

//--- Session bounds (UTC) - mirrors the RiskManager gate
#define SIG_SESSION_OPEN_HOUR   7
#define SIG_SESSION_CLOSE_HOUR  17

//+------------------------------------------------------------------+
//| SSignal - a proposed trade. Always check .valid first.            |
//+------------------------------------------------------------------+
struct SSignal {
  bool     valid;        // Signal is actionable - check this first
  bool     is_long;      // true=buy, false=sell
  double   entry_price;  // Suggested entry (Ask for long, Bid for short)
  double   stop_loss;    // Absolute SL price
  double   take_profit;  // Absolute TP price
  double   sl_pips;      // SL distance in pips (feeds RiskManager lot sizing)
  double   risk_usd;     // Recommended risk amount
  string   symbol;       // Which pair generated the signal
  string   reason;       // Human-readable description
  datetime signal_time;  // When the signal was generated

  SSignal() {
    valid       = false;
    is_long     = false;
    entry_price = 0.0;
    stop_loss   = 0.0;
    take_profit = 0.0;
    sl_pips     = 0.0;
    risk_usd    = 500.0;
    symbol      = "";
    reason      = "";
    signal_time = 0;
  }
};

//+------------------------------------------------------------------+
//| CSignalEngine                                                     |
//+------------------------------------------------------------------+
class CSignalEngine {
private:
  CAsianRange m_asian_range;
  double      m_rr_ratio;
  double      m_risk_usd;
  string      m_symbol;

  // Indicator handles are a finite resource - create once, reuse, release.
  int         m_ma_handle;

  double      PipSize(string symbol);
  SSignal     Invalid(string symbol, string reason);

public:
  CSignalEngine();
  ~CSignalEngine();

  bool    Init(string symbol, double risk_usd = 500.0, double rr = 2.0);
  void    OnNewBar(string symbol);
  SSignal CheckSignal(string symbol);
  int     GetH4Trend(string symbol);
  bool    IsLondonSession();

  // Pure entry geometry: every input is passed in, nothing is read from the
  // market. CheckSignal() feeds it live values; tests feed it fixed ones, which
  // is the only way to exercise stop/target placement without waiting for a
  // real breakout to occur.
  SSignal BuildSignal(string symbol, bool is_long,
                      double range_high, double range_low, double range_pips,
                      double ask, double bid, double pip, double rr);

  CAsianRange *Range() { return GetPointer(m_asian_range); }
};

//--- Constructor
CSignalEngine::CSignalEngine() {
  m_rr_ratio  = 2.0;
  m_risk_usd  = 500.0;
  m_symbol    = "";
  m_ma_handle = INVALID_HANDLE;
}

//--- Destructor
CSignalEngine::~CSignalEngine() {
  if(m_ma_handle != INVALID_HANDLE) {
    IndicatorRelease(m_ma_handle);
    m_ma_handle = INVALID_HANDLE;
  }
}

//--- Init
bool CSignalEngine::Init(string symbol, double risk_usd, double rr) {
  m_symbol   = symbol;
  m_risk_usd = risk_usd;
  m_rr_ratio = rr;

  m_asian_range.Init(symbol);

  // MQL5 returns an indicator HANDLE here, not a value - the reading itself
  // comes from CopyBuffer() later. Created once so repeated signal checks
  // don't leak handles.
  m_ma_handle = iMA(symbol, PERIOD_H4, H4_MA_PERIOD, 0, MODE_SMA, PRICE_CLOSE);
  if(m_ma_handle == INVALID_HANDLE) {
    Print("[SignalEngine] ERROR: could not create H4 MA handle for ", symbol);
    return false;
  }

  Print("[SignalEngine] Initialized ", symbol,
        " risk=$", DoubleToString(m_risk_usd, 2),
        " rr=", DoubleToString(m_rr_ratio, 1));
  return true;
}

//--- PipSize
double CSignalEngine::PipSize(string symbol) {
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if(point <= 0.0) return 0.0;

  if(StringFind(symbol, "JPY") >= 0) return point * 100.0;
  return point * 10.0;
}

//--- Invalid: build a rejected signal carrying the reason
SSignal CSignalEngine::Invalid(string symbol, string reason) {
  SSignal s;
  s.valid       = false;
  s.symbol      = symbol;
  s.reason      = reason;
  s.risk_usd    = m_risk_usd;
  s.signal_time = TimeCurrent();
  return s;
}

//--- OnNewBar: pass through to the range calculator
void CSignalEngine::OnNewBar(string symbol) {
  m_asian_range.OnNewBar(symbol);
}

//--- IsLondonSession: 07:00-17:00 UTC, Monday to Friday
bool CSignalEngine::IsLondonSession() {
  MqlDateTime dt;
  TimeToStruct(TimeGMT(), dt);

  if(dt.day_of_week < 1 || dt.day_of_week > 5) return false;
  if(dt.hour < SIG_SESSION_OPEN_HOUR || dt.hour >= SIG_SESSION_CLOSE_HOUR) return false;

  return true;
}

//--- GetH4Trend: 1 = bullish, -1 = bearish, 0 = ambiguous.
//    Ambiguity is a first-class answer here: a mixed H4 picture is exactly
//    when a breakout is most likely to be noise, so it must not be forced
//    into a bull/bear bucket.
int CSignalEngine::GetH4Trend(string symbol) {
  if(m_ma_handle == INVALID_HANDLE) return TREND_AMBIGUOUS;

  double c0 = iClose(symbol, PERIOD_H4, 0);
  double c1 = iClose(symbol, PERIOD_H4, 1);
  double c2 = iClose(symbol, PERIOD_H4, 2);

  if(c0 <= 0.0 || c1 <= 0.0 || c2 <= 0.0) return TREND_AMBIGUOUS;

  double ma[];
  if(CopyBuffer(m_ma_handle, 0, 0, 1, ma) < 1) {
    Print("[SignalEngine] H4 MA not ready for ", symbol, " - treating trend as ambiguous");
    return TREND_AMBIGUOUS;
  }

  double ma_now = ma[0];

  bool bullish = (c0 > c1 && c1 > c2 && c0 > ma_now);
  bool bearish = (c0 < c1 && c1 < c2 && c0 < ma_now);

  if(bullish) return TREND_BULL;
  if(bearish) return TREND_BEAR;

  return TREND_AMBIGUOUS;
}

//--- BuildSignal: pure entry geometry - no market access, fully testable
SSignal CSignalEngine::BuildSignal(string symbol, bool is_long,
                                   double range_high, double range_low, double range_pips,
                                   double ask, double bid, double pip, double rr) {
  if(pip <= 0.0)
    return Invalid(symbol, "Cannot resolve pip size");

  if(ask <= 0.0 || bid <= 0.0)
    return Invalid(symbol, "No live quote available");

  if(range_high <= range_low)
    return Invalid(symbol, "Range high is not above range low");

  SSignal s;
  s.valid       = true;
  s.is_long     = is_long;
  s.symbol      = symbol;
  s.risk_usd    = m_risk_usd;
  s.signal_time = TimeCurrent();

  if(is_long) {
    s.entry_price = ask;
    s.stop_loss   = range_low - (SL_BUFFER_PIPS * pip);
    s.take_profit = range_high + (range_pips * rr * pip);
    s.sl_pips     = (s.entry_price - s.stop_loss) / pip;
  } else {
    s.entry_price = bid;
    s.stop_loss   = range_high + (SL_BUFFER_PIPS * pip);
    s.take_profit = range_low - (range_pips * rr * pip);
    s.sl_pips     = (s.stop_loss - s.entry_price) / pip;
  }

  // A non-positive stop distance means price crossed the level between the
  // breakout check and the quote read - reject rather than send a broken order.
  if(s.sl_pips <= 0.0)
    return Invalid(symbol, "Computed stop distance is not positive");

  s.reason = StringFormat("Asian breakout + retest confirmed | Range: %.1fpips | Dir: %s",
                          range_pips, (is_long ? "LONG" : "SHORT"));

  return s;
}

//--- CheckSignal: the full entry sequence. Returns a struct; never trades.
SSignal CSignalEngine::CheckSignal(string symbol) {
  // 1. Session
  if(!IsLondonSession())
    return Invalid(symbol, "Outside session");

  // 2. Range quality
  if(!m_asian_range.IsRangeValid())
    return Invalid(symbol, "Range invalid");

  // 3. H4 trend
  int trend = GetH4Trend(symbol);
  if(trend == TREND_AMBIGUOUS)
    return Invalid(symbol, "H4 trend ambiguous");

  // 4. Last CLOSED H1 bar - bar 0 is still forming and would repaint
  double close = iClose(symbol, PERIOD_H1, 1);
  if(close <= 0.0)
    return Invalid(symbol, "No H1 close available");

  // 5. Breakout in the direction of the H4 trend
  bool breakout_up   = (trend == TREND_BULL && m_asian_range.IsBreakoutUp(close));
  bool breakout_down = (trend == TREND_BEAR && m_asian_range.IsBreakoutDown(close));

  if(!breakout_up && !breakout_down)
    return Invalid(symbol, "No breakout or direction mismatch");

  double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
  if(ask <= 0.0 || bid <= 0.0)
    return Invalid(symbol, "No live quote available");

  // 6. Retest - price must have come back to the broken level and held it
  bool holding = breakout_up ? m_asian_range.IsRetestHold(bid, true)
                             : m_asian_range.IsRetestHold(ask, false);
  if(!holding)
    return Invalid(symbol, "No retest confirmation");

  // 7. Populate the signal from the pure geometry helper
  SSignal s = BuildSignal(symbol, breakout_up,
                          m_asian_range.GetRangeHigh(),
                          m_asian_range.GetRangeLow(),
                          m_asian_range.GetRangePips(),
                          ask, bid, PipSize(symbol), m_rr_ratio);
  if(!s.valid) return s;

  // 8. Log
  Print("[SignalEngine] SIGNAL ", (s.is_long ? "LONG " : "SHORT "), symbol,
        " entry=", DoubleToString(s.entry_price, _Digits),
        " sl=",    DoubleToString(s.stop_loss,   _Digits),
        " tp=",    DoubleToString(s.take_profit, _Digits),
        " sl_pips=", DoubleToString(s.sl_pips, 1),
        " risk=$",   DoubleToString(s.risk_usd, 2),
        " | ", s.reason);

  return s;
}

#endif

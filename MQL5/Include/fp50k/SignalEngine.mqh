//+------------------------------------------------------------------+
//| SignalEngine.mqh                                                  |
//| FP50K-EA | Signal Engine                                          |
//| Asian Liquidity Sweep & Fade, with an H4 EMA bias filter          |
//| Returns a structured signal - never self-executes                 |
//+------------------------------------------------------------------+
//
// Why this file changed shape in July 2026:
//
//   The original entry was an Asian-range BREAKOUT plus retest. Twenty
//   backtest variants established that it had no edge - with all trade
//   management stripped away it won 24.6-30.7% at 2:1, against the 33.3%
//   needed just to break even, and 45.8% at 1:1 against the 50% needed. The
//   losses were not coming from the exits; the entry simply did not predict
//   direction. See Docs/backtest_results.md for the full evidence.
//
//   The replacement is the opposite trade. Instead of buying the break of the
//   Asian high, it SELLS a poke above the Asian high that fails and closes
//   back inside the range - the classic stop-run, where the move exists to
//   collect resting orders rather than to go anywhere. The premise is testable
//   and, importantly, it is not a tuned version of the old idea: it trades in
//   the other direction, so a flat result here is genuine new information.
//
//   The breakout path is kept, unchanged, behind ENTRY_MODE_BREAKOUT. It is
//   the control. A new signal that cannot beat a known-worthless one on the
//   same data has not been demonstrated to work.

#ifndef _SIGNALENGINE_MQH_
#define _SIGNALENGINE_MQH_

#include "AsianRange.mqh"

//--- Trend states
#define TREND_BULL        1
#define TREND_BEAR       -1
#define TREND_AMBIGUOUS   0

//--- H4 trend filter
#define H4_MA_PERIOD     50
#define H4_EMA_PERIOD    50

//--- Stop placed this far beyond the far side of the range
#define SL_BUFFER_PIPS    2.0

//--- Session bounds (UTC) - mirrors the RiskManager gate
#define SIG_SESSION_OPEN_HOUR   7
#define SIG_SESSION_CLOSE_HOUR  17

//+------------------------------------------------------------------+
//| Sweep & fade defaults                                             |
//+------------------------------------------------------------------+
//--- How far past the range edge counts as a sweep rather than a graze.
//    Below this the "sweep" is inside the spread and means nothing.
#define SWEEP_MIN_PIPS        3.0

//--- Stop goes this far beyond the sweeping candle's extreme wick. The wick is
//    the level the market has just proved it will not hold; the buffer covers
//    the spread on the exit side.
#define SWEEP_SL_BUFFER_PIPS  2.0

//--- Volatility coiling filter. A fade needs a range that has compressed; a
//    wide Asian session usually means a trend is already running, and fading a
//    trend is how an account dies.
#define SWEEP_MIN_RANGE_PIPS  8.0
#define SWEEP_MAX_RANGE_PIPS  40.0

//--- ...and the same idea expressed relative to recent volatility, so it keeps
//    meaning something if the pair's character changes.
#define SWEEP_ATR_FRACTION    0.60
#define ATR_D1_PERIOD         14

//--- Trigger timeframe for the sweep itself
#define SWEEP_TIMEFRAME       PERIOD_M5

//+------------------------------------------------------------------+
//| Which entry model the engine is running                           |
//+------------------------------------------------------------------+
enum ENTRY_MODE {
  ENTRY_MODE_SWEEP    = 0,   // Asian liquidity sweep & fade (current)
  ENTRY_MODE_BREAKOUT = 1    // Legacy Asian breakout + retest (control)
};

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

  // Entry geometry. Both default to the original behaviour so an engine that
  // is never configured trades exactly as it did before these existed.
  double      m_stop_range_frac;  // 0 = stop at the far side of the range
  bool        m_consistent_tp;    // false = target measured from the range

  // Indicator handles are a finite resource - create once, reuse, release.
  int         m_ma_handle;       // H4 SMA(50) - legacy breakout trend filter
  int         m_ema_handle;      // H4 EMA(50) - sweep & fade bias filter
  int         m_atr_d1_handle;   // D1 ATR(14) - volatility coiling filter

  //--- Sweep & fade configuration
  ENTRY_MODE  m_mode;
  double      m_sweep_min_pips;
  double      m_sweep_sl_buffer;
  double      m_range_min_pips;
  double      m_range_max_pips;
  double      m_range_atr_frac;

  //--- Hunt window in UTC hours: when sweeps are looked for. Separate from the
  //    contraction window, and settable for the same reason - which hours a
  //    fade works in is a question the data answers, not a constant.
  int         m_hunt_open_hour;
  int         m_hunt_close_hour;

  //--- Assumed adverse fill, in pips. The Strategy Tester fills at the exact
  //    quote, which no live account ever does. Charging this against the
  //    geometry makes a backtest cost what a real fill costs.
  double      m_slippage_pips;

  //--- One evaluation per closed M5 bar. Without this the same sweep is
  //    re-detected on every tick until the bar rolls, which in the tester
  //    silently multiplies one setup into hundreds.
  datetime    m_last_sweep_bar;

  double      PipSize(string symbol);
  SSignal     Invalid(string symbol, string reason);
  double      AtrPips(string symbol);

public:
  CSignalEngine();
  ~CSignalEngine();

  bool    Init(string symbol, double risk_usd = 375.0, double rr = 2.5);

  // Optional geometry override, applied after Init(). Left alone, the engine
  // keeps the original range-width stop and range-measured target.
  void    SetGeometry(double stop_range_frac, bool consistent_tp);

  //--- Sweep & fade configuration. All optional; the defaults above apply.
  void    SetMode(ENTRY_MODE mode);
  void    SetSweepParams(double sweep_min_pips, double sl_buffer_pips,
                         double range_min_pips, double range_max_pips,
                         double range_atr_frac);
  void    SetExecution(double slippage_pips);

  //--- Contraction window (delegated to the range) and hunt window, UTC hours.
  void    SetSessionWindows(int asian_start, int asian_end,
                            int hunt_open, int hunt_close);
  int     HuntOpenHour()  { return m_hunt_open_hour; }
  int     HuntCloseHour() { return m_hunt_close_hour; }

  //--- Pure window test, so the wrap-around case can be driven directly rather
  //    than by waiting for the clock to reach the awkward hour.
  static bool HourInWindow(int hour, int open_hour, int close_hour) {
    if(open_hour == close_hour) return false;            // empty, not all-day
    if(open_hour < close_hour)  return (hour >= open_hour && hour < close_hour);
    return (hour >= open_hour || hour < close_hour);     // crosses midnight
  }

  void    OnNewBar(string symbol);
  SSignal CheckSignal(string symbol);
  SSignal CheckSweepSignal(string symbol);
  SSignal CheckBreakoutSignal(string symbol);
  int     GetH4Trend(string symbol);
  int     GetH4Bias(string symbol);
  bool    IsLondonSession();

  //--- Pure sweep detection. Everything the rule needs is an argument, so a
  //    test can present a synthetic candle instead of waiting for a real
  //    stop-run to happen on a live chart.

  //--- Threshold tolerance. Prices are binary floating point: 1.1003 - 1.1000
  //    evaluates to 0.00029999999999996696, which divides out to 2.9999999999
  //    pips and fails a ">= 3.0" test. Without this slack a poke of exactly the
  //    configured depth is rejected roughly half the time, depending on where
  //    the two prices happen to land in binary - a filter that silently drops
  //    valid setups for no reason a chart would ever show.
  //    1e-6 of a pip is far below any price move that exists.
  #define SWEEP_PIP_EPSILON  1e-6

  //--- A sell setup: the candle poked above the range high by at least
  //    min_sweep_pips, then closed back below it. Both halves are required -
  //    a poke that closes outside is a breakout, which is the opposite trade.
  static bool IsSweepAbove(double bar_high, double bar_close,
                           double range_high, double pip, double min_sweep_pips) {
    if(pip <= 0.0 || range_high <= 0.0) return false;
    if(bar_high <= 0.0 || bar_close <= 0.0) return false;

    bool poked  = ((bar_high - range_high) / pip) >= (min_sweep_pips - SWEEP_PIP_EPSILON);
    bool closed_back = (bar_close < range_high);
    return (poked && closed_back);
  }

  //--- A buy setup: the mirror image below the range low.
  static bool IsSweepBelow(double bar_low, double bar_close,
                           double range_low, double pip, double min_sweep_pips) {
    if(pip <= 0.0 || range_low <= 0.0) return false;
    if(bar_low <= 0.0 || bar_close <= 0.0) return false;

    bool poked  = ((range_low - bar_low) / pip) >= (min_sweep_pips - SWEEP_PIP_EPSILON);
    bool closed_back = (bar_close > range_low);
    return (poked && closed_back);
  }

  //--- Volatility coiling. Both the absolute pip band and the ATR ratio must
  //    hold. An atr_pips of zero means the daily ATR is unavailable, in which
  //    case the ratio test is skipped rather than silently failing everything.
  static bool RangeVolatilityOk(double range_pips, double atr_pips,
                                double min_pips, double max_pips, double atr_frac) {
    if(range_pips < min_pips || range_pips > max_pips) return false;
    if(atr_pips > 0.0 && atr_frac > 0.0 && range_pips > atr_pips * atr_frac)
      return false;
    return true;
  }

  //--- Pure sweep geometry. Stop sits beyond the sweeping wick, target is a
  //    fixed multiple of that stop measured from the entry - so the nominal
  //    R:R is the R:R actually delivered, which the old range-measured target
  //    was not. slippage_pips shifts the reference price against us before
  //    anything is measured, so the stop lands nearer and the target further.
  SSignal BuildSweepSignal(string symbol, bool is_long,
                           double sweep_high, double sweep_low,
                           double ask, double bid, double pip, double rr,
                           double sl_buffer_pips, double slippage_pips);

  // Pure entry geometry: every input is passed in, nothing is read from the
  // market. CheckSignal() feeds it live values; tests feed it fixed ones, which
  // is the only way to exercise stop/target placement without waiting for a
  // real breakout to occur.
  //
  // The two trailing parameters default to the original geometry, so existing
  // callers and tests that pass nine arguments are unaffected.
  SSignal BuildSignal(string symbol, bool is_long,
                      double range_high, double range_low, double range_pips,
                      double ask, double bid, double pip, double rr,
                      double stop_range_frac = 0.0, bool consistent_tp = false);

  CAsianRange *Range() { return GetPointer(m_asian_range); }
};

//--- Constructor
CSignalEngine::CSignalEngine() {
  m_rr_ratio        = 2.5;
  m_risk_usd        = 375.0;
  m_symbol          = "";
  m_ma_handle       = INVALID_HANDLE;
  m_ema_handle      = INVALID_HANDLE;
  m_atr_d1_handle   = INVALID_HANDLE;
  m_stop_range_frac = 0.0;
  m_consistent_tp   = false;

  m_mode            = ENTRY_MODE_SWEEP;
  m_sweep_min_pips  = SWEEP_MIN_PIPS;
  m_sweep_sl_buffer = SWEEP_SL_BUFFER_PIPS;
  m_range_min_pips  = SWEEP_MIN_RANGE_PIPS;
  m_range_max_pips  = SWEEP_MAX_RANGE_PIPS;
  m_range_atr_frac  = SWEEP_ATR_FRACTION;
  m_slippage_pips   = 0.0;
  m_last_sweep_bar  = 0;
  m_hunt_open_hour  = SIG_SESSION_OPEN_HOUR;
  m_hunt_close_hour = SIG_SESSION_CLOSE_HOUR;
}

//--- SetSessionWindows: contraction window and hunt window, both UTC hours.
void CSignalEngine::SetSessionWindows(int asian_start, int asian_end,
                                      int hunt_open, int hunt_close) {
  m_asian_range.SetWindow(asian_start, asian_end);

  if(hunt_open < 0 || hunt_open > 23 || hunt_close < 0 || hunt_close > 23) {
    Print("[SignalEngine] ERROR: hunt window ", hunt_open, "-", hunt_close,
          " is outside 0-23. Keeping ", m_hunt_open_hour, "-", m_hunt_close_hour, ".");
    return;
  }
  if(hunt_open == hunt_close) {
    Print("[SignalEngine] ERROR: hunt window ", hunt_open, "-", hunt_close,
          " is empty - that would disable the strategy silently. Keeping ",
          m_hunt_open_hour, "-", m_hunt_close_hour, ".");
    return;
  }

  m_hunt_open_hour  = hunt_open;
  m_hunt_close_hour = hunt_close;

  Print("[SignalEngine] Sessions ", m_symbol,
        " | contraction ", asian_start, ":00-", asian_end, ":00 UTC",
        " | hunt ", m_hunt_open_hour, ":00-", m_hunt_close_hour, ":00 UTC");
}

//--- Destructor
CSignalEngine::~CSignalEngine() {
  if(m_ma_handle != INVALID_HANDLE) {
    IndicatorRelease(m_ma_handle);
    m_ma_handle = INVALID_HANDLE;
  }
  if(m_ema_handle != INVALID_HANDLE) {
    IndicatorRelease(m_ema_handle);
    m_ema_handle = INVALID_HANDLE;
  }
  if(m_atr_d1_handle != INVALID_HANDLE) {
    IndicatorRelease(m_atr_d1_handle);
    m_atr_d1_handle = INVALID_HANDLE;
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

  m_ema_handle = iMA(symbol, PERIOD_H4, H4_EMA_PERIOD, 0, MODE_EMA, PRICE_CLOSE);
  if(m_ema_handle == INVALID_HANDLE) {
    Print("[SignalEngine] ERROR: could not create H4 EMA handle for ", symbol);
    return false;
  }

  // The daily ATR is a filter, not a trigger. If the broker has no daily
  // history the volatility ratio is skipped and the pip band still applies -
  // refusing to start over a missing filter would be worse than running
  // slightly less selectively.
  m_atr_d1_handle = iATR(symbol, PERIOD_D1, ATR_D1_PERIOD);
  if(m_atr_d1_handle == INVALID_HANDLE)
    Print("[SignalEngine] WARNING: no D1 ATR handle for ", symbol,
          " - the ATR coiling filter will be skipped.");

  m_last_sweep_bar = 0;

  Print("[SignalEngine] Initialized ", symbol,
        " mode=", (m_mode == ENTRY_MODE_SWEEP ? "SWEEP-FADE" : "BREAKOUT"),
        " risk=$", DoubleToString(m_risk_usd, 2),
        " rr=", DoubleToString(m_rr_ratio, 2));
  return true;
}

//--- SetMode: choose the entry model. The breakout is retained as a control.
void CSignalEngine::SetMode(ENTRY_MODE mode) {
  m_mode = mode;
  Print("[SignalEngine] Entry mode ", m_symbol, " = ",
        (m_mode == ENTRY_MODE_SWEEP ? "SWEEP-FADE (fade the failed poke)"
                                    : "BREAKOUT (legacy control)"));
}

//--- SetSweepParams: a non-positive value leaves that parameter at its default,
//    so a caller can override one setting without restating all five.
void CSignalEngine::SetSweepParams(double sweep_min_pips, double sl_buffer_pips,
                                   double range_min_pips, double range_max_pips,
                                   double range_atr_frac) {
  if(sweep_min_pips > 0.0) m_sweep_min_pips  = sweep_min_pips;
  if(sl_buffer_pips > 0.0) m_sweep_sl_buffer = sl_buffer_pips;
  if(range_min_pips > 0.0) m_range_min_pips  = range_min_pips;
  if(range_max_pips > 0.0) m_range_max_pips  = range_max_pips;

  // Zero is meaningful here: it switches the ATR ratio filter off.
  if(range_atr_frac >= 0.0) m_range_atr_frac = range_atr_frac;

  Print("[SignalEngine] Sweep params ", m_symbol,
        " min_sweep=", DoubleToString(m_sweep_min_pips, 1), "p",
        " sl_buffer=", DoubleToString(m_sweep_sl_buffer, 1), "p",
        " range=", DoubleToString(m_range_min_pips, 1), "-",
        DoubleToString(m_range_max_pips, 1), "p",
        " atr_frac=", DoubleToString(m_range_atr_frac, 2));
}

//--- SetExecution: assumed adverse fill in pips, charged against the geometry.
void CSignalEngine::SetExecution(double slippage_pips) {
  m_slippage_pips = (slippage_pips > 0.0) ? slippage_pips : 0.0;
  Print("[SignalEngine] Execution ", m_symbol, " slippage=",
        DoubleToString(m_slippage_pips, 2), " pips charged against every entry");
}

//--- AtrPips: daily ATR expressed in pips. Zero means unavailable.
double CSignalEngine::AtrPips(string symbol) {
  if(m_atr_d1_handle == INVALID_HANDLE) return 0.0;

  double pip = PipSize(symbol);
  if(pip <= 0.0) return 0.0;

  double buf[];
  // Bar 1, not 0 - the forming day's ATR moves under us tick by tick.
  if(CopyBuffer(m_atr_d1_handle, 0, 1, 1, buf) < 1) return 0.0;
  if(buf[0] <= 0.0) return 0.0;

  return buf[0] / pip;
}

//--- SetGeometry: change where the stop and target go.
//    A negative fraction is meaningless and is clamped to 0 (legacy) rather
//    than allowed to produce a stop on the wrong side of the entry.
void CSignalEngine::SetGeometry(double stop_range_frac, bool consistent_tp) {
  m_stop_range_frac = (stop_range_frac > 0.0) ? stop_range_frac : 0.0;
  m_consistent_tp   = consistent_tp;

  Print("[SignalEngine] Geometry ", m_symbol,
        " stop=", (m_stop_range_frac > 0.0
                     ? DoubleToString(m_stop_range_frac, 2) + "x range from entry"
                     : "far side of range"),
        " target=", (m_consistent_tp ? "rr x actual stop" : "range-measured"));
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
  TimeToStruct(FpNowUtc(), dt);

  if(dt.day_of_week < 1 || dt.day_of_week > 5) return false;

  return HourInWindow(dt.hour, m_hunt_open_hour, m_hunt_close_hour);
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

//--- GetH4Bias: the sweep model's trend filter. Deliberately simpler than
//    GetH4Trend above - price on one side of the H4 EMA(50), nothing more.
//
//    The three-consecutive-closes rule the breakout used is a momentum test,
//    and momentum is the wrong question for a fade: by the time three H4 bars
//    have run in one direction, the pullback being faded is usually over. This
//    only asks which side of the mean price is on, which is what decides
//    whether a failed poke is a reversal or a trap.
int CSignalEngine::GetH4Bias(string symbol) {
  if(m_ema_handle == INVALID_HANDLE) return TREND_AMBIGUOUS;

  // Bar 1 - the last CLOSED H4 bar. Bar 0 repaints until it closes.
  double close = iClose(symbol, PERIOD_H4, 1);
  if(close <= 0.0) return TREND_AMBIGUOUS;

  double ema[];
  if(CopyBuffer(m_ema_handle, 0, 1, 1, ema) < 1) {
    Print("[SignalEngine] H4 EMA not ready for ", symbol, " - bias ambiguous");
    return TREND_AMBIGUOUS;
  }
  if(ema[0] <= 0.0) return TREND_AMBIGUOUS;

  if(close > ema[0]) return TREND_BULL;
  if(close < ema[0]) return TREND_BEAR;

  // Exactly on the EMA. Rare, but it is genuinely no information.
  return TREND_AMBIGUOUS;
}

//--- BuildSignal: pure entry geometry - no market access, fully testable
SSignal CSignalEngine::BuildSignal(string symbol, bool is_long,
                                   double range_high, double range_low, double range_pips,
                                   double ask, double bid, double pip, double rr,
                                   double stop_range_frac, bool consistent_tp) {
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

  s.entry_price = is_long ? ask : bid;

  // --- Stop ---------------------------------------------------------------
  // Default (stop_range_frac = 0) puts the stop beyond the FAR side of the
  // range, so every trade risks the whole range width. A positive fraction
  // measures the stop from the entry instead, which is what makes the cost of
  // a trade adjustable rather than dictated by how wide the Asian session was.
  if(stop_range_frac > 0.0) {
    double stop_dist = (range_pips * stop_range_frac + SL_BUFFER_PIPS) * pip;
    s.stop_loss = is_long ? (s.entry_price - stop_dist)
                          : (s.entry_price + stop_dist);
  } else {
    s.stop_loss = is_long ? (range_low  - SL_BUFFER_PIPS * pip)
                          : (range_high + SL_BUFFER_PIPS * pip);
  }

  s.sl_pips = (is_long ? (s.entry_price - s.stop_loss)
                       : (s.stop_loss - s.entry_price)) / pip;

  // A non-positive stop distance means price crossed the level between the
  // breakout check and the quote read - reject rather than send a broken order.
  if(s.sl_pips <= 0.0)
    return Invalid(symbol, "Computed stop distance is not positive");

  // --- Target -------------------------------------------------------------
  // Legacy measures reward from the NEAR side of the range while risk is
  // measured from the far side, so a nominal 2.0 does not deliver 2.0. The
  // consistent form measures both from the entry, and actually pays rr.
  if(consistent_tp) {
    double reward = s.sl_pips * rr * pip;
    s.take_profit = is_long ? (s.entry_price + reward)
                            : (s.entry_price - reward);
  } else {
    s.take_profit = is_long ? (range_high + range_pips * rr * pip)
                            : (range_low  - range_pips * rr * pip);
  }

  s.reason = StringFormat("Asian breakout + retest confirmed | Range: %.1fpips | Dir: %s",
                          range_pips, (is_long ? "LONG" : "SHORT"));

  return s;
}

//--- BuildSweepSignal: pure fade geometry - no market access, fully testable
SSignal CSignalEngine::BuildSweepSignal(string symbol, bool is_long,
                                        double sweep_high, double sweep_low,
                                        double ask, double bid, double pip, double rr,
                                        double sl_buffer_pips, double slippage_pips) {
  if(pip <= 0.0)
    return Invalid(symbol, "Cannot resolve pip size");

  if(ask <= 0.0 || bid <= 0.0)
    return Invalid(symbol, "No live quote available");

  if(sweep_high <= 0.0 || sweep_low <= 0.0 || sweep_high <= sweep_low)
    return Invalid(symbol, "Sweeping candle high is not above its low");

  if(rr <= 0.0)
    return Invalid(symbol, "Reward-to-risk ratio must be positive");

  SSignal s;
  s.valid       = true;
  s.is_long     = is_long;
  s.symbol      = symbol;
  s.risk_usd    = m_risk_usd;
  s.signal_time = TimeCurrent();

  // The reference price is the live quote made WORSE by the assumed slippage:
  // a buy fills higher than the ask, a sell lower than the bid. Measuring the
  // stop and target from that point is what makes the penalty real - the stop
  // ends up nearer than it looks and the target further away, exactly as an
  // adverse fill does to a live trade.
  double slip = slippage_pips * pip;
  s.entry_price = is_long ? (ask + slip) : (bid - slip);

  if(s.entry_price <= 0.0)
    return Invalid(symbol, "Slippage-adjusted entry price is not positive");

  // --- Stop: beyond the wick the market just rejected ----------------------
  double buffer = sl_buffer_pips * pip;
  s.stop_loss = is_long ? (sweep_low  - buffer)
                        : (sweep_high + buffer);

  s.sl_pips = (is_long ? (s.entry_price - s.stop_loss)
                       : (s.stop_loss - s.entry_price)) / pip;

  // Price ran through the setup between the candle closing and this quote
  // being read. Refuse rather than send an order whose stop is on the wrong
  // side of the entry.
  if(s.sl_pips <= 0.0)
    return Invalid(symbol, "Sweep stop is on the wrong side of the entry");

  // --- Target: a fixed multiple of the ACTUAL stop, from the entry ---------
  double reward = s.sl_pips * rr * pip;
  s.take_profit = is_long ? (s.entry_price + reward)
                          : (s.entry_price - reward);

  s.reason = StringFormat(
    "Asian liquidity sweep faded | %s | stop %.1fp | target %.1f:1",
    (is_long ? "LONG (swept the low)" : "SHORT (swept the high)"),
    s.sl_pips, rr);

  return s;
}

//--- CheckSweepSignal: the live sweep & fade sequence. Returns a struct only.
SSignal CSignalEngine::CheckSweepSignal(string symbol) {
  // 1. Session
  if(!IsLondonSession())
    return Invalid(symbol, "Outside session");

  // 2. The Asian range must exist. Its own MIN/MAX filter is separate from and
  //    wider than the coiling filter applied below.
  if(!m_asian_range.IsRangeSet())
    return Invalid(symbol, "Asian range not measured yet");

  double range_high = m_asian_range.GetRangeHigh();
  double range_low  = m_asian_range.GetRangeLow();
  double range_pips = m_asian_range.GetRangePips();

  double pip = PipSize(symbol);
  if(pip <= 0.0)
    return Invalid(symbol, "Cannot resolve pip size");

  // 3. Volatility coiling
  double atr_pips = AtrPips(symbol);
  if(!RangeVolatilityOk(range_pips, atr_pips,
                        m_range_min_pips, m_range_max_pips, m_range_atr_frac))
    return Invalid(symbol, StringFormat(
      "Range %.1fp outside the coiling band %.1f-%.1fp (D1 ATR %.1fp)",
      range_pips, m_range_min_pips, m_range_max_pips, atr_pips));

  // 4. One evaluation per closed M5 bar, not per tick.
  datetime bar_time = iTime(symbol, SWEEP_TIMEFRAME, 1);
  if(bar_time <= 0)
    return Invalid(symbol, "No closed M5 bar available");
  if(bar_time == m_last_sweep_bar)
    return Invalid(symbol, "This M5 bar has already been evaluated");

  // 5. The sweeping candle: the last CLOSED M5 bar
  double bar_high  = iHigh(symbol,  SWEEP_TIMEFRAME, 1);
  double bar_low   = iLow(symbol,   SWEEP_TIMEFRAME, 1);
  double bar_close = iClose(symbol, SWEEP_TIMEFRAME, 1);
  if(bar_high <= 0.0 || bar_low <= 0.0 || bar_close <= 0.0)
    return Invalid(symbol, "Incomplete M5 bar data");

  bool sweep_up   = IsSweepAbove(bar_high, bar_close, range_high, pip, m_sweep_min_pips);
  bool sweep_down = IsSweepBelow(bar_low,  bar_close, range_low,  pip, m_sweep_min_pips);

  if(!sweep_up && !sweep_down)
    return Invalid(symbol, "No failed sweep on the last M5 bar");

  // A bar that swept BOTH edges and closed inside is a whipsaw, not a setup -
  // there is no way to say which side got trapped.
  if(sweep_up && sweep_down) {
    m_last_sweep_bar = bar_time;
    return Invalid(symbol, "Bar swept both range edges - direction undecidable");
  }

  // 6. Trend alignment. A sweep of the HIGH is faded SHORT, so it needs a
  //    bearish H4 bias; a sweep of the LOW is faded LONG.
  bool is_long = sweep_down;
  int  bias    = GetH4Bias(symbol);

  if(bias == TREND_AMBIGUOUS) {
    m_last_sweep_bar = bar_time;
    return Invalid(symbol, "H4 bias ambiguous");
  }
  if(is_long && bias != TREND_BULL) {
    m_last_sweep_bar = bar_time;
    return Invalid(symbol, "Low swept but H4 bias is bearish - no counter-trend longs");
  }
  if(!is_long && bias != TREND_BEAR) {
    m_last_sweep_bar = bar_time;
    return Invalid(symbol, "High swept but H4 bias is bullish - no counter-trend shorts");
  }

  double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
  if(ask <= 0.0 || bid <= 0.0)
    return Invalid(symbol, "No live quote available");

  // Marked before the geometry runs. Whatever happens below, this bar has now
  // had its one evaluation - otherwise a geometry rejection would let the same
  // bar be retried on the next tick, and the next, until it rolled.
  m_last_sweep_bar = bar_time;

  // 7. Geometry
  SSignal s = BuildSweepSignal(symbol, is_long, bar_high, bar_low,
                               ask, bid, pip, m_rr_ratio,
                               m_sweep_sl_buffer, m_slippage_pips);
  if(!s.valid) return s;

  // 8. Log
  Print("[SignalEngine] SWEEP SIGNAL ", (s.is_long ? "LONG " : "SHORT "), symbol,
        " range=", DoubleToString(range_pips, 1), "p",
        " sweep_bar=", TimeToString(bar_time, TIME_DATE | TIME_MINUTES),
        " entry=", DoubleToString(s.entry_price, _Digits),
        " sl=",    DoubleToString(s.stop_loss,   _Digits),
        " tp=",    DoubleToString(s.take_profit, _Digits),
        " sl_pips=", DoubleToString(s.sl_pips, 1),
        " | ", s.reason);

  return s;
}

//--- CheckSignal: dispatch to whichever entry model is configured.
SSignal CSignalEngine::CheckSignal(string symbol) {
  if(m_mode == ENTRY_MODE_SWEEP) return CheckSweepSignal(symbol);
  return CheckBreakoutSignal(symbol);
}

//--- CheckBreakoutSignal: the legacy entry, unchanged. Retained as a control -
//    it is known to have no edge, so any replacement must beat it on the same
//    data before the replacement can be said to work.
SSignal CSignalEngine::CheckBreakoutSignal(string symbol) {
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
                          ask, bid, PipSize(symbol), m_rr_ratio,
                          m_stop_range_frac, m_consistent_tp);
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

//+------------------------------------------------------------------+
//| TrendPullback.mqh                                                |
//| Strategy Lab | Hypothesis H1 - Trend Pullback Continuation       |
//|                                                                  |
//| Purpose : Signal logic for a trend-continuation entry, kept       |
//|           separate from any order handling so the detection rules |
//|           can be asserted offline with no broker connection.      |
//|                                                                  |
//| The rule, in full:                                                |
//|   1. A slow EMA on a HIGHER timeframe sets the regime. Price      |
//|      above it means long-only; below it means short-only. There   |
//|      is no neutral state and no counter-trend trade, ever.        |
//|   2. On the ENTRY timeframe, a fast EMA marks the pullback zone.  |
//|   3. A signal fires on one closed bar that does two things at     |
//|      once: trades INTO the fast EMA, and closes back OUT of it in |
//|      the regime direction. One bar, three conditions, no state    |
//|      machine and no expiry window.                                |
//|                                                                  |
//| Why one bar and not an arm-then-wait state machine: an arming     |
//| flag needs an expiry ("armed for N bars"), and N is a free        |
//| parameter with no structural justification. Every free parameter  |
//| is somewhere the result can be fitted to the sample. The one-bar  |
//| form has none.                                                    |
//|                                                                  |
//| Author  : Tee (aigentforce.io)                                   |
//| Project : Strategy Lab (built on the FP50K-EA framework)          |
//+------------------------------------------------------------------+
#ifndef _LAB_TRENDPULLBACK_MQH_
#define _LAB_TRENDPULLBACK_MQH_

//--- Round numbers only. Each is a convention with decades of use
//--- behind it, not a value that was searched for on this data.
#define TP_EMA_TREND      200    // regime EMA, higher timeframe
#define TP_EMA_PULLBACK    50    // pullback EMA, entry timeframe
#define TP_ATR_PERIOD      20    // volatility measure, entry timeframe
#define TP_ATR_STOP_MULT  2.0    // stop distance in ATRs
#define TP_RR_RATIO       2.0    // reward:risk -> 33.3% break-even win rate

enum TP_DIR {
  TP_NONE  =  0,
  TP_LONG  =  1,
  TP_SHORT = -1
};

//--- What a fired signal contains. Prices, not lots: position sizing
//--- is the EA's job, and keeping it out of here is what lets the
//--- geometry be tested without an account.
struct TPSignal {
  TP_DIR   dir;
  double   entry_price;
  double   stop_loss;
  double   take_profit;
  double   sl_pips;
  string   reason;

  TPSignal() {
    dir = TP_NONE;  entry_price = 0.0;  stop_loss = 0.0;
    take_profit = 0.0;  sl_pips = 0.0;  reason = "";
  }
};

//+------------------------------------------------------------------+
//| Pure detection - no market access, fully testable offline        |
//+------------------------------------------------------------------+

//--- Regime. Strictly one side or the other; a close exactly on the
//--- EMA is treated as no trade rather than arbitrarily assigned.
TP_DIR TpRegime(double trend_close, double trend_ema) {
  if(trend_close <= 0.0 || trend_ema <= 0.0) return TP_NONE;
  if(trend_close > trend_ema) return TP_LONG;
  if(trend_close < trend_ema) return TP_SHORT;
  return TP_NONE;
}

//--- Did this bar reach into the pullback zone?
bool TpTouched(double bar_high, double bar_low, double ema, bool is_long) {
  if(ema <= 0.0 || bar_high <= 0.0 || bar_low <= 0.0) return false;
  return is_long ? (bar_low <= ema) : (bar_high >= ema);
}

//--- Did it close back out of the zone, on the regime's side?
bool TpReclaimed(double bar_close, double ema, bool is_long) {
  if(ema <= 0.0 || bar_close <= 0.0) return false;
  return is_long ? (bar_close > ema) : (bar_close < ema);
}

//--- The full one-bar trigger. Kept as its own function so the EA and
//--- the tests are provably asking the same question.
bool TpIsSignalBar(double bar_high, double bar_low, double bar_close,
                   double ema, bool is_long) {
  return TpTouched(bar_high, bar_low, ema, is_long) &&
         TpReclaimed(bar_close, ema, is_long);
}

//+------------------------------------------------------------------+
//| Trade geometry                                                    |
//|                                                                   |
//| Slippage is charged against the trade in both directions: the fill|
//| is worse than the quote, which widens the stop and shortens the   |
//| reach to target. The tester has no slippage setting, so if it is  |
//| not applied here it is not applied at all.                        |
//+------------------------------------------------------------------+
TPSignal TpBuildSignal(TP_DIR dir, double ask, double bid, double atr,
                       double pip, double atr_mult, double rr,
                       double slippage_pips) {
  TPSignal s;
  if(dir == TP_NONE)                     { s.reason = "No regime";        return s; }
  if(atr <= 0.0 || pip <= 0.0)           { s.reason = "Bad ATR or pip";   return s; }
  if(ask <= 0.0 || bid <= 0.0)           { s.reason = "Bad quote";        return s; }
  if(atr_mult <= 0.0 || rr <= 0.0)       { s.reason = "Bad multipliers";  return s; }

  bool   is_long = (dir == TP_LONG);
  double slip    = slippage_pips * pip;
  double stop_d  = atr * atr_mult;

  s.dir         = dir;
  s.entry_price = is_long ? (ask + slip) : (bid - slip);
  s.stop_loss   = is_long ? (s.entry_price - stop_d) : (s.entry_price + stop_d);
  s.sl_pips     = stop_d / pip;

  if(s.sl_pips <= 0.0) {
    s.dir = TP_NONE;  s.reason = "Stop collapsed to zero";  return s;
  }

  double reward = stop_d * rr;
  s.take_profit = is_long ? (s.entry_price + reward) : (s.entry_price - reward);
  s.reason      = is_long ? "Pullback reclaim long" : "Pullback reclaim short";
  return s;
}

//--- Break-even win rate for a given reward:risk. At 2.0 this is
//--- 33.33%; anything measured below that is a losing system however
//--- good the equity curve looks over a short sample.
double TpBreakEvenWinPct(double rr) {
  if(rr <= 0.0) return 100.0;
  return 100.0 / (1.0 + rr);
}

//--- Lots from a flat dollar risk. Floor-rounded, never up: rounding
//--- up would quietly risk more than the budget allows.
double TpLotsFromRisk(double risk_usd, double sl_pips, double pip_value,
                      double step, double vmin, double vmax) {
  if(risk_usd <= 0.0 || sl_pips <= 0.0 || pip_value <= 0.0) return 0.0;
  if(step <= 0.0) step = 0.01;
  double lots = risk_usd / (sl_pips * pip_value);
  lots = MathFloor(lots / step) * step;
  lots = NormalizeDouble(lots, 2);
  if(vmax > 0.0 && lots > vmax) lots = vmax;
  if(lots < vmin) return 0.0;
  return lots;
}

#endif // _LAB_TRENDPULLBACK_MQH_

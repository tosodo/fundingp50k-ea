//+------------------------------------------------------------------+
//| LabCore.mqh                                                       |
//| Strategy Lab | shared trade geometry                              |
//|                                                                   |
//| Purpose : The parts of a lab strategy that must be identical      |
//|           across every hypothesis - where the stop goes, where     |
//|           the target goes, how slippage is charged, and how many   |
//|           lots a fixed dollar risk buys.                           |
//|                                                                   |
//| Why this is shared rather than copied: these are the functions     |
//| that turn a directional opinion into a measured R multiple. If     |
//| H2 computed its stop even slightly differently from H1, the two    |
//| results would not be comparable and the difference would be        |
//| invisible - it would look like a difference in edge. One copy,     |
//| one set of tests.                                                  |
//|                                                                   |
//| Contains no market access whatsoever: every input is a plain       |
//| number passed in by the caller. That is what allows the whole of   |
//| it to be asserted offline with no broker connection.               |
//|                                                                   |
//| Author  : Tee (aigentforce.io)                                    |
//| Project : Strategy Lab                                            |
//+------------------------------------------------------------------+
#ifndef LAB_CORE_MQH
#define LAB_CORE_MQH

enum LAB_DIR { LAB_NONE = 0, LAB_LONG = 1, LAB_SHORT = -1 };

struct LabSignal {
  LAB_DIR dir;
  double  entry_price;
  double  stop_loss;
  double  take_profit;
  double  sl_pips;
  string  reason;

  LabSignal() {
    dir = LAB_NONE; entry_price = 0.0; stop_loss = 0.0;
    take_profit = 0.0; sl_pips = 0.0; reason = "";
  }
};

//+------------------------------------------------------------------+
//| Turn a direction into a full trade: fill, stop and target.        |
//|                                                                   |
//| Slippage worsens the FILL only. It does not widen the stop, which  |
//| is anchored to volatility rather than to the entry - so a slipped  |
//| entry loses slightly more than 1R, exactly as it does live. Pretend|
//| otherwise and every loss reports as a clean -1.00R and the cost of |
//| slippage silently vanishes from the statistics.                    |
//+------------------------------------------------------------------+
LabSignal LabBuildSignal(LAB_DIR dir, double ask, double bid, double atr,
                         double pip, double atr_mult, double rr,
                         double slippage_pips) {
  LabSignal s;
  if(dir == LAB_NONE)              { s.reason = "No direction";    return s; }
  if(atr <= 0.0 || pip <= 0.0)     { s.reason = "Bad ATR or pip";  return s; }
  if(ask <= 0.0 || bid <= 0.0)     { s.reason = "Bad quote";       return s; }
  if(atr_mult <= 0.0 || rr <= 0.0) { s.reason = "Bad multipliers"; return s; }

  bool   is_long = (dir == LAB_LONG);
  double slip    = slippage_pips * pip;
  double stop_d  = atr * atr_mult;

  s.dir         = dir;
  s.entry_price = is_long ? (ask + slip) : (bid - slip);
  s.stop_loss   = is_long ? (s.entry_price - stop_d) : (s.entry_price + stop_d);
  s.sl_pips     = stop_d / pip;

  if(s.sl_pips <= 0.0) { s.dir = LAB_NONE; s.reason = "Stop collapsed to zero"; return s; }

  double reward = stop_d * rr;
  s.take_profit = is_long ? (s.entry_price + reward) : (s.entry_price - reward);
  s.reason      = is_long ? "Long" : "Short";
  return s;
}

//--- The win rate a reward:risk ratio must beat just to break even.
double LabBreakEvenWinPct(double rr) {
  if(rr <= 0.0) return 100.0;
  return 100.0 / (1.0 + rr);
}

//+------------------------------------------------------------------+
//| Lots for a fixed dollar risk. Always rounds DOWN to the volume    |
//| step - rounding up would quietly risk more than the budget, and   |
//| every trade would then be slightly larger than the one the        |
//| statistics assume.                                                |
//+------------------------------------------------------------------+
double LabLotsFromRisk(double risk_usd, double sl_pips, double pip_value,
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

//+------------------------------------------------------------------+
//| Is an hour inside a [start, end) window? Half-open on purpose:    |
//| an hour belongs to exactly one window, so windows laid end to end |
//| neither overlap nor leave a gap.                                   |
//|                                                                    |
//| Handles a window that wraps past midnight (start > end), which the |
//| Asian session does on most broker server offsets.                  |
//+------------------------------------------------------------------+
bool LabHourInWindow(int hour, int start_h, int end_h) {
  if(hour < 0 || hour > 23) return false;
  if(start_h == end_h)      return false;         // empty window, not a full day
  if(start_h < end_h)       return (hour >= start_h && hour < end_h);
  return (hour >= start_h || hour < end_h);       // wraps midnight
}

#endif // LAB_CORE_MQH

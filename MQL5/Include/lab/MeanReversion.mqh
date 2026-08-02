//+------------------------------------------------------------------+
//| MeanReversion.mqh                                                 |
//| Strategy Lab | Hypothesis H4 - Overextension Fade                 |
//|                                                                   |
//| Purpose : The detection rules for H4, as pure arithmetic with no  |
//|           market access, so every rule can be asserted offline.   |
//|                                                                   |
//| The claim being tested                                            |
//|   A move that carries price a long way from its own recent mean   |
//|   in a short time is mostly liquidity, not information. Someone   |
//|   had to fill a large order, or a cluster of stops was reached,   |
//|   and the price paid to do that is not the price the market       |
//|   actually agrees on. Price therefore returns toward the mean     |
//|   more often than a coin flip says it should.                     |
//|                                                                   |
//| Why this hypothesis, after three rejections                       |
//|   H1 bet on continuation after a pullback and won 30.9% where it  |
//|   needed 33.3%. H3 bet on continuation after a range break and    |
//|   won 25.3% of resolved trades against a ~29.8% random-walk       |
//|   baseline. Both continuation bets landed AT OR BELOW random.     |
//|   A continuation bet losing to a random walk is the same          |
//|   observation as a reversion bet beating one, so this is the      |
//|   direction the evidence points - not a fresh guess.              |
//|                                                                   |
//|   Being honest about where that idea came from: it was suggested  |
//|   by the lab's own two results. That is a legitimate way to pick  |
//|   the next mechanism, but it means a PASS here carries less       |
//|   weight than a pass would have carried for H1, and the           |
//|   out-of-sample checks matter correspondingly more.               |
//|                                                                   |
//| Why the target is the mean itself                                 |
//|   The hypothesis is "price returns to its mean". The mean is      |
//|   therefore the target - it is supplied by the setup, not chosen. |
//|   That removes the reward:risk ratio as a free parameter, which   |
//|   is where H1 and H2 both had a number that could have been       |
//|   tuned. The value is frozen at signal time; a target that        |
//|   tracked a moving average would be a different hypothesis.       |
//|                                                                   |
//| Author  : Tee (aigentforce.io)                                    |
//| Project : Strategy Lab                                            |
//+------------------------------------------------------------------+
#ifndef LAB_MEAN_REVERSION_MQH
#define LAB_MEAN_REVERSION_MQH

#include <lab\LabCore.mqh>

#define MR_MA_PERIOD    20     // bars in the mean
#define MR_ATR_PERIOD   20     // bars in the volatility measure
#define MR_ENTRY_ATR    2.0    // how far from the mean counts as overextended
#define MR_STOP_ATR     2.0    // stop distance beyond the fill
#define MR_HOLD_BARS    24     // give up after one day of H1 bars
#define MR_HOUR_START   7      // entries allowed from, GMT
#define MR_HOUR_END    20      // entries allowed until, GMT

//+------------------------------------------------------------------+
//| Is a closed bar overextended, and which way should we fade it?    |
//|                                                                   |
//| Measured on the CLOSE, not the high or low. A wick that stretches |
//| and comes back has already reverted - the move we want to fade is |
//| one that was still extended when the bar finished. This also      |
//| avoids depending on intrabar ordering, which 1-minute OHLC        |
//| modelling cannot resolve honestly.                                |
//|                                                                   |
//| Strictly beyond the threshold, so a close exactly on it is not a  |
//| signal. Same no-arbitrary-tie-breaking rule as the rest of the    |
//| lab.                                                              |
//|                                                                    |
//| "Exactly" needs a tolerance, and this one is not a tuning knob.    |
//| The threshold is a computed real number while quotes live on a     |
//| discrete grid, so `ma - stretch` can land one floating-point step  |
//| above or below a price that is logically identical to it, and the  |
//| rule would then fire or not fire on rounding luck - differently on |
//| a EURUSD-scale price than on a JPY-scale one. The tolerance is a   |
//| millionth of the ATR: on a 25 pip ATR that is 0.000025 of a pip,   |
//| far below any broker's smallest quote step and far above double    |
//| rounding error. It makes the boundary decidable. It cannot change  |
//| a trade.                                                           |
//+------------------------------------------------------------------+
LAB_DIR MrStretchDir(double bar_close, double ma, double atr, double entry_mult) {
  if(bar_close <= 0.0 || ma <= 0.0) return LAB_NONE;
  if(atr <= 0.0 || entry_mult <= 0.0) return LAB_NONE;

  double stretch = entry_mult * atr;
  double eps     = atr * 0.000001;
  if(bar_close < ma - stretch - eps) return LAB_LONG;   // too far below: buy it back
  if(bar_close > ma + stretch + eps) return LAB_SHORT;  // too far above: sell it back
  return LAB_NONE;
}

//--- How many ATRs from the mean is this close? Diagnostic only: it is
//    printed with every entry so a null or lopsided result can be read
//    without rerunning anything.
double MrStretchAtrs(double bar_close, double ma, double atr) {
  if(atr <= 0.0) return 0.0;
  return MathAbs(bar_close - ma) / atr;
}

//+------------------------------------------------------------------+
//| Build the trade: stop a fixed distance beyond the fill, target on |
//| the mean as it stood when the signal fired.                       |
//|                                                                   |
//| Slippage on a fade pushes the fill TOWARD the mean, not away from  |
//| it: a long is buying below the mean, so paying more moves the      |
//| entry closer to the target. The reward therefore shrinks while the |
//| risk is unchanged, because the stop is measured from the fill.     |
//| That is a real cost and it is charged, exactly as in H1-H3.        |
//|                                                                    |
//| Worth stating plainly because the first version of this comment    |
//| claimed the opposite, and the assertion in section 7 of the test   |
//| script is what caught it.                                          |
//|                                                                   |
//| The trade is refused if the fill has already passed the mean. That |
//| cannot happen from slippage alone at a 2 ATR stretch, but it can   |
//| happen if this is ever run with a small entry multiple, and a      |
//| target on the wrong side of the entry would book an instant win    |
//| that never occurred.                                               |
//+------------------------------------------------------------------+
LabSignal MrBuildSignal(LAB_DIR dir, double ask, double bid, double ma,
                        double atr, double pip, double stop_mult,
                        double slippage_pips) {
  LabSignal s;
  if(dir == LAB_NONE)               { s.reason = "No direction";     return s; }
  if(ask <= 0.0 || bid <= 0.0)      { s.reason = "Bad quote";        return s; }
  if(ma <= 0.0 || atr <= 0.0)       { s.reason = "Bad mean or ATR";  return s; }
  if(pip <= 0.0 || stop_mult <= 0.0){ s.reason = "Bad multipliers";  return s; }

  bool   is_long = (dir == LAB_LONG);
  double slip    = slippage_pips * pip;
  double stop_d  = stop_mult * atr;

  s.entry_price = is_long ? (ask + slip) : (bid - slip);
  s.stop_loss   = is_long ? (s.entry_price - stop_d) : (s.entry_price + stop_d);
  s.take_profit = ma;

  double reward = is_long ? (s.take_profit - s.entry_price)
                          : (s.entry_price - s.take_profit);
  if(reward <= 0.0) {
    s.reason = "Fill is already at or through the mean";
    return s;
  }

  s.dir     = dir;
  s.sl_pips = stop_d / pip;
  if(s.sl_pips <= 0.0) {
    s.dir = LAB_NONE;
    s.reason = "Stop collapsed to zero";
    return s;
  }
  s.reason = is_long ? "Fade long" : "Fade short";
  return s;
}

//--- Realised reward:risk of a built signal. Used by the tests to check
//    the geometry against actual prices rather than against the inputs
//    that were meant to produce them.
double MrRealisedRR(const LabSignal &s) {
  if(s.dir == LAB_NONE || s.sl_pips <= 0.0) return 0.0;
  double reward = (s.dir == LAB_LONG) ? (s.take_profit - s.entry_price)
                                      : (s.entry_price - s.take_profit);
  double risk   = (s.dir == LAB_LONG) ? (s.entry_price - s.stop_loss)
                                      : (s.stop_loss - s.entry_price);
  if(risk <= 0.0) return 0.0;
  return reward / risk;
}

//+------------------------------------------------------------------+
//| Are entries allowed at this GMT hour?                             |
//|                                                                   |
//| This is a REALISM limit, not a performance filter, and the         |
//| distinction matters because a session window chosen because it     |
//| tested well is a tuned parameter wearing a structural disguise.    |
//| Every run forces one fixed spread. Outside London and New York     |
//| the real spread is materially wider, so a trade taken at 03:00     |
//| GMT would be charged a cost the live market would not have         |
//| offered. Restricting entries to the hours where the assumed spread |
//| is honest makes the measurement mean what it says.                 |
//|                                                                   |
//| Positions opened inside the window are NOT force-closed when it    |
//| ends. The holding limit is what ends a trade, and cutting it at    |
//| the window edge would mix a second rule into the result.           |
//+------------------------------------------------------------------+
bool MrEntryHourAllowed(int gmt_hour) {
  return LabHourInWindow(gmt_hour, MR_HOUR_START, MR_HOUR_END);
}

//--- Has the position been held long enough to give up on it?
//    The claim is about a move reverting within about a day, so a
//    trade still open after that has had its question answered.
bool MrHoldExpired(int bars_held, int limit_bars) {
  if(limit_bars <= 0) return false;
  return (bars_held >= limit_bars);
}

#endif // LAB_MEAN_REVERSION_MQH

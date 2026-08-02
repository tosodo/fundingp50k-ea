//+------------------------------------------------------------------+
//| SessionBreakout.mqh                                               |
//| Strategy Lab | Hypothesis H2 - Asian Range Compression Breakout   |
//|                                                                   |
//| Purpose : The detection rules for H2, as pure arithmetic with no  |
//|           market access, so every rule can be asserted offline.    |
//|                                                                   |
//| The claim being tested                                             |
//|   Volatility clusters. A quiet overnight session is followed by a  |
//|   quiet morning more often than chance, and a compressed range     |
//|   that finally breaks tends to keep going rather than snap back.   |
//|   This is the single most reliably documented statistical property |
//|   of financial prices - far better evidenced than trend            |
//|   persistence, which is what H1 tested and failed to find.         |
//|                                                                    |
//|   The bet is therefore NOT "the market goes up". It is "a market   |
//|   that has been unusually still is storing a move, and the         |
//|   direction it first breaks is more informative than a coin flip". |
//|                                                                    |
//| Why the compression gate is part of the hypothesis, not a filter   |
//|   Plain "break the overnight range" is one of the oldest published |
//|   intraday ideas in FX and has no conditioning at all. Compression |
//|   is the entire structural claim; removing it would leave a rule   |
//|   with nothing behind it. It costs exactly one round number (a     |
//|   20-day average) and it is not searched for on this data.          |
//|                                                                    |
//| Author  : Tee (aigentforce.io)                                    |
//| Project : Strategy Lab                                            |
//+------------------------------------------------------------------+
#ifndef LAB_SESSION_BREAKOUT_MQH
#define LAB_SESSION_BREAKOUT_MQH

#include <lab\LabCore.mqh>

//--- All hours are GMT. See the EA header for why not server time.
#define SB_ASIA_START      0     // overnight range starts, GMT
#define SB_ASIA_END        7     // overnight range closes, GMT
#define SB_BREAK_START     7     // breakout window opens, GMT (London)
#define SB_BREAK_END      12     // breakout window shuts, GMT
#define SB_FLAT_HOUR      20     // anything still open is closed, GMT
#define SB_AVG_DAYS       20     // days in the compression benchmark
#define SB_ATR_PERIOD     20     // volatility measure, entry timeframe
#define SB_ATR_STOP_MULT  1.5    // stop distance in ATRs
#define SB_RR_RATIO       2.0    // reward:risk -> 33.3% break-even win rate

//+------------------------------------------------------------------+
//| Mean of the first `count` entries. Returns 0 when there is no     |
//| history, which callers must treat as "not ready" rather than as   |
//| an average of zero - otherwise every day would read as compressed |
//| on the first run through.                                          |
//+------------------------------------------------------------------+
double SbAverage(const double &vals[], int count) {
  if(count <= 0) return 0.0;
  int n = MathMin(count, ArraySize(vals));
  if(n <= 0) return 0.0;
  double sum = 0.0;
  for(int i = 0; i < n; i++) sum += vals[i];
  return sum / n;
}

//+------------------------------------------------------------------+
//| Was the overnight range unusually narrow?                         |
//|                                                                   |
//| Strictly less than the benchmark. A range exactly ON the average  |
//| is not compressed - the same "no arbitrary tie-breaking" rule     |
//| used everywhere else in the lab.                                   |
//+------------------------------------------------------------------+
bool SbIsCompressed(double range, double avg_range) {
  if(range <= 0.0 || avg_range <= 0.0) return false;
  return (range < avg_range);
}

//+------------------------------------------------------------------+
//| Which way, if either, did a closed bar break the range?           |
//|                                                                   |
//| Close-based, not touch-based. A wick through the level and back   |
//| is the market rejecting it; requiring the close to settle beyond  |
//| the level is the difference between a break and a probe. It also  |
//| removes any ambiguity about intrabar ordering, which 1-minute     |
//| OHLC modelling cannot resolve honestly.                            |
//+------------------------------------------------------------------+
LAB_DIR SbBreakoutDir(double bar_close, double range_hi, double range_lo) {
  if(bar_close <= 0.0 || range_hi <= 0.0 || range_lo <= 0.0) return LAB_NONE;
  if(range_hi <= range_lo)                                   return LAB_NONE;
  if(bar_close > range_hi) return LAB_LONG;
  if(bar_close < range_lo) return LAB_SHORT;
  return LAB_NONE;
}

//+------------------------------------------------------------------+
//| H3: the stop is the opposite side of the range.                   |
//|                                                                   |
//| Not a parameter, and nothing to choose. The strategy's whole claim |
//| is that a decisive break of a compressed range means something; if |
//| price returns all the way to the far side of that range, the claim |
//| is simply false and the trade is over. The level is supplied by    |
//| the setup itself.                                                  |
//|                                                                    |
//| This replaces H2's 1.5 x ATR stop, which on M15 came to about five |
//| pips - against two pips of spread and slippage. That is not a      |
//| stop, it is a coin toss with a fee attached: the bid had to fall   |
//| 3.5 pips to lose but rise 13 to win, so a random walk won 21% of   |
//| the time while the cash payoff still demanded 33.3%. No entry      |
//| signal can climb out of that hole.                                 |
//|                                                                    |
//| No buffer is added beyond the level. A buffer would be a free      |
//| parameter, and every free parameter is somewhere a result can be   |
//| fitted to the sample.                                              |
//+------------------------------------------------------------------+
LabSignal SbBuildRangeSignal(LAB_DIR dir, double ask, double bid,
                             double range_hi, double range_lo,
                             double pip, double rr, double slippage_pips) {
  LabSignal s;
  if(dir == LAB_NONE)          { s.reason = "No direction";     return s; }
  if(pip <= 0.0 || rr <= 0.0)  { s.reason = "Bad pip or RR";    return s; }
  if(ask <= 0.0 || bid <= 0.0) { s.reason = "Bad quote";        return s; }
  if(range_hi <= range_lo)     { s.reason = "Bad range";        return s; }

  bool   is_long = (dir == LAB_LONG);
  double slip    = slippage_pips * pip;

  s.dir         = dir;
  s.entry_price = is_long ? (ask + slip) : (bid - slip);
  s.stop_loss   = is_long ? range_lo : range_hi;

  // Distance from the fill to the far side. Slippage worsens the fill,
  // so it widens the risk here rather than being absorbed silently -
  // which is correct: a worse fill really is further from the stop.
  double stop_d = is_long ? (s.entry_price - s.stop_loss)
                          : (s.stop_loss - s.entry_price);
  if(stop_d <= 0.0) {
    s.dir = LAB_NONE;
    s.reason = "Fill is already through the far side of the range";
    return s;
  }

  s.sl_pips     = stop_d / pip;
  double reward = stop_d * rr;
  s.take_profit = is_long ? (s.entry_price + reward) : (s.entry_price - reward);
  s.reason      = is_long ? "Range breakout long" : "Range breakout short";
  return s;
}

//--- Convenience wrappers, so the hours live in one place only.
bool SbInAsianSession(int gmt_hour)   { return LabHourInWindow(gmt_hour, SB_ASIA_START,  SB_ASIA_END);  }
bool SbInBreakoutWindow(int gmt_hour) { return LabHourInWindow(gmt_hour, SB_BREAK_START, SB_BREAK_END); }

//+------------------------------------------------------------------+
//| Server clock to GMT, rounded to the nearest hour.                 |
//|                                                                   |
//| Brokers run their servers on their own offsets and change them at |
//| daylight saving. A session strategy with the hours hard-coded to  |
//| one broker's clock would appear to break on a different feed for  |
//| a reason that has nothing to do with the strategy - which would   |
//| corrupt the multi-data-source robustness test rather than inform  |
//| it. Rounding removes the few seconds of clock drift that would    |
//| otherwise flip an hour boundary at random.                         |
//+------------------------------------------------------------------+
int SbGmtOffsetSeconds(datetime server_now, datetime gmt_now) {
  if(server_now == 0 || gmt_now == 0) return 0;
  double diff = (double)((long)server_now - (long)gmt_now);
  return (int)(MathRound(diff / 3600.0) * 3600.0);
}

#endif // LAB_SESSION_BREAKOUT_MQH

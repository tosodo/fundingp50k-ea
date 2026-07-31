//+------------------------------------------------------------------+
//| SignalEngine_tests.mq5                                            |
//| FP50K-EA | Sprint 2 Unit Tests                                    |
//| Tests: Asian range, H4 trend, session gate, signal geometry       |
//+------------------------------------------------------------------+
#property script_show_inputs

#include <fp50k\SignalEngine.mqh>
#include <fp50k\RiskManager.mqh>

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

//--- Informational only - does not affect pass/fail
void Info(string label, string value)
  {
   Print("[QA] INFO | ", label, " | ", value);
  }

void OnStart()
  {
   Print("=== FP50K-EA | SignalEngine Unit Tests ===");

//--- GROUP 1: Range quality constants
   Check("MIN_RANGE_PIPS == 10",   MIN_RANGE_PIPS   == 10);
   Check("MAX_RANGE_PIPS == 80",   MAX_RANGE_PIPS   == 80);
   Check("RETEST_TOLERANCE == 3",  RETEST_TOLERANCE == 3);
   Check("ASIAN_START_HOUR == 0",  ASIAN_START_HOUR == 0);
   Check("ASIAN_END_HOUR == 7",    ASIAN_END_HOUR   == 7);
   Check("Min range below max range",   MIN_RANGE_PIPS < MAX_RANGE_PIPS);
   Check("Asian session ends where London begins",
         ASIAN_END_HOUR == SIG_SESSION_OPEN_HOUR);
   Check("Stop buffer is positive",     SL_BUFFER_PIPS > 0.0);
   Check("Retest tolerance is positive", RETEST_TOLERANCE > 0);

//--- GROUP 2: SSignal defaults - an unpopulated signal must never look tradeable
   SSignal blank;
   Check("Fresh SSignal is invalid",        blank.valid == false);
   Check("Fresh SSignal has no entry",      blank.entry_price == 0.0);
   Check("Fresh SSignal has no stop",       blank.stop_loss   == 0.0);
   Check("Fresh SSignal has no target",     blank.take_profit == 0.0);
   Check("Fresh SSignal has zero sl_pips",  blank.sl_pips     == 0.0);
   Check("Fresh SSignal defaults risk to $500", blank.risk_usd == 500.0);

//--- GROUP 3: A fresh range must refuse everything until it is measured
   CAsianRange range;
   range.Init(_Symbol);

   Check("Fresh range is not set",     range.IsRangeSet()   == false);
   Check("Fresh range is not valid",   range.IsRangeValid() == false);
   Check("Unmeasured range refuses breakout up",   range.IsBreakoutUp(999999.0)  == false);
   Check("Unmeasured range refuses breakout down", range.IsBreakoutDown(0.00001) == false);
   Check("Unmeasured range refuses retest (long)",  range.IsRetestHold(999999.0, true)  == false);
   Check("Unmeasured range refuses retest (short)", range.IsRetestHold(0.00001, false) == false);

//--- GROUP 4: Measure today's real Asian range
   range.CalculateRange(_Symbol);
   Info("Range summary", range.ToString());

   if(range.IsRangeSet())
     {
      Check("Measured range high is above low",
            range.GetRangeHigh() > range.GetRangeLow());
      Check("Measured range size is positive",
            range.GetRangePips() > 0.0);

      double rp = range.GetRangePips();
      bool expect_valid = (rp >= MIN_RANGE_PIPS && rp <= MAX_RANGE_PIPS);
      Check("Validity flag matches the min/max filter",
            range.IsRangeValid() == expect_valid,
            StringFormat("%.1f pips, valid=%s", rp, (range.IsRangeValid() ? "true" : "false")));

      if(range.IsRangeValid())
        {
         Check("Long target sits above the range high",
               range.GetTargetUp(2.0) > range.GetRangeHigh());
         Check("Short target sits below the range low",
               range.GetTargetDown(2.0) < range.GetRangeLow());
         Check("A wider R:R pushes the long target further out",
               range.GetTargetUp(3.0) > range.GetTargetUp(2.0));
         Check("Price inside the range is not a breakout",
               range.IsBreakoutUp((range.GetRangeHigh() + range.GetRangeLow()) / 2.0) == false);
         Check("Price above the high is a breakout up",
               range.IsBreakoutUp(range.GetRangeHigh() + 0.0010) == true);
         Check("Price below the low is a breakout down",
               range.IsBreakoutDown(range.GetRangeLow() - 0.0010) == true);
        }
      else
        {
         Info("Target/breakout tests", "SKIPPED - today's range failed the min/max filter");
        }
     }
   else
     {
      Info("Range tests", "SKIPPED - no H1 bars in the 00:00-07:00 UTC window");
     }

//--- GROUP 5: Session gate
   CSignalEngine engine;
   Check("Init() returns true", engine.Init(_Symbol, 500.0, 2.0));

   MqlDateTime gmt;
   TimeToStruct(TimeGMT(), gmt);
   bool expect_session = (gmt.day_of_week >= 1 && gmt.day_of_week <= 5 &&
                          gmt.hour >= SIG_SESSION_OPEN_HOUR &&
                          gmt.hour <  SIG_SESSION_CLOSE_HOUR);

   Check("Session gate agrees with the UTC clock",
         engine.IsLondonSession() == expect_session,
         StringFormat("%02d:%02d UTC dow=%d", gmt.hour, gmt.min, gmt.day_of_week));
   Check("Weekends are never in session",
         (gmt.day_of_week == 0 || gmt.day_of_week == 6) ? (engine.IsLondonSession() == false) : true);

//--- GROUP 6: H4 trend must always answer with one of three defined states
   int trend = engine.GetH4Trend(_Symbol);
   Check("H4 trend is bull, bear or ambiguous",
         trend == TREND_BULL || trend == TREND_BEAR || trend == TREND_AMBIGUOUS,
         IntegerToString(trend));
   Info("H4 trend now", trend == TREND_BULL ? "BULL" : (trend == TREND_BEAR ? "BEAR" : "AMBIGUOUS"));

//--- GROUP 7: Signal geometry, driven by fixed values rather than live prices.
//    Synthetic range: high 1.1000, low 1.0950 (50 pips), pip = 0.0001
   double pip  = 0.0001;
   double hi   = 1.1000;
   double lo   = 1.0950;
   double rpip = 50.0;
   double ask  = 1.1002;
   double bid  = 1.1001;

   SSignal lng = engine.BuildSignal(_Symbol, true, hi, lo, rpip, ask, bid, pip, 2.0);

   Check("Long signal is valid", lng.valid == true, lng.reason);
   Check("Long entry is the ask",        MathAbs(lng.entry_price - ask) < 1e-8);
   Check("Long stop is below entry",     lng.stop_loss < lng.entry_price);
   Check("Long stop is below range low", lng.stop_loss < lo);
   Check("Long target is above entry",   lng.take_profit > lng.entry_price);
   Check("Long sl_pips is positive",     lng.sl_pips > 0.0,
         StringFormat("%.1f pips", lng.sl_pips));
   Check("Long reward exceeds risk",
         (lng.take_profit - lng.entry_price) > (lng.entry_price - lng.stop_loss),
         StringFormat("reward=%.1f risk=%.1f pips",
                      (lng.take_profit - lng.entry_price) / pip,
                      (lng.entry_price - lng.stop_loss) / pip));
   Check("Long signal carries a reason", StringLen(lng.reason) > 0);
   Check("Long signal is flagged long",  lng.is_long == true);

   double sask = 1.0949;
   double sbid = 1.0948;
   SSignal sht = engine.BuildSignal(_Symbol, false, hi, lo, rpip, sask, sbid, pip, 2.0);

   Check("Short signal is valid", sht.valid == true, sht.reason);
   Check("Short entry is the bid",        MathAbs(sht.entry_price - sbid) < 1e-8);
   Check("Short stop is above entry",     sht.stop_loss > sht.entry_price);
   Check("Short stop is above range high", sht.stop_loss > hi);
   Check("Short target is below entry",   sht.take_profit < sht.entry_price);
   Check("Short sl_pips is positive",     sht.sl_pips > 0.0,
         StringFormat("%.1f pips", sht.sl_pips));
   Check("Short reward exceeds risk",
         (sht.entry_price - sht.take_profit) > (sht.stop_loss - sht.entry_price),
         StringFormat("reward=%.1f risk=%.1f pips",
                      (sht.entry_price - sht.take_profit) / pip,
                      (sht.stop_loss - sht.entry_price) / pip));
   Check("Short signal is flagged short", sht.is_long == false);

//--- GROUP 8: Geometry must reject nonsense inputs rather than emit a broken order
   SSignal bad_pip = engine.BuildSignal(_Symbol, true, hi, lo, rpip, ask, bid, 0.0, 2.0);
   Check("Rejects zero pip size", bad_pip.valid == false, bad_pip.reason);

   SSignal bad_quote = engine.BuildSignal(_Symbol, true, hi, lo, rpip, 0.0, 0.0, pip, 2.0);
   Check("Rejects missing quote", bad_quote.valid == false, bad_quote.reason);

   SSignal inverted = engine.BuildSignal(_Symbol, true, lo, hi, rpip, ask, bid, pip, 2.0);
   Check("Rejects an inverted range", inverted.valid == false, inverted.reason);

// A long whose ask is already below the stop would produce a negative stop
// distance - it must be refused, not sized.
   SSignal crossed = engine.BuildSignal(_Symbol, true, hi, lo, rpip, 1.0900, 1.0900, pip, 2.0);
   Check("Rejects a crossed stop distance", crossed.valid == false, crossed.reason);

   Check("Rejected signals never carry a positive stop distance",
         bad_pip.sl_pips == 0.0 && bad_quote.sl_pips == 0.0 &&
         inverted.sl_pips == 0.0 && crossed.sl_pips == 0.0);

//--- GROUP 10: Sweep & fade constants
   Check("SWEEP_MIN_PIPS == 3",        SWEEP_MIN_PIPS       == 3.0);
   Check("SWEEP_SL_BUFFER_PIPS == 2",  SWEEP_SL_BUFFER_PIPS == 2.0);
   Check("SWEEP_MIN_RANGE_PIPS == 8",  SWEEP_MIN_RANGE_PIPS == 8.0);
   Check("SWEEP_MAX_RANGE_PIPS == 40", SWEEP_MAX_RANGE_PIPS == 40.0);
   Check("SWEEP_ATR_FRACTION == 0.60", MathAbs(SWEEP_ATR_FRACTION - 0.60) < 1e-9);
   Check("H4_EMA_PERIOD == 50",        H4_EMA_PERIOD        == 50);
   Check("Sweep trigger runs on M5",   SWEEP_TIMEFRAME      == PERIOD_M5);
   Check("The coiling band caps range width well below the breakout filter",
         SWEEP_MAX_RANGE_PIPS < MAX_RANGE_PIPS,
         "40 pips vs 80 - a fade needs a compressed range, a breakout did not");
   Check("The coiling band is a real band, not an open end",
         SWEEP_MIN_RANGE_PIPS > 0.0 && SWEEP_MIN_RANGE_PIPS < SWEEP_MAX_RANGE_PIPS);

// The sweep model applies its OWN 8-pip floor, which sits below the legacy
// 10-pip one. That is why CheckSweepSignal gates on IsRangeSet() rather than
// IsRangeValid() - routing it through the old validity flag would silently
// discard every 8-9 pip range the new filter was written to accept.
   Check("The sweep floor is deliberately below the legacy range filter",
         SWEEP_MIN_RANGE_PIPS < MIN_RANGE_PIPS,
         "8 vs 10 pips - the sweep path must not inherit the old flag");

//--- GROUP 11: Sweep detection. Range 1.0950-1.1000, pip 0.0001, min sweep 3p.
//    The two halves of the rule are independent, and a test that only proves
//    one of them would pass while the EA traded exactly the wrong direction.
   Check("A 5-pip poke above the high that closes back inside is a sell sweep",
         CSignalEngine::IsSweepAbove(1.1005, 1.0990, hi, pip, 3.0) == true);
   Check("A 3-pip poke exactly meets the threshold",
         CSignalEngine::IsSweepAbove(1.1003, 1.0990, hi, pip, 3.0) == true);
   Check("A 2-pip graze is not a sweep",
         CSignalEngine::IsSweepAbove(1.1002, 1.0990, hi, pip, 3.0) == false,
         "inside the spread, so it means nothing");
   Check("A poke that CLOSES outside is a breakout, not a sweep",
         CSignalEngine::IsSweepAbove(1.1010, 1.1008, hi, pip, 3.0) == false,
         "this is the trade the old strategy took, and it lost");
   Check("A bar that never reaches the high is not a sweep",
         CSignalEngine::IsSweepAbove(1.0995, 1.0980, hi, pip, 3.0) == false);
   Check("A close exactly at the high does not count as back inside",
         CSignalEngine::IsSweepAbove(1.1005, hi, hi, pip, 3.0) == false);

   Check("A 5-pip poke below the low that closes back inside is a buy sweep",
         CSignalEngine::IsSweepBelow(1.0945, 1.0960, lo, pip, 3.0) == true);
   Check("A 2-pip graze below is not a sweep",
         CSignalEngine::IsSweepBelow(1.0948, 1.0960, lo, pip, 3.0) == false);
   Check("A poke below that closes below is a breakdown, not a sweep",
         CSignalEngine::IsSweepBelow(1.0940, 1.0942, lo, pip, 3.0) == false);
   Check("Zero pip size refuses both directions rather than dividing by zero",
         CSignalEngine::IsSweepAbove(1.1005, 1.0990, hi, 0.0, 3.0) == false &&
         CSignalEngine::IsSweepBelow(1.0945, 1.0960, lo, 0.0, 3.0) == false);

//--- GROUP 12: Volatility coiling filter
   Check("A 20-pip range inside a 60-pip ATR day is tradeable",
         CSignalEngine::RangeVolatilityOk(20.0, 60.0, 8.0, 40.0, 0.60) == true);
   Check("A 5-pip range is too quiet to fade",
         CSignalEngine::RangeVolatilityOk(5.0, 60.0, 8.0, 40.0, 0.60) == false);
   Check("A 50-pip range is too wide - a trend is already running",
         CSignalEngine::RangeVolatilityOk(50.0, 120.0, 8.0, 40.0, 0.60) == false);
   Check("A 38-pip range against a 50-pip ATR fails the ratio test",
         CSignalEngine::RangeVolatilityOk(38.0, 50.0, 8.0, 40.0, 0.60) == false,
         "38 is under the 40-pip cap but is 76% of the day's ATR, not 60%");
   Check("The ratio test is skipped when the daily ATR is unavailable",
         CSignalEngine::RangeVolatilityOk(38.0, 0.0, 8.0, 40.0, 0.60) == true,
         "a missing filter must not silently reject every setup");
   Check("An ATR fraction of zero switches the ratio test off",
         CSignalEngine::RangeVolatilityOk(38.0, 50.0, 8.0, 40.0, 0.0) == true);
   Check("The band boundaries are inclusive",
         CSignalEngine::RangeVolatilityOk(8.0,  0.0, 8.0, 40.0, 0.0) == true &&
         CSignalEngine::RangeVolatilityOk(40.0, 0.0, 8.0, 40.0, 0.0) == true);

//--- GROUP 13: Sweep geometry. Sell setup - the bar swept to 1.1006 and closed
//    back at 1.0990. Stop goes 2 pips above the wick; target is 2.5x the stop.
   double sw_hi = 1.1006;
   double sw_lo = 1.0988;

   SSignal fade_s = engine.BuildSweepSignal(_Symbol, false, sw_hi, sw_lo,
                                            1.0991, 1.0990, pip, 2.5, 2.0, 0.0);
   Check("Sell fade is valid", fade_s.valid == true, fade_s.reason);
   Check("Sell fade entry is the bid", MathAbs(fade_s.entry_price - 1.0990) < 1e-8);
   Check("Sell fade stop sits 2 pips above the swept wick",
         MathAbs(fade_s.stop_loss - (sw_hi + 2.0 * pip)) < 1e-8,
         DoubleToString(fade_s.stop_loss, 5));
   Check("Sell fade target is below the entry", fade_s.take_profit < fade_s.entry_price);
   Check("Sell fade delivers exactly 2.5:1 measured from the entry",
         MathAbs((fade_s.entry_price - fade_s.take_profit) /
                 (fade_s.stop_loss - fade_s.entry_price) - 2.5) < 0.001,
         "the old range-measured target quietly paid 1.79:1 on a nominal 2.0");
   Check("Sell fade sl_pips matches the stop distance",
         MathAbs(fade_s.sl_pips - (fade_s.stop_loss - fade_s.entry_price) / pip) < 0.001,
         StringFormat("%.1f pips", fade_s.sl_pips));

   SSignal fade_l = engine.BuildSweepSignal(_Symbol, true, 1.0962, 1.0944,
                                            1.0960, 1.0959, pip, 2.5, 2.0, 0.0);
   Check("Buy fade is valid", fade_l.valid == true, fade_l.reason);
   Check("Buy fade entry is the ask", MathAbs(fade_l.entry_price - 1.0960) < 1e-8);
   Check("Buy fade stop sits 2 pips below the swept wick",
         MathAbs(fade_l.stop_loss - (1.0944 - 2.0 * pip)) < 1e-8);
   Check("Buy fade delivers exactly 2.5:1",
         MathAbs((fade_l.take_profit - fade_l.entry_price) /
                 (fade_l.entry_price - fade_l.stop_loss) - 2.5) < 0.001);

//--- GROUP 14: The slippage penalty must actually cost something.
//    Charging it has to move the fill AGAINST us - a "penalty" that leaves the
//    trade unchanged, or improves it, is worse than none at all because it
//    looks like realism in the report.
   SSignal slip_s = engine.BuildSweepSignal(_Symbol, false, sw_hi, sw_lo,
                                            1.0991, 1.0990, pip, 2.5, 2.0, 0.5);
   Check("Slippage fills a sell below the bid",
         slip_s.entry_price < fade_s.entry_price,
         StringFormat("%.5f vs %.5f", slip_s.entry_price, fade_s.entry_price));
   Check("Slippage leaves a sell with a WIDER stop to survive",
         slip_s.sl_pips > fade_s.sl_pips,
         StringFormat("%.1f vs %.1f pips", slip_s.sl_pips, fade_s.sl_pips));

   SSignal slip_l = engine.BuildSweepSignal(_Symbol, true, 1.0962, 1.0944,
                                            1.0960, 1.0959, pip, 2.5, 2.0, 0.5);
   Check("Slippage fills a buy above the ask",
         slip_l.entry_price > fade_l.entry_price);
   Check("Slippage leaves a buy with a wider stop too",
         slip_l.sl_pips > fade_l.sl_pips);
   Check("Slippage never flatters the R:R - it stays at 2.5:1 on a worse entry",
         MathAbs((slip_l.take_profit - slip_l.entry_price) /
                 (slip_l.entry_price - slip_l.stop_loss) - 2.5) < 0.001);

//--- GROUP 15: Sweep geometry rejects nonsense rather than emitting a bad order
   SSignal sw_bad_pip = engine.BuildSweepSignal(_Symbol, false, sw_hi, sw_lo,
                                                1.0991, 1.0990, 0.0, 2.5, 2.0, 0.0);
   Check("Sweep geometry rejects zero pip size", sw_bad_pip.valid == false);

   SSignal sw_no_quote = engine.BuildSweepSignal(_Symbol, false, sw_hi, sw_lo,
                                                 0.0, 0.0, pip, 2.5, 2.0, 0.0);
   Check("Sweep geometry rejects a missing quote", sw_no_quote.valid == false);

   SSignal sw_inverted = engine.BuildSweepSignal(_Symbol, false, sw_lo, sw_hi,
                                                 1.0991, 1.0990, pip, 2.5, 2.0, 0.0);
   Check("Sweep geometry rejects an inverted candle", sw_inverted.valid == false);

   SSignal sw_bad_rr = engine.BuildSweepSignal(_Symbol, false, sw_hi, sw_lo,
                                               1.0991, 1.0990, pip, 0.0, 2.0, 0.0);
   Check("Sweep geometry rejects a zero reward ratio", sw_bad_rr.valid == false);

// A sell whose bid is already ABOVE the stop leaves the stop on the wrong side.
   SSignal sw_crossed = engine.BuildSweepSignal(_Symbol, false, sw_hi, sw_lo,
                                                1.1050, 1.1049, pip, 2.5, 2.0, 0.0);
   Check("Sweep geometry rejects a crossed stop distance", sw_crossed.valid == false,
         sw_crossed.reason);

   Check("Rejected sweeps never carry a positive stop distance",
         sw_bad_pip.sl_pips == 0.0 && sw_no_quote.sl_pips == 0.0 &&
         sw_inverted.sl_pips == 0.0 && sw_bad_rr.sl_pips == 0.0 &&
         sw_crossed.sl_pips == 0.0);

//--- GROUP 16: H4 bias must always answer with one of three defined states
   int bias = engine.GetH4Bias(_Symbol);
   Check("H4 bias is bull, bear or ambiguous",
         bias == TREND_BULL || bias == TREND_BEAR || bias == TREND_AMBIGUOUS,
         IntegerToString(bias));
   Info("H4 bias now", bias == TREND_BULL ? "BULL" : (bias == TREND_BEAR ? "BEAR" : "AMBIGUOUS"));

//--- GROUP 17: Mode switching. The breakout is retained as the control, so it
//    must still be reachable and must still behave as it did.
   engine.SetMode(ENTRY_MODE_BREAKOUT);
   SSignal ctrl = engine.CheckSignal(_Symbol);
   Check("Breakout mode still returns a decision", StringLen(ctrl.reason) > 0, ctrl.reason);
   engine.SetMode(ENTRY_MODE_SWEEP);
   Check("Entry modes are distinct values", (int)ENTRY_MODE_SWEEP != (int)ENTRY_MODE_BREAKOUT);

//--- GROUP 18: Session windows, including the midnight wrap.
//    The wrap is not a curiosity: a clock defect had this project accidentally
//    measuring 21:00-04:00 UTC for months, and that window outperformed the
//    00:00-07:00 one it was meant to use. Supporting it properly is what turns
//    that accident into a hypothesis that can be tested on purpose.
   Check("A normal window includes its start hour",
         CSignalEngine::HourInWindow(7, 7, 17) == true);
   Check("A normal window excludes its end hour",
         CSignalEngine::HourInWindow(17, 7, 17) == false);
   Check("A normal window includes the hour before the end",
         CSignalEngine::HourInWindow(16, 7, 17) == true);
   Check("A normal window excludes an earlier hour",
         CSignalEngine::HourInWindow(6, 7, 17) == false);

   Check("A wrapping window includes its start hour",
         CSignalEngine::HourInWindow(21, 21, 4) == true);
   Check("A wrapping window includes hours before midnight",
         CSignalEngine::HourInWindow(23, 21, 4) == true);
   Check("A wrapping window includes hours after midnight",
         CSignalEngine::HourInWindow(2, 21, 4) == true);
   Check("A wrapping window excludes its end hour",
         CSignalEngine::HourInWindow(4, 21, 4) == false);
   Check("A wrapping window excludes the middle of the day",
         CSignalEngine::HourInWindow(12, 21, 4) == false);

   Check("An empty window admits nothing rather than everything",
         CSignalEngine::HourInWindow(12, 9, 9) == false,
         "start == end must not be read as all-day");

   Check("The governor and the engine agree on every hour",
         CSignalEngine::HourInWindow(2,  21, 4) == CRiskManager::HourInSession(2,  21, 4) &&
         CSignalEngine::HourInWindow(12, 21, 4) == CRiskManager::HourInSession(12, 21, 4) &&
         CSignalEngine::HourInWindow(7,   7, 17) == CRiskManager::HourInSession(7,   7, 17) &&
         CSignalEngine::HourInWindow(17,  7, 17) == CRiskManager::HourInSession(17,  7, 17),
         "a gate that disagrees with the signal blocks every setup it finds");

//--- Contraction window plumbing
   CAsianRange win;
   win.Init(_Symbol);
   Check("Default contraction window is 00:00-07:00 UTC",
         win.StartHour() == 0 && win.EndHour() == 7);
   Check("The default window does not wrap", win.WrapsMidnight() == false);

   win.SetWindow(21, 4);
   Check("Contraction window is settable",
         win.StartHour() == 21 && win.EndHour() == 4);
   Check("A 21-04 window is detected as wrapping", win.WrapsMidnight() == true);

   win.SetWindow(25, 4);
   Check("An out-of-range hour is refused, not clamped",
         win.StartHour() == 21 && win.EndHour() == 4,
         "clamping a typo to hour 0 would measure a window nobody asked for");

   engine.SetSessionWindows(22, 5, 5, 15);
   Check("Hunt window is settable",
         engine.HuntOpenHour() == 5 && engine.HuntCloseHour() == 15);
   engine.SetSessionWindows(22, 5, 9, 9);
   Check("An empty hunt window is refused",
         engine.HuntOpenHour() == 5 && engine.HuntCloseHour() == 15,
         "accepting it would disable the strategy silently");

// Put the engine back before the live checks below.
   engine.SetSessionWindows(0, 7, 7, 17);

//--- GROUP 9: CheckSignal always returns a decision, never a half-filled struct
   SSignal live = engine.CheckSignal(_Symbol);
   Check("CheckSignal returns a reason", StringLen(live.reason) > 0, live.reason);
   Check("CheckSignal stamps the symbol", live.symbol == _Symbol);
   if(!live.valid)
      Check("An invalid signal exposes no stop distance", live.sl_pips == 0.0);
   Info("CheckSignal now", (live.valid ? "VALID: " : "no trade: ") + live.reason);

//--- Summary
   Print("[QA] ===== RESULT: ", test_passed, " passed, ", test_failed, " failed =====");
  }

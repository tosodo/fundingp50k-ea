//+------------------------------------------------------------------+
//| SignalEngine_tests.mq5                                            |
//| FP50K-EA | Sprint 2 Unit Tests                                    |
//| Tests: Asian range, H4 trend, session gate, signal geometry       |
//+------------------------------------------------------------------+
#property script_show_inputs

#include <fp50k\SignalEngine.mqh>

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

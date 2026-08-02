//+------------------------------------------------------------------+
//| SessionBreakout_tests.mq5                                        |
//| Strategy Lab | offline assertions for LabCore + SessionBreakout   |
//|                                                                  |
//| Purpose : Prove the detection and geometry rules do what the      |
//|           hypothesis says, before a single backtest is run. A     |
//|           strategy that loses because its stop was on the wrong   |
//|           side of the entry has not tested its hypothesis - it    |
//|           has tested a bug, and the rejection would be false.     |
//|                                                                  |
//| These are pure-arithmetic assertions. They exercise NO live       |
//| account, NO price feed and NO calendar. Passing here means the    |
//| maths is right, not that the strategy works.                      |
//|                                                                  |
//| Author  : Tee (aigentforce.io)                                   |
//| Project : Strategy Lab                                           |
//+------------------------------------------------------------------+
#property copyright "Tee - aigentforce.io"
#property version   "1.00"
#property script_show_inputs
#property strict

#include <lab\SessionBreakout.mqh>

int g_pass = 0;
int g_fail = 0;

void Check(string name, bool ok, string detail) {
  if(ok) { g_pass++; Print("[QA] PASS | ", name, " | ", detail); }
  else   { g_fail++; Print("[QA] FAIL | ", name, " | ", detail); }
}

//--- Floating point never compares exactly. One tolerance, stated once.
bool Near(double a, double b, double tol = 0.0000001) {
  return (MathAbs(a - b) <= tol);
}

void OnStart() {
  Print("[QA] ===== SessionBreakout / LabCore assertions =====");

  //================================================================
  // 1. The constants are the round numbers the hypothesis claims
  //================================================================
  Check("Const_AsiaStart",   SB_ASIA_START == 0,      "overnight range opens 00:00 GMT");
  Check("Const_AsiaEnd",     SB_ASIA_END == 7,        "overnight range closes 07:00 GMT");
  Check("Const_BreakStart",  SB_BREAK_START == 7,     "breakout window opens 07:00 GMT");
  Check("Const_BreakEnd",    SB_BREAK_END == 12,      "breakout window shuts 12:00 GMT");
  Check("Const_FlatHour",    SB_FLAT_HOUR == 20,      "flatten at 20:00 GMT");
  Check("Const_AvgDays",     SB_AVG_DAYS == 20,       "compression benchmark = 20 days");
  Check("Const_AtrPeriod",   SB_ATR_PERIOD == 20,     "ATR period 20");
  Check("Const_AtrMult",     Near(SB_ATR_STOP_MULT, 1.5), "stop = 1.5 x ATR");
  Check("Const_RR",          Near(SB_RR_RATIO, 2.0),  "reward:risk 2.0");
  Check("Const_WindowsAbut", SB_ASIA_END == SB_BREAK_START,
        "range closes exactly when the breakout window opens - no gap");

  //================================================================
  // 2. Hour windows are half-open, so an hour belongs to exactly one
  //================================================================
  Check("Win_StartIncluded", LabHourInWindow(0, 0, 7) == true,   "hour 0 is inside [0,7)");
  Check("Win_LastIncluded",  LabHourInWindow(6, 0, 7) == true,   "hour 6 is inside [0,7)");
  Check("Win_EndExcluded",   LabHourInWindow(7, 0, 7) == false,  "hour 7 is NOT inside [0,7)");
  Check("Win_NextStart",     LabHourInWindow(7, 7, 12) == true,  "hour 7 IS inside [7,12)");
  Check("Win_NextLast",      LabHourInWindow(11, 7, 12) == true, "hour 11 is inside [7,12)");
  Check("Win_NextEnd",       LabHourInWindow(12, 7, 12) == false,"hour 12 is NOT inside [7,12)");
  Check("Win_NoOverlap",
        (LabHourInWindow(7, 0, 7) == false) && (LabHourInWindow(7, 7, 12) == true),
        "hour 7 falls in the breakout window only, never both");
  Check("Win_WrapLate",      LabHourInWindow(23, 22, 2) == true, "hour 23 inside wrapped [22,2)");
  Check("Win_WrapEarly",     LabHourInWindow(1, 22, 2) == true,  "hour 1 inside wrapped [22,2)");
  Check("Win_WrapOutside",   LabHourInWindow(5, 22, 2) == false, "hour 5 outside wrapped [22,2)");
  Check("Win_BadHourLow",    LabHourInWindow(-1, 0, 7) == false, "hour -1 is never inside");
  Check("Win_BadHourHigh",   LabHourInWindow(24, 0, 7) == false, "hour 24 is never inside");
  Check("Win_EmptyWindow",   LabHourInWindow(5, 5, 5) == false,
        "start == end is an empty window, not a whole day");

  //--- The named session wrappers must agree with the constants.
  Check("Sess_AsiaMid",      SbInAsianSession(3) == true,     "03:00 GMT is overnight");
  Check("Sess_AsiaOut",      SbInAsianSession(9) == false,    "09:00 GMT is not overnight");
  Check("Sess_BreakMid",     SbInBreakoutWindow(9) == true,   "09:00 GMT is in the breakout window");
  Check("Sess_BreakOut",     SbInBreakoutWindow(15) == false, "15:00 GMT is past the breakout window");

  //================================================================
  // 3. The compression benchmark
  //================================================================
  double vals[];
  ArrayResize(vals, 3);
  vals[0] = 2.0; vals[1] = 4.0; vals[2] = 6.0;
  Check("Avg_Simple",   Near(SbAverage(vals, 3), 4.0),  "mean of 2,4,6 is 4");
  Check("Avg_Partial",  Near(SbAverage(vals, 2), 3.0),
        "count 2 averages only the first two entries, ignoring 6");
  Check("Avg_ZeroCount",Near(SbAverage(vals, 0), 0.0),  "no history averages to 0");
  Check("Avg_Clamped",  Near(SbAverage(vals, 99), 4.0),
        "a count beyond the array is clamped, not read out of bounds");

  Check("Comp_Narrow",  SbIsCompressed(10.0, 20.0) == true,  "10 is below the 20 average");
  Check("Comp_Wide",    SbIsCompressed(30.0, 20.0) == false, "30 is above the 20 average");
  Check("Comp_Tie",     SbIsCompressed(20.0, 20.0) == false,
        "exactly on the average is not compressed - no arbitrary tie-break");
  Check("Comp_ZeroRange",SbIsCompressed(0.0, 20.0) == false, "a zero range is not a setup");
  Check("Comp_NoBench", SbIsCompressed(10.0, 0.0) == false,
        "an empty benchmark must not read as compressed");

  //================================================================
  // 4. Break detection - close-based, never touch-based
  //================================================================
  double hi = 1.1050, lo = 1.1000;
  Check("Brk_Long",     SbBreakoutDir(1.1055, hi, lo) == LAB_LONG,  "close above the range high is long");
  Check("Brk_Short",    SbBreakoutDir(1.0995, hi, lo) == LAB_SHORT, "close below the range low is short");
  Check("Brk_Inside",   SbBreakoutDir(1.1025, hi, lo) == LAB_NONE,  "a close inside the range is no trade");
  Check("Brk_OnHigh",   SbBreakoutDir(hi, hi, lo) == LAB_NONE,
        "closing exactly ON the high is a touch, not a break");
  Check("Brk_OnLow",    SbBreakoutDir(lo, hi, lo) == LAB_NONE,
        "closing exactly ON the low is a touch, not a break");
  Check("Brk_Inverted", SbBreakoutDir(1.1055, lo, hi) == LAB_NONE,
        "an inverted range is rejected rather than traded backwards");
  Check("Brk_BadClose", SbBreakoutDir(0.0, hi, lo) == LAB_NONE,     "a zero close is no trade");

  //================================================================
  // 5. Server clock to GMT
  //================================================================
  datetime gmt = D'2025.06.02 12:00';
  Check("Gmt_Plus2",  SbGmtOffsetSeconds(gmt + 7200, gmt) == 7200,   "server GMT+2 measured as +2h");
  Check("Gmt_Plus3",  SbGmtOffsetSeconds(gmt + 10800, gmt) == 10800, "server GMT+3 measured as +3h");
  Check("Gmt_Minus1", SbGmtOffsetSeconds(gmt - 3600, gmt) == -3600,  "a negative offset is preserved");
  Check("Gmt_Zero",   SbGmtOffsetSeconds(gmt, gmt) == 0,             "an aligned server reads as GMT+0");
  Check("Gmt_Drift",  SbGmtOffsetSeconds(gmt + 7203, gmt) == 7200,
        "3 seconds of clock drift rounds away instead of shifting an hour");
  Check("Gmt_Unset",  SbGmtOffsetSeconds(0, 0) == 0, "unset clocks give 0 rather than nonsense");

  //================================================================
  // 6. Trade geometry - LONG
  //     ask 1.10000, slip 0.5 pip -> fill 1.10005
  //     ATR 0.0020 x 1.5          -> stop 0.0030 = 30 pips
  //     SL 1.10005 - 0.0030       =  1.09705
  //     TP 1.10005 + 0.0060       =  1.10605
  //================================================================
  double pip = 0.0001;
  LabSignal L = LabBuildSignal(LAB_LONG, 1.10000, 1.09990, 0.0020, pip, 1.5, 2.0, 0.5);
  Check("Long_Dir",    L.dir == LAB_LONG,               "direction survives the build");
  Check("Long_Entry",  Near(L.entry_price, 1.10005),    "fill is the ask worsened by slippage");
  Check("Long_SL",     Near(L.stop_loss, 1.09705),      "stop is 1.5 ATR below the fill");
  Check("Long_TP",     Near(L.take_profit, 1.10605),    "target is 2x the stop distance above");
  Check("Long_SlPips", Near(L.sl_pips, 30.0, 0.0001),   "stop measures 30 pips");
  Check("Long_RR",
        Near((L.take_profit - L.entry_price) / (L.entry_price - L.stop_loss), 2.0, 0.000001),
        "reward:risk is 2.0 measured off the actual prices, not assumed");

  //================================================================
  // 7. Trade geometry - SHORT (mirror image)
  //================================================================
  LabSignal S = LabBuildSignal(LAB_SHORT, 1.10000, 1.09990, 0.0020, pip, 1.5, 2.0, 0.5);
  Check("Short_Dir",   S.dir == LAB_SHORT,              "direction survives the build");
  Check("Short_Entry", Near(S.entry_price, 1.09985),    "fill is the bid worsened by slippage");
  Check("Short_SL",    Near(S.stop_loss, 1.10285),      "stop is 1.5 ATR above the fill");
  Check("Short_TP",    Near(S.take_profit, 1.09385),    "target is 2x the stop distance below");
  Check("Short_SlPips",Near(S.sl_pips, 30.0, 0.0001),   "stop measures 30 pips");
  Check("Short_RR",
        Near((S.entry_price - S.take_profit) / (S.stop_loss - S.entry_price), 2.0, 0.000001),
        "reward:risk is 2.0 measured off the actual prices, not assumed");

  //--- Slippage must cost money without secretly widening the stop.
  LabSignal N = LabBuildSignal(LAB_LONG, 1.10000, 1.09990, 0.0020, pip, 1.5, 2.0, 0.0);
  Check("Slip_WorsensFill", L.entry_price > N.entry_price,
        "a slipped long fills higher than an unslipped one");
  Check("Slip_SameStop",    Near(L.sl_pips, N.sl_pips, 0.0001),
        "the stop stays 30 pips - it is anchored to ATR, not to the fill");

  //================================================================
  // 8. Guards - bad input must return no trade, never a broken one
  //================================================================
  Check("Guard_NoDir",  LabBuildSignal(LAB_NONE, 1.1, 1.1, 0.002, pip, 1.5, 2.0, 0.5).dir == LAB_NONE,
        "no direction gives no trade");
  Check("Guard_ZeroAtr",LabBuildSignal(LAB_LONG, 1.1, 1.1, 0.0, pip, 1.5, 2.0, 0.5).dir == LAB_NONE,
        "a zero ATR gives no trade rather than a zero-width stop");
  Check("Guard_ZeroPip",LabBuildSignal(LAB_LONG, 1.1, 1.1, 0.002, 0.0, 1.5, 2.0, 0.5).dir == LAB_NONE,
        "a zero pip size gives no trade rather than a divide by zero");
  Check("Guard_BadQuote",LabBuildSignal(LAB_LONG, 0.0, 0.0, 0.002, pip, 1.5, 2.0, 0.5).dir == LAB_NONE,
        "a dead quote gives no trade");
  Check("Guard_ZeroMult",LabBuildSignal(LAB_LONG, 1.1, 1.1, 0.002, pip, 0.0, 2.0, 0.5).dir == LAB_NONE,
        "a zero ATR multiple gives no trade");
  Check("Guard_ZeroRR", LabBuildSignal(LAB_LONG, 1.1, 1.1, 0.002, pip, 1.5, 0.0, 0.5).dir == LAB_NONE,
        "a zero reward:risk gives no trade");

  //================================================================
  // 8b. H3 geometry - the stop IS the far side of the range
  //     range 1.1000 - 1.1050, break long, ask 1.10520, slip 0.5 pip
  //     fill  1.10525
  //     stop  1.10000 (the range low)      -> 52.5 pips
  //     tp    1.10525 + 2 x 0.00525        =  1.11575
  //================================================================
  double rhi = 1.1050, rlo = 1.1000;
  LabSignal RL = SbBuildRangeSignal(LAB_LONG, 1.10520, 1.10505, rhi, rlo, pip, 2.0, 0.5);
  Check("RngL_Dir",    RL.dir == LAB_LONG,             "long survives the build");
  Check("RngL_Entry",  Near(RL.entry_price, 1.10525),  "fill is the ask worsened by slippage");
  Check("RngL_SL",     Near(RL.stop_loss, rlo),        "stop sits exactly on the range low");
  Check("RngL_SlPips", Near(RL.sl_pips, 52.5, 0.0001), "risk is the distance to the far side");
  Check("RngL_TP",     Near(RL.take_profit, 1.11575),  "target is 2x that distance above");
  Check("RngL_RR",
        Near((RL.take_profit - RL.entry_price) / (RL.entry_price - RL.stop_loss), 2.0, 0.000001),
        "reward:risk is 2.0 measured off the actual prices");

  //--- Short mirror: break below the low, stop on the range high.
  LabSignal RS = SbBuildRangeSignal(LAB_SHORT, 1.09995, 1.09980, rhi, rlo, pip, 2.0, 0.5);
  Check("RngS_Dir",    RS.dir == LAB_SHORT,            "short survives the build");
  Check("RngS_Entry",  Near(RS.entry_price, 1.09975),  "fill is the bid worsened by slippage");
  Check("RngS_SL",     Near(RS.stop_loss, rhi),        "stop sits exactly on the range high");
  Check("RngS_SlPips", Near(RS.sl_pips, 52.5, 0.0001), "risk is the distance to the far side");
  // 1.09975 - 2 x 0.00525 = 1.08925
  Check("RngS_TP",     Near(RS.take_profit, 1.08925),  "target is 2x that distance below");
  Check("RngS_RR",
        Near((RS.entry_price - RS.take_profit) / (RS.stop_loss - RS.entry_price), 2.0, 0.000001),
        "reward:risk is 2.0 measured off the actual prices");

  //--- The whole point of H3: the stop must dwarf the costs.
  Check("RngL_BeatsCosts", RL.sl_pips > 20.0,
        "a range stop is tens of pips, not the ~5 that killed H2");

  //--- Slippage must widen the measured risk, not vanish into it. A
  //--- worse fill really is further from a stop that is pinned to a
  //--- fixed price level.
  LabSignal RN = SbBuildRangeSignal(LAB_LONG, 1.10520, 1.10505, rhi, rlo, pip, 2.0, 0.0);
  Check("RngL_SlipWidensRisk", RL.sl_pips > RN.sl_pips,
        "slipping into a fixed stop level increases the risk taken");

  //--- Guards
  Check("RngG_NoDir",   SbBuildRangeSignal(LAB_NONE, 1.105, 1.105, rhi, rlo, pip, 2.0, 0.5).dir == LAB_NONE,
        "no direction gives no trade");
  Check("RngG_BadRange",SbBuildRangeSignal(LAB_LONG, 1.105, 1.105, rlo, rhi, pip, 2.0, 0.5).dir == LAB_NONE,
        "an inverted range gives no trade");
  Check("RngG_ZeroPip", SbBuildRangeSignal(LAB_LONG, 1.105, 1.105, rhi, rlo, 0.0, 2.0, 0.5).dir == LAB_NONE,
        "a zero pip size gives no trade");
  Check("RngG_BadQuote",SbBuildRangeSignal(LAB_LONG, 0.0, 0.0, rhi, rlo, pip, 2.0, 0.5).dir == LAB_NONE,
        "a dead quote gives no trade");
  Check("RngG_ZeroRR",  SbBuildRangeSignal(LAB_LONG, 1.105, 1.105, rhi, rlo, pip, 0.0, 0.5).dir == LAB_NONE,
        "a zero reward:risk gives no trade");
  Check("RngG_ThroughStop",
        SbBuildRangeSignal(LAB_LONG, 1.09900, 1.09890, rhi, rlo, pip, 2.0, 0.5).dir == LAB_NONE,
        "a fill already below the range low is refused, not opened pre-stopped");

  //================================================================
  // 9. Break-even win rate = 100 / (1 + RR)
  //================================================================
  Check("BE_2to1",   Near(LabBreakEvenWinPct(2.0), 33.3333333, 0.0001), "2:1 needs 33.33%");
  Check("BE_1to1",   Near(LabBreakEvenWinPct(1.0), 50.0, 0.0001),       "1:1 needs 50%");
  Check("BE_1p5to1", Near(LabBreakEvenWinPct(1.5), 40.0, 0.0001),       "1.5:1 needs 40%");
  Check("BE_3to1",   Near(LabBreakEvenWinPct(3.0), 25.0, 0.0001),       "3:1 needs 25%");
  Check("BE_Invalid",Near(LabBreakEvenWinPct(0.0), 100.0, 0.0001),
        "an invalid RR reports 100% - impossible, so it can never pass by accident");

  //================================================================
  // 10. Lot sizing - never risk more than the budget
  //     $500 risk / (30 pips x $10 per pip) = 1.6666 lots
  //================================================================
  Check("Lots_RoundsDown", Near(LabLotsFromRisk(500.0, 30.0, 10.0, 0.01, 0.01, 100.0), 1.66, 0.0001),
        "1.6666 rounds DOWN to 1.66 - rounding up would exceed the risk budget");
  Check("Lots_BelowMin",   Near(LabLotsFromRisk(1.0, 30.0, 10.0, 0.01, 0.10, 100.0), 0.0, 0.0001),
        "a size under the broker minimum is refused, not rounded up to it");
  Check("Lots_CappedMax",  Near(LabLotsFromRisk(500000.0, 30.0, 10.0, 0.01, 0.01, 5.0), 5.0, 0.0001),
        "size is capped at the broker maximum");
  Check("Lots_ZeroStop",   Near(LabLotsFromRisk(500.0, 0.0, 10.0, 0.01, 0.01, 100.0), 0.0, 0.0001),
        "a zero stop gives no position rather than an infinite one");
  Check("Lots_ZeroPipVal", Near(LabLotsFromRisk(500.0, 30.0, 0.0, 0.01, 0.01, 100.0), 0.0, 0.0001),
        "an unknown pip value gives no position");
  Check("Lots_ZeroRisk",   Near(LabLotsFromRisk(0.0, 30.0, 10.0, 0.01, 0.01, 100.0), 0.0, 0.0001),
        "zero risk gives no position");

  Print("[QA] ===== RESULT: ", g_pass, " passed, ", g_fail, " failed =====");
}

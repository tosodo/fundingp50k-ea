//+------------------------------------------------------------------+
//| TrendPullback_tests.mq5                                          |
//| Strategy Lab | Offline assertions for the H1 signal logic        |
//|                                                                  |
//| Runs as a Script, not under the Tester: the Strategy Tester needs |
//| a real account login, whereas a script attaches to an offline     |
//| chart with no connection. Everything asserted here is pure        |
//| arithmetic, so no broker, quote feed or account is involved.      |
//|                                                                  |
//| What this does NOT verify: that the live indicator handles read   |
//| the values expected, or that orders fill. Those need a real feed. |
//|                                                                  |
//| Author  : Tee (aigentforce.io)                                   |
//+------------------------------------------------------------------+
#property copyright "Tee - aigentforce.io"
#property version   "1.00"
#property script_show_inputs

#include <lab\TrendPullback.mqh>

int g_pass = 0;
int g_fail = 0;

void Check(string name, bool condition, string detail = "") {
  if(condition) { g_pass++; Print("[QA] PASS | ", name, " | ", detail); }
  else          { g_fail++; Print("[QA] FAIL | ", name, " | ", detail); }
}

bool Near(double a, double b, double tol = 0.0001) {
  return (MathAbs(a - b) <= tol);
}

void OnStart() {
  Print("[QA] ===== TrendPullback: signal logic =====");

  //--- Parameters are the round numbers they claim to be -------------
  Check("Const_EmaTrend_200",   TP_EMA_TREND == 200,      "regime EMA");
  Check("Const_EmaPullback_50", TP_EMA_PULLBACK == 50,    "pullback EMA");
  Check("Const_AtrPeriod_20",   TP_ATR_PERIOD == 20,      "ATR period");
  Check("Const_AtrMult_2",      Near(TP_ATR_STOP_MULT, 2.0), "stop multiple");
  Check("Const_RR_2",           Near(TP_RR_RATIO, 2.0),   "reward:risk");

  //--- Regime ---------------------------------------------------------
  Check("Regime_Above_IsLong",  TpRegime(1.1050, 1.1000) == TP_LONG,  "close above EMA");
  Check("Regime_Below_IsShort", TpRegime(1.0950, 1.1000) == TP_SHORT, "close below EMA");
  Check("Regime_Equal_IsNone",  TpRegime(1.1000, 1.1000) == TP_NONE,
        "exactly on the EMA is no trade, not an arbitrary side");
  Check("Regime_BadInput_IsNone", TpRegime(0.0, 1.1000) == TP_NONE, "guards zero input");

  //--- Touch ----------------------------------------------------------
  Check("Touch_Long_WickInto",  TpTouched(1.1080, 1.0995, 1.1000, true),
        "low 1.0995 pierces EMA 1.1000");
  Check("Touch_Long_NoReach",  !TpTouched(1.1080, 1.1010, 1.1000, true),
        "low stayed above the EMA");
  Check("Touch_Long_ExactTag",  TpTouched(1.1080, 1.1000, 1.1000, true),
        "touching exactly counts as reaching");
  Check("Touch_Short_WickInto", TpTouched(1.1005, 1.0920, 1.1000, false),
        "high 1.1005 pierces EMA from below");
  Check("Touch_Short_NoReach", !TpTouched(1.0990, 1.0920, 1.1000, false),
        "high stayed below the EMA");

  //--- Reclaim --------------------------------------------------------
  Check("Reclaim_Long_Above",   TpReclaimed(1.1020, 1.1000, true),  "closed back above");
  Check("Reclaim_Long_Below",  !TpReclaimed(1.0980, 1.1000, true),  "closed through, no signal");
  Check("Reclaim_Long_Equal",  !TpReclaimed(1.1000, 1.1000, true),  "closing ON the EMA is not a reclaim");
  Check("Reclaim_Short_Below",  TpReclaimed(1.0980, 1.1000, false), "closed back below");
  Check("Reclaim_Short_Above", !TpReclaimed(1.1020, 1.1000, false), "closed through, no signal");

  //--- The full one-bar trigger ---------------------------------------
  Check("Signal_Long_TouchAndReclaim",
        TpIsSignalBar(1.1080, 1.0990, 1.1030, 1.1000, true),
        "wick into 1.0990, close back at 1.1030");
  Check("Signal_Long_TouchNoReclaim",
        !TpIsSignalBar(1.1080, 1.0990, 1.0995, 1.1000, true),
        "reached the EMA but closed below it - trend may be breaking, no trade");
  Check("Signal_Long_ReclaimNoTouch",
        !TpIsSignalBar(1.1080, 1.1010, 1.1050, 1.1000, true),
        "never pulled back - chasing, not a pullback entry");
  Check("Signal_Short_TouchAndReclaim",
        TpIsSignalBar(1.1010, 1.0920, 1.0970, 1.1000, false),
        "wick up into 1.1010, close back at 1.0970");
  Check("Signal_Short_TouchNoReclaim",
        !TpIsSignalBar(1.1010, 1.0920, 1.1005, 1.1000, false),
        "closed above the EMA - no short");

  //--- Geometry: long --------------------------------------------------
  // ask 1.1000, slippage 0.5 pip -> fill 1.10005
  // ATR 0.0020 x 2.0 -> stop 0.0040 -> SL 1.09605, 40 pips
  // TP = fill + 2.0 x 0.0040 = 1.10805
  TPSignal L = TpBuildSignal(TP_LONG, 1.1000, 1.0998, 0.0020, 0.0001, 2.0, 2.0, 0.5);
  Check("Geom_Long_Fires",     L.dir == TP_LONG, L.reason);
  Check("Geom_Long_Entry",     Near(L.entry_price, 1.10005, 0.000001),
        "slippage worsens a buy fill: " + DoubleToString(L.entry_price, 5));
  Check("Geom_Long_Stop",      Near(L.stop_loss, 1.09605, 0.000001),
        DoubleToString(L.stop_loss, 5));
  Check("Geom_Long_SlPips",    Near(L.sl_pips, 40.0, 0.01),
        "2.0 x ATR(0.0020) = 40 pips");
  Check("Geom_Long_Target",    Near(L.take_profit, 1.10805, 0.000001),
        DoubleToString(L.take_profit, 5));
  Check("Geom_Long_RewardIsTwiceRisk",
        Near((L.take_profit - L.entry_price) / (L.entry_price - L.stop_loss), 2.0, 0.001),
        "reward:risk measured off the actual prices, not assumed");

  //--- Geometry: short -------------------------------------------------
  // bid 1.1000, slippage 0.5 pip -> fill 1.09995
  TPSignal S = TpBuildSignal(TP_SHORT, 1.1002, 1.1000, 0.0020, 0.0001, 2.0, 2.0, 0.5);
  Check("Geom_Short_Fires",    S.dir == TP_SHORT, S.reason);
  Check("Geom_Short_Entry",    Near(S.entry_price, 1.09995, 0.000001),
        "slippage worsens a sell fill: " + DoubleToString(S.entry_price, 5));
  Check("Geom_Short_StopAbove", S.stop_loss > S.entry_price, "stop sits above a short");
  Check("Geom_Short_TargetBelow", S.take_profit < S.entry_price, "target sits below a short");
  Check("Geom_Short_RewardIsTwiceRisk",
        Near((S.entry_price - S.take_profit) / (S.stop_loss - S.entry_price), 2.0, 0.001),
        "reward:risk measured off the actual prices");

  //--- Slippage genuinely costs money -----------------------------------
  TPSignal NoSlip = TpBuildSignal(TP_LONG, 1.1000, 1.0998, 0.0020, 0.0001, 2.0, 2.0, 0.0);
  Check("Slippage_WorsensEntry", L.entry_price > NoSlip.entry_price,
        "a slipped buy fills higher than the quote");
  Check("Slippage_SameStopDistance", Near(L.sl_pips, NoSlip.sl_pips, 0.01),
        "the stop is ATR-based, so slippage shifts it rather than widening it");

  //--- Guards -----------------------------------------------------------
  Check("Guard_NoRegime",  TpBuildSignal(TP_NONE, 1.1, 1.1, 0.002, 0.0001, 2.0, 2.0, 0.5).dir == TP_NONE, "flat regime");
  Check("Guard_ZeroAtr",   TpBuildSignal(TP_LONG, 1.1, 1.1, 0.000, 0.0001, 2.0, 2.0, 0.5).dir == TP_NONE, "zero ATR");
  Check("Guard_ZeroPip",   TpBuildSignal(TP_LONG, 1.1, 1.1, 0.002, 0.0000, 2.0, 2.0, 0.5).dir == TP_NONE, "zero pip");
  Check("Guard_ZeroQuote", TpBuildSignal(TP_LONG, 0.0, 0.0, 0.002, 0.0001, 2.0, 2.0, 0.5).dir == TP_NONE, "no quote");

  //--- Break-even win rate ------------------------------------------------
  Check("BreakEven_RR2",   Near(TpBreakEvenWinPct(2.0), 33.3333, 0.001), "2:1 needs 33.33%");
  Check("BreakEven_RR1",   Near(TpBreakEvenWinPct(1.0), 50.0,    0.001), "1:1 needs 50%");
  Check("BreakEven_RR25",  Near(TpBreakEvenWinPct(2.5), 28.5714, 0.001), "2.5:1 needs 28.57%");
  Check("BreakEven_RR3",   Near(TpBreakEvenWinPct(3.0), 25.0,    0.001), "3:1 needs 25%");

  //--- Lot sizing ----------------------------------------------------------
  // $500 risk over a 40-pip stop at $10/pip/lot = 1.25 lots
  Check("Lots_Basic", Near(TpLotsFromRisk(500.0, 40.0, 10.0, 0.01, 0.01, 100.0), 1.25, 0.001),
        "500 / (40 x 10)");
  Check("Lots_RoundsDown",
        TpLotsFromRisk(500.0, 37.0, 10.0, 0.01, 0.01, 100.0) <= 500.0 / (37.0 * 10.0),
        "never rounds up past the risk budget");
  Check("Lots_BelowMinimum_IsZero",
        Near(TpLotsFromRisk(1.0, 400.0, 10.0, 0.01, 0.10, 100.0), 0.0, 0.0001),
        "too small to trade returns zero rather than the minimum");
  Check("Lots_CappedAtMax",
        Near(TpLotsFromRisk(500000.0, 10.0, 10.0, 0.01, 0.01, 5.0), 5.0, 0.001),
        "broker volume ceiling respected");
  Check("Lots_ZeroStop_IsZero",
        Near(TpLotsFromRisk(500.0, 0.0, 10.0, 0.01, 0.01, 100.0), 0.0, 0.0001), "guards zero stop");

  Print("[QA] ===== RESULT: ", g_pass, " passed, ", g_fail, " failed =====");
}

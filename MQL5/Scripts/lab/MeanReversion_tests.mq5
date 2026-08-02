//+------------------------------------------------------------------+
//| MeanReversion_tests.mq5                                          |
//| Strategy Lab | Offline assertions for Hypothesis H4              |
//|                                                                  |
//| Every rule in MeanReversion.mqh is pure arithmetic, so all of it  |
//| can be checked without a broker, a feed, or a calendar. Nothing   |
//| here exercises a live connection - a PASS means the maths is      |
//| right, not that the strategy works.                               |
//|                                                                   |
//| Prices are chosen so the expected answers are exact and can be    |
//| checked by hand: mean 1.10000, ATR 0.00250 (25 pips), so the      |
//| 2.0 ATR entry threshold sits exactly 50 pips from the mean.       |
//|                                                                   |
//| Author  : Tee (aigentforce.io)                                   |
//| Project : Strategy Lab                                           |
//+------------------------------------------------------------------+
#property copyright "Tee - aigentforce.io"
#property version   "1.00"
#property strict

#include <lab\MeanReversion.mqh>

int g_pass = 0;
int g_fail = 0;

void Check(string name, bool ok, string detail) {
  if(ok) { g_pass++; Print("[QA] PASS | ", name, " | ", detail); }
  else   { g_fail++; Print("[QA] FAIL | ", name, " | ", detail); }
}

bool Near(double a, double b, double tol = 0.0000001) {
  return (MathAbs(a - b) <= tol);
}

void OnStart() {
  Print("[QA] ===== MeanReversion (H4) offline assertions =====");

  double MA   = 1.10000;
  double ATR  = 0.00250;   // 25 pips
  double PIP  = 0.00010;

  //================================================================
  // 1. The constants are the ones the hypothesis was written with.
  //    A silent edit to a #define would otherwise change what is
  //    being measured without changing anything that is read.
  //================================================================
  Check("Const_MaPeriod",  MR_MA_PERIOD  == 20,  "mean is 20 bars");
  Check("Const_AtrPeriod", MR_ATR_PERIOD == 20,  "ATR is 20 bars");
  Check("Const_EntryAtr",  Near(MR_ENTRY_ATR, 2.0), "overextended at 2.0 ATR");
  Check("Const_StopAtr",   Near(MR_STOP_ATR,  2.0), "stop at 2.0 ATR");
  Check("Const_HoldBars",  MR_HOLD_BARS  == 24,  "give up after 24 bars");
  Check("Const_HourStart", MR_HOUR_START == 7,   "entries from 07:00 GMT");
  Check("Const_HourEnd",   MR_HOUR_END   == 20,  "entries until 20:00 GMT");

  //================================================================
  // 2. Direction detection. Threshold is MA -/+ 2.0 * 0.00250,
  //    i.e. 1.09500 and 1.10500 exactly.
  //================================================================
  Check("Dir_FarBelow",
        MrStretchDir(1.09400, MA, ATR, 2.0) == LAB_LONG,
        "60 pips below the mean -> fade upward (long)");
  Check("Dir_FarAbove",
        MrStretchDir(1.10600, MA, ATR, 2.0) == LAB_SHORT,
        "60 pips above the mean -> fade downward (short)");
  Check("Dir_AtMean",
        MrStretchDir(1.10000, MA, ATR, 2.0) == LAB_NONE,
        "sitting on the mean is not a signal");
  Check("Dir_JustInside",
        MrStretchDir(1.09510, MA, ATR, 2.0) == LAB_NONE,
        "49 pips below is inside the threshold, no signal");

  // Exactly on the threshold must NOT fire. Same no-arbitrary-tie-break
  // rule as the rest of the lab: a boundary case that fires is a boundary
  // case that can be tuned.
  Check("Dir_ExactlyOnLower",
        MrStretchDir(1.09500, MA, ATR, 2.0) == LAB_NONE,
        "exactly 2.0 ATR below is a touch, not an overextension");
  Check("Dir_ExactlyOnUpper",
        MrStretchDir(1.10500, MA, ATR, 2.0) == LAB_NONE,
        "exactly 2.0 ATR above is a touch, not an overextension");
  Check("Dir_JustOutside",
        MrStretchDir(1.09499, MA, ATR, 2.0) == LAB_LONG,
        "a hair beyond the threshold does fire");

  //================================================================
  // 3. Guards. Every one of these returns "no trade" rather than a
  //    number, because a bad input that produces a plausible signal
  //    is the failure mode that does not announce itself.
  //================================================================
  Check("DirG_ZeroAtr",
        MrStretchDir(1.09400, MA, 0.0, 2.0) == LAB_NONE,
        "zero ATR gives no signal");
  Check("DirG_NegAtr",
        MrStretchDir(1.09400, MA, -0.00250, 2.0) == LAB_NONE,
        "negative ATR gives no signal");
  Check("DirG_ZeroMa",
        MrStretchDir(1.09400, 0.0, ATR, 2.0) == LAB_NONE,
        "zero mean gives no signal");
  Check("DirG_ZeroClose",
        MrStretchDir(0.0, MA, ATR, 2.0) == LAB_NONE,
        "zero close gives no signal");
  Check("DirG_ZeroMult",
        MrStretchDir(1.09400, MA, ATR, 0.0) == LAB_NONE,
        "zero entry multiple gives no signal");

  //================================================================
  // 4. Stretch measurement (diagnostic only, but it is printed with
  //    every entry, so a wrong one would mislead a later diagnosis).
  //================================================================
  Check("Stretch_Below",
        Near(MrStretchAtrs(1.09500, MA, ATR), 2.0),
        "50 pips below with a 25 pip ATR is 2.0 ATR");
  Check("Stretch_Above",
        Near(MrStretchAtrs(1.10750, MA, ATR), 3.0),
        "75 pips above is 3.0 ATR");
  Check("Stretch_Abs",
        Near(MrStretchAtrs(1.09250, MA, ATR),
             MrStretchAtrs(1.10750, MA, ATR)),
        "distance is unsigned: equal stretches either side match");
  Check("Stretch_ZeroAtr",
        Near(MrStretchAtrs(1.09500, MA, 0.0), 0.0),
        "zero ATR reports zero rather than dividing by it");

  //================================================================
  // 5. Long geometry. Close 1.09400, bid 1.09400, ask 1.09415
  //    (1.5 pip spread), slippage 0.5 pips.
  //      entry  = 1.09415 + 0.00005 = 1.09420
  //      stop   = 1.09420 - 0.00500 = 1.08920   (2.0 x 25 pips)
  //      target = the mean          = 1.10000
  //      reward = 0.00580 = 58 pips, risk 50 pips -> RR 1.16
  //================================================================
  LabSignal L = MrBuildSignal(LAB_LONG, 1.09415, 1.09400, MA, ATR, PIP, 2.0, 0.5);

  Check("Long_Fires",  L.dir == LAB_LONG,           "a long is produced");
  Check("Long_Entry",  Near(L.entry_price, 1.09420), "fills at ask plus slippage");
  Check("Long_Stop",   Near(L.stop_loss,   1.08920), "stop is 50 pips below the fill");
  Check("Long_Target", Near(L.take_profit, 1.10000), "target IS the mean, unmodified");
  Check("Long_SlPips", Near(L.sl_pips, 50.0),        "risk is 50 pips");
  Check("Long_RR",     Near(MrRealisedRR(L), 0.00580 / 0.00500),
        "RR measured off the actual prices, not the inputs");
  Check("Long_RewardBeatsRisk", MrRealisedRR(L) > 1.0,
        "fading from beyond the threshold pays more than it risks");

  //================================================================
  // 6. Short geometry, mirrored. Bid 1.10600, ask 1.10615.
  //      entry  = 1.10600 - 0.00005 = 1.10595
  //      stop   = 1.10595 + 0.00500 = 1.11095
  //      target = 1.10000
  //      reward = 0.00595 = 59.5 pips, risk 50 pips
  //================================================================
  LabSignal S = MrBuildSignal(LAB_SHORT, 1.10615, 1.10600, MA, ATR, PIP, 2.0, 0.5);

  Check("Short_Fires",  S.dir == LAB_SHORT,           "a short is produced");
  Check("Short_Entry",  Near(S.entry_price, 1.10595), "fills at bid minus slippage");
  Check("Short_Stop",   Near(S.stop_loss,   1.11095), "stop is 50 pips above the fill");
  Check("Short_Target", Near(S.take_profit, 1.10000), "target IS the mean");
  Check("Short_SlPips", Near(S.sl_pips, 50.0),        "risk is 50 pips");
  Check("Short_RR",     Near(MrRealisedRR(S), 0.00595 / 0.00500),
        "RR measured off the actual prices");

  //================================================================
  // 7. Slippage must move the RIGHT things. On a fade the fill is
  //    pushed TOWARD the mean, so the reward shrinks; the risk is
  //    unchanged because the stop is measured from the fill.
  //
  //    An earlier version of this section asserted the opposite and
  //    failed, which is how the mistake in the header comment was
  //    found. Kept as a worked case rather than deleted.
  //      no slippage: entry 1.09415, reward 0.00585, RR 1.170
  //      0.5 pips   : entry 1.09420, reward 0.00580, RR 1.160
  //================================================================
  LabSignal L0 = MrBuildSignal(LAB_LONG, 1.09415, 1.09400, MA, ATR, PIP, 2.0, 0.0);
  Check("Slip_SameRisk", Near(L0.sl_pips, L.sl_pips),
        "slippage does not change the 50 pip risk");
  Check("Slip_WorseEntry", L.entry_price > L0.entry_price,
        "slippage genuinely worsens the fill");
  Check("Slip_LessReward", MrRealisedRR(L) < MrRealisedRR(L0),
        "paying more on a long fade sits closer to the mean, so reward shrinks");
  Check("Slip_RewardExact", Near(MrRealisedRR(L0), 0.00585 / 0.00500),
        "unslipped RR is 1.170 exactly");

  //================================================================
  // 8. Cost geometry - the H2 lesson, asserted rather than assumed.
  //    A 50 pip stop against ~2 pips of cost is 4%. H2's five pip
  //    stop was 40% and that alone made it unwinnable.
  //================================================================
  Check("Cost_StopDwarfsCosts", L.sl_pips > 20.0,
        "stop is tens of pips, not the ~5 that made H2 impossible");
  double cost_share = 2.0 / L.sl_pips;
  Check("Cost_ShareSmall", cost_share < 0.10,
        "spread plus slippage is under 10% of the risk");

  //================================================================
  // 9. Build guards.
  //================================================================
  LabSignal G;

  G = MrBuildSignal(LAB_NONE, 1.09415, 1.09400, MA, ATR, PIP, 2.0, 0.5);
  Check("BldG_NoDir", G.dir == LAB_NONE, "no direction -> no trade");

  G = MrBuildSignal(LAB_LONG, 0.0, 1.09400, MA, ATR, PIP, 2.0, 0.5);
  Check("BldG_ZeroAsk", G.dir == LAB_NONE, "zero ask -> no trade");

  G = MrBuildSignal(LAB_LONG, 1.09415, 0.0, MA, ATR, PIP, 2.0, 0.5);
  Check("BldG_ZeroBid", G.dir == LAB_NONE, "zero bid -> no trade");

  G = MrBuildSignal(LAB_LONG, 1.09415, 1.09400, 0.0, ATR, PIP, 2.0, 0.5);
  Check("BldG_ZeroMa", G.dir == LAB_NONE, "zero mean -> no trade");

  G = MrBuildSignal(LAB_LONG, 1.09415, 1.09400, MA, 0.0, PIP, 2.0, 0.5);
  Check("BldG_ZeroAtr", G.dir == LAB_NONE, "zero ATR -> no trade");

  G = MrBuildSignal(LAB_LONG, 1.09415, 1.09400, MA, ATR, 0.0, 2.0, 0.5);
  Check("BldG_ZeroPip", G.dir == LAB_NONE, "zero pip size -> no trade");

  G = MrBuildSignal(LAB_LONG, 1.09415, 1.09400, MA, ATR, PIP, 0.0, 0.5);
  Check("BldG_ZeroStopMult", G.dir == LAB_NONE, "zero stop multiple -> no trade");

  // The one that actually matters: a long whose fill is already at or above
  // the mean would book a target it has passed. Ask 1.10050 is above MA.
  G = MrBuildSignal(LAB_LONG, 1.10050, 1.10035, MA, ATR, PIP, 2.0, 0.5);
  Check("BldG_LongPastMean", G.dir == LAB_NONE,
        "a long filled above the mean is refused, not booked as a free win");

  G = MrBuildSignal(LAB_SHORT, 1.09965, 1.09950, MA, ATR, PIP, 2.0, 0.5);
  Check("BldG_ShortPastMean", G.dir == LAB_NONE,
        "a short filled below the mean is refused");

  // Exactly on the mean is zero reward, which is also refused.
  G = MrBuildSignal(LAB_LONG, 1.09995, 1.09980, MA, ATR, PIP, 2.0, 0.5);
  Check("BldG_LongAtMean", G.dir == LAB_NONE,
        "a long filled exactly on the mean has no reward and is refused");

  //================================================================
  // 10. RR helper guards.
  //================================================================
  LabSignal empty;
  Check("RR_NoTrade", Near(MrRealisedRR(empty), 0.0),
        "an empty signal reports zero RR rather than dividing by zero");

  //================================================================
  // 11. Entry hour window, half-open [07:00, 20:00).
  //================================================================
  Check("Hour_Start",   MrEntryHourAllowed(7),   "07:00 is inside");
  Check("Hour_Mid",     MrEntryHourAllowed(13),  "13:00 is inside");
  Check("Hour_Last",    MrEntryHourAllowed(19),  "19:00 is the last allowed hour");
  Check("Hour_End",    !MrEntryHourAllowed(20),  "20:00 is outside - half open");
  Check("Hour_Early",  !MrEntryHourAllowed(6),   "06:00 is too early");
  Check("Hour_Night",  !MrEntryHourAllowed(3),   "03:00 is outside");
  Check("Hour_Invalid",!MrEntryHourAllowed(24),  "24 is not an hour");
  Check("Hour_Neg",    !MrEntryHourAllowed(-1),  "-1 is not an hour");

  //================================================================
  // 12. Holding limit.
  //================================================================
  Check("Hold_Under",   !MrHoldExpired(23, 24), "23 bars held is not expired");
  Check("Hold_Exact",    MrHoldExpired(24, 24), "24 bars held expires");
  Check("Hold_Over",     MrHoldExpired(30, 24), "beyond the limit expires");
  Check("Hold_Zero",    !MrHoldExpired(0,  24), "a fresh position is not expired");
  Check("Hold_NoLimit", !MrHoldExpired(999, 0), "a zero limit means no time exit");

  //================================================================
  // 13. Break-even win rate at this geometry. The reward floats with
  //     the distance to the mean, so this is the figure AT the entry
  //     threshold - the point at which the trade is least favourable.
  //================================================================
  Check("BE_AtThreshold", Near(LabBreakEvenWinPct(1.0), 50.0),
        "a 1:1 fade at the threshold needs 50%");
  Check("BE_Realised", LabBreakEvenWinPct(MrRealisedRR(L)) < 50.0,
        "the realised RR above 1.0 lowers the bar below 50%");

  Print("[QA] ===== RESULT: ", g_pass, " passed, ", g_fail, " failed =====");
}

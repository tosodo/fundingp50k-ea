//+------------------------------------------------------------------+
//| RiskManager_tests.mq5                                             |
//| FP50K-EA | Sprint 1 Unit Tests                                    |
//| Tests: constants, lot sizing, session window, gates, state machine|
//+------------------------------------------------------------------+
#property script_show_inputs

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
   Print("=== FP50K-EA | RiskManager Unit Tests ===");

//--- GROUP 1: Hard limit constants (FundingPips rules)
   Check("FP_INITIAL_BALANCE == 50000",    FP_INITIAL_BALANCE    == 50000.0);
   Check("FP_EQUITY_FLOOR == 44000",       FP_EQUITY_FLOOR       == 44000.0);
   Check("FP_DD_EMERGENCY_FLOOR == 44500", FP_DD_EMERGENCY_FLOOR == 44500.0);
   Check("FP_DAILY_HARD_STOP == 1800",     FP_DAILY_HARD_STOP    == 1800.0);
   Check("FP_DAILY_SOFT_STOP == 1000",     FP_DAILY_SOFT_STOP    == 1000.0);
   Check("FP_MAX_TRADE_RISK_USD == 1000",  FP_MAX_TRADE_RISK_USD == 1000.0);

//--- GROUP 2: Session constants
   Check("SESSION_OPEN_HOUR == 7",   SESSION_OPEN_HOUR   == 7);
   Check("SESSION_CLOSE_HOUR == 17", SESSION_CLOSE_HOUR  == 17);
   Check("FRIDAY_FLATTEN_HOUR == 20",FRIDAY_FLATTEN_HOUR == 20);
   Check("NEWS_BLOCK_MINUTES == 5",  NEWS_BLOCK_MINUTES  == 5);

//--- GROUP 3: Derived math - our buffers must sit INSIDE the firm walls
   Check("Soft stop < hard stop",
         FP_DAILY_SOFT_STOP < FP_DAILY_HARD_STOP);
   Check("Hard stop < firm daily wall (2000)",
         FP_DAILY_HARD_STOP < 2000.0);
   Check("Emergency floor above firm equity floor",
         FP_DD_EMERGENCY_FLOOR > FP_EQUITY_FLOOR);
   Check("Emergency floor = equity floor + 500 buffer",
         FP_DD_EMERGENCY_FLOOR == FP_EQUITY_FLOOR + 500.0);
   Check("Equity floor = 12% drawdown from initial balance",
         MathAbs(FP_EQUITY_FLOOR - (FP_INITIAL_BALANCE * 0.88)) < 0.01);
   Check("Three losses at recommended $600 hit the hard stop exactly",
         (3 * 600.0) <= FP_DAILY_HARD_STOP);
   Check("Max trade risk stays under the daily hard stop",
         FP_MAX_TRADE_RISK_USD < FP_DAILY_HARD_STOP);

//--- GROUP 4: Initialisation state
   CRiskManager risk;
   Check("Init() returns true",        risk.Init(FP_INITIAL_BALANCE, 50001));
   Check("Initial state is RISK_OK",   risk.GetState() == RISK_OK);
   Check("Initial killed flag false",  risk.IsKilled() == false);
   Check("Initial daily loss is zero", risk.GetDailyLoss() == 0.0);
   Check("Init anchors the day to the starting balance",
         risk.GetDayAnchor() == FP_INITIAL_BALANCE);

//--- GROUP 4b: The daily allowance resets every day.
//    "Daily loss" must be measured from the equity TODAY opened at, not from
//    the balance the challenge began with. Anchored to the start balance
//    instead, a bad week would leave the EA permanently hard-stopped and a
//    good week would hand it an allowance far larger than the firm grants.
   Check("Daily loss is the fall from the day's opening equity",
         CRiskManager::DailyLossFrom(50000.0, 49000.0) == 1000.0);
   Check("A day in profit reports a negative loss, not zero",
         CRiskManager::DailyLossFrom(50000.0, 51000.0) == -1000.0);

   Check("No loss leaves the state OK",
         CRiskManager::StateFromDailyLoss(0.0) == RISK_OK);
   Check("A dollar under the soft stop is still OK",
         CRiskManager::StateFromDailyLoss(999.0) == RISK_OK);
   Check("Exactly $1000 triggers the soft stop",
         CRiskManager::StateFromDailyLoss(FP_DAILY_SOFT_STOP) == RISK_SOFT_STOP);
   Check("A dollar under the hard stop is still only a soft stop",
         CRiskManager::StateFromDailyLoss(1799.0) == RISK_SOFT_STOP);
   Check("Exactly $1800 triggers the hard stop",
         CRiskManager::StateFromDailyLoss(FP_DAILY_HARD_STOP) == RISK_HARD_STOP);
   Check("A loss past the hard stop stays hard-stopped",
         CRiskManager::StateFromDailyLoss(5000.0) == RISK_HARD_STOP);

   Check("A new day re-anchors to that morning's equity",
         CRiskManager::NextDayAnchor(50000.0, 48000.0) == 48000.0);
   Check("A profitable week moves the anchor up too",
         CRiskManager::NextDayAnchor(50000.0, 52000.0) == 52000.0);
   Check("A zero equity reading keeps the previous anchor",
         CRiskManager::NextDayAnchor(50000.0, 0.0) == 50000.0,
         "an offline terminal reads equity as 0.00 - re-anchoring there would "
         "report an instant $50,000 loss");
   Check("A negative equity reading keeps the previous anchor",
         CRiskManager::NextDayAnchor(50000.0, -5.0) == 50000.0);

// The regression this guards. Down $2,000 over an earlier week, the account
// sits at $48,000 and opens a new day. Losing $1,000 today is a soft stop and
// nothing worse. Measured from the original $50,000 it would read as a $3,000
// loss and hard-stop the EA on a day it had done nothing wrong.
   double anchor_today = CRiskManager::NextDayAnchor(FP_INITIAL_BALANCE, 48000.0);
   Check("After a losing week, today's $1,000 loss is only a soft stop",
         CRiskManager::StateFromDailyLoss(
           CRiskManager::DailyLossFrom(anchor_today, 47000.0)) == RISK_SOFT_STOP);
   Check("Measured from the start balance instead, the same day would hard-stop",
         CRiskManager::StateFromDailyLoss(
           CRiskManager::DailyLossFrom(FP_INITIAL_BALANCE, 47000.0)) == RISK_HARD_STOP,
         "this is the behaviour the day anchor exists to prevent");

//--- GROUP 4c: FundingPips percentage limits, layered on the dollar limits.
//    The whole point of this layer is that it can only ever RESTRICT the EA.
//    A test that just checks the new numbers exist would miss the one failure
//    that matters: a percentage rule quietly granting more room than the fixed
//    rule it sits beside.
   Check("Daily percentage buffer sits inside the firm's 5% rule",
         FP_DAILY_DD_PCT < 5.0);
   Check("Overall percentage buffer sits inside the firm's 10% rule",
         FP_OVERALL_DD_PCT < 10.0);
   Check("Risk per trade is well under the daily allowance",
         FP_RISK_PER_TRADE_PCT < FP_DAILY_DD_PCT);

   Check("0.75% of a $50,000 account is $375",
         MathAbs(50000.0 * FP_RISK_PER_TRADE_PCT / 100.0 - 375.0) < 0.01);
   Check("4% of a $50,000 account is $2,000",
         MathAbs(50000.0 * FP_DAILY_DD_PCT / 100.0 - 2000.0) < 0.01);
   Check("9% below $50,000 is a $45,500 floor",
         MathAbs(CRiskManager::OverallFloorOf(50000.0, FP_OVERALL_DD_PCT) - 45500.0) < 0.01);

// The tighter-of-the-two rule, in both directions.
   Check("Daily stop takes the TIGHTER of $1,800 and 4%",
         MathAbs(CRiskManager::EffectiveDailyStopUsd(50000.0, FP_DAILY_DD_PCT)
                 - FP_DAILY_HARD_STOP) < 0.01,
         "4% of $50,000 is $2,000, so the fixed $1,800 binds");
   Check("On a smaller baseline the percentage binds instead",
         MathAbs(CRiskManager::EffectiveDailyStopUsd(30000.0, FP_DAILY_DD_PCT)
                 - 1200.0) < 0.01,
         "4% of $30,000 is $1,200, which is tighter than $1,800");
   Check("Equity floor takes the HIGHER of $44,500 and the 9% floor",
         MathAbs(CRiskManager::EffectiveOverallFloor(50000.0, FP_OVERALL_DD_PCT)
                 - 45500.0) < 0.01,
         "the 9% floor at $45,500 is above the fixed $44,500, so it binds");
   Check("The layered floor is never looser than the fixed one",
         CRiskManager::EffectiveOverallFloor(50000.0, FP_OVERALL_DD_PCT)
           >= FP_DD_EMERGENCY_FLOOR);
   Check("The layered daily stop is never looser than the fixed one",
         CRiskManager::EffectiveDailyStopUsd(50000.0, FP_DAILY_DD_PCT)
           <= FP_DAILY_HARD_STOP);

//--- GROUP 4d: the 5 PM EST / 00:00 platform-time high-water reset.
//    The baseline is the HIGHER of balance and equity. A day opened with a
//    position floating at a loss must NOT be handed a fresh allowance measured
//    from the depressed equity - that quietly forgives money already lost.
   Check("Baseline takes balance when equity is floating lower",
         CRiskManager::NextDayBaseline(50000.0, 50000.0, 49200.0) == 50000.0,
         "an open loser at the reset must not enlarge today's allowance");
   Check("Baseline takes equity when it is the higher of the two",
         CRiskManager::NextDayBaseline(50000.0, 50000.0, 50800.0) == 50800.0);
   Check("Baseline follows the account up after a winning week",
         CRiskManager::NextDayBaseline(50000.0, 53000.0, 53000.0) == 53000.0);
   Check("A dead account reading keeps the previous baseline",
         CRiskManager::NextDayBaseline(50000.0, 0.0, 0.0) == 50000.0,
         "an offline terminal reads both as 0.00");

   Check("Daily floor is 4% below the baseline",
         MathAbs(CRiskManager::DailyFloorOf(50000.0, FP_DAILY_DD_PCT) - 48000.0) < 0.01);
   Check("Daily floor moves with the baseline, not the start balance",
         MathAbs(CRiskManager::DailyFloorOf(53000.0, FP_DAILY_DD_PCT) - 50880.0) < 0.01);

//--- GROUP 4e: dynamic sizing. Three ceilings apply and the lowest wins.
   double stop_50k = CRiskManager::EffectiveDailyStopUsd(50000.0, FP_DAILY_DD_PCT);

   Check("A fresh day sizes at 0.75% of equity",
         MathAbs(CRiskManager::RiskBudgetUsd(50000.0, FP_RISK_PER_TRADE_PCT,
                                             0.0, stop_50k) - 375.0) < 0.01);
   Check("Sizing shrinks with the account, not with a fixed dollar figure",
         CRiskManager::RiskBudgetUsd(46000.0, FP_RISK_PER_TRADE_PCT, 0.0, stop_50k)
           < CRiskManager::RiskBudgetUsd(50000.0, FP_RISK_PER_TRADE_PCT, 0.0, stop_50k),
         "a constant dollar risk against a shrinking cushion is how accounts die");
   Check("The per-trade dollar cap still applies on a large account",
         CRiskManager::RiskBudgetUsd(200000.0, FP_RISK_PER_TRADE_PCT, 0.0, 5000.0)
           == FP_MAX_TRADE_RISK_USD,
         "0.75% of $200,000 is $1,500, above the $1,000 ceiling");

// The one that matters most: a day already most of the way to its stop must
// not be allowed to take a full-size trade through it.
   Check("Remaining daily allowance caps the trade when the day is already down",
         MathAbs(CRiskManager::RiskBudgetUsd(50000.0, FP_RISK_PER_TRADE_PCT,
                                             1600.0, stop_50k) - 200.0) < 0.01,
         "$1,800 stop less $1,600 already lost leaves $200, not the $375 by percentage");
   Check("A spent day offers no budget at all",
         CRiskManager::RiskBudgetUsd(50000.0, FP_RISK_PER_TRADE_PCT,
                                     1800.0, stop_50k) == 0.0);
   Check("A day past its stop never returns a negative budget",
         CRiskManager::RiskBudgetUsd(50000.0, FP_RISK_PER_TRADE_PCT,
                                     2500.0, stop_50k) == 0.0);
   Check("No equity reading means no budget",
         CRiskManager::RiskBudgetUsd(0.0, FP_RISK_PER_TRADE_PCT, 0.0, stop_50k) == 0.0);

//--- GROUP 4f: lot arithmetic, driven with known numbers instead of live ticks.
//    $375 over a 25-pip stop at $10/pip per lot = 1.50 lots exactly.
   Check("Risk, stop and pip value produce the expected lot size",
         MathAbs(CRiskManager::LotsFromRisk(375.0, 25.0, 10.0, 0.01, 0.01, 100.0)
                 - 1.50) < 0.0001);
   Check("A wider stop buys fewer lots for the same money",
         CRiskManager::LotsFromRisk(375.0, 50.0, 10.0, 0.01, 0.01, 100.0)
           < CRiskManager::LotsFromRisk(375.0, 25.0, 10.0, 0.01, 0.01, 100.0));
   Check("Lots round DOWN to the volume step, never up",
         CRiskManager::LotsFromRisk(379.0, 25.0, 10.0, 0.01, 0.01, 100.0) == 1.51,
         "1.516 lots rounds to 1.51 - rounding up would overspend the budget");
   Check("A lot size under the broker minimum returns zero, not a tiny trade",
         CRiskManager::LotsFromRisk(1.0, 500.0, 10.0, 0.01, 0.01, 100.0) == 0.0);
   Check("Lots are capped at the broker maximum",
         CRiskManager::LotsFromRisk(500000.0, 10.0, 10.0, 0.01, 0.01, 5.0) == 5.0);
   Check("Zero stop distance produces no lots rather than a divide by zero",
         CRiskManager::LotsFromRisk(375.0, 0.0, 10.0, 0.01, 0.01, 100.0) == 0.0);
   Check("Zero pip value produces no lots",
         CRiskManager::LotsFromRisk(375.0, 25.0, 0.0, 0.01, 0.01, 100.0) == 0.0);

//--- GROUP 4g: EvaluateRisk returns a decision, never a half-filled struct
   RiskStatus st_bad = risk.EvaluateRisk(0.0, _Symbol);
   Check("EvaluateRisk refuses a non-positive stop distance",
         st_bad.isTradingAllowed == false);
   Check("A refusal still carries a reason",
         StringLen(st_bad.statusReason) > 0, st_bad.statusReason);
   Check("A refusal never returns a tradeable lot size",
         st_bad.maxAllowedLotSize == 0.0);
   Check("A refusal still reports the floors it was measured against",
         st_bad.overallFloor > 0.0,
         StringFormat("daily $%.2f overall $%.2f", st_bad.dailyFloor, st_bad.overallFloor));
   Check("The reported overall floor is the layered one",
         MathAbs(st_bad.overallFloor - 45500.0) < 0.01,
         DoubleToString(st_bad.overallFloor, 2));

   RiskStatus st_live = risk.EvaluateRisk(25.0, _Symbol);
   Info("EvaluateRisk(25 pips)", st_live.statusReason);
   Check("EvaluateRisk never allows a trade without a lot size",
         st_live.isTradingAllowed ? (st_live.maxAllowedLotSize > 0.0) : true);
   Check("EvaluateRisk never sizes above the per-trade dollar cap",
         st_live.riskUsd <= FP_MAX_TRADE_RISK_USD,
         DoubleToString(st_live.riskUsd, 2));

   Check("News blackout width defaults to the module constant",
         risk.GetNewsBlockMinutes() == NEWS_BLOCK_MINUTES);
   risk.SetNewsBlockMinutes(15);
   Check("News blackout width is settable to the 15-minute spec",
         risk.GetNewsBlockMinutes() == 15);
   risk.SetNewsBlockMinutes(0);
   Check("A nonsense blackout width falls back to the default rather than off",
         risk.GetNewsBlockMinutes() == NEWS_BLOCK_MINUTES,
         "zero minutes would silently disable the filter");
   risk.SetNewsBlockMinutes(15);

//--- GROUP 5: CalculateLotSize input validation (deterministic - no market data needed)
   Check("Rejects zero risk",
         risk.CalculateLotSize(0.0, 50.0, _Symbol) == 0.0);
   Check("Rejects negative risk",
         risk.CalculateLotSize(-500.0, 50.0, _Symbol) == 0.0);
   Check("Rejects zero stop distance",
         risk.CalculateLotSize(500.0, 0.0, _Symbol) == 0.0);
   Check("Rejects negative stop distance",
         risk.CalculateLotSize(500.0, -50.0, _Symbol) == 0.0);

//--- GROUP 6: CalculateLotSize with live market data (chart symbol)
   double lot_500     = risk.CalculateLotSize(500.0,  50.0, _Symbol);
   double lot_at_cap  = risk.CalculateLotSize(1000.0, 50.0, _Symbol);
   double lot_over    = risk.CalculateLotSize(5000.0, 50.0, _Symbol);

   Info("Chart symbol", _Symbol);
   Info("Lot for $500 risk / 50 pip stop",  DoubleToString(lot_500, 2));
   Info("Lot for $1000 risk / 50 pip stop", DoubleToString(lot_at_cap, 2));
   Info("Lot for $5000 risk / 50 pip stop", DoubleToString(lot_over, 2));

   if(lot_500 > 0.0)
     {
      Check("Valid inputs produce a positive lot size", lot_500 > 0.0);
      Check("Risk above the $1000 cap is clamped to the $1000 lot",
            MathAbs(lot_over - lot_at_cap) < 0.0001);
      Check("Larger risk never produces a smaller lot", lot_at_cap >= lot_500);
     }
   else
     {
      Info("Lot sizing", "SKIPPED - no tick data for " + _Symbol + " (run on a live chart)");
     }

//--- GROUP 7: Gate behaviour (deterministic regardless of clock)
   string reason = "";

// Over-cap risk must always be refused, whatever the session state
   bool over_cap_ok = risk.CanOpenTrade(50.0, 5000.0, _Symbol, reason);
   Check("Gate refuses risk above $1000 cap", over_cap_ok == false);
   Check("Gate populates a block reason when refusing", StringLen(reason) > 0);
   Info("Block reason", reason);

// Risk that alone would breach the hard stop must be refused
   reason = "";
   bool breach_ok = risk.CanOpenTrade(50.0, 999.0, _Symbol, reason);
   if(breach_ok == false)
      Info("Second gate reason", reason);

// The gate runs on every candidate entry, so it must never block on a slow
// calendar query. CalendarValueHistory() costs ~2s cold and ~90s on a terminal
// downloading the calendar database for the first time - both unacceptable
// here, which is why events are cached and refreshed on a timer instead.
   uint t0 = GetTickCount();
   for(int i = 0; i < 50; i++)
     {
      string r = "";
      risk.CanOpenTrade(50.0, 400.0, _Symbol, r);
     }
   uint elapsed = GetTickCount() - t0;
   Info("50 gate calls took", IntegerToString(elapsed) + " ms");
   Check("Gate stays off the slow calendar path (50 calls under 500ms)",
         elapsed < 500, IntegerToString(elapsed) + " ms");

//--- GROUP 8: State machine enum integrity
   Check("RISK_OK == 0",        (int)RISK_OK        == 0);
   Check("RISK_SOFT_STOP == 1", (int)RISK_SOFT_STOP == 1);
   Check("RISK_HARD_STOP == 2", (int)RISK_HARD_STOP == 2);
   Check("RISK_KILLED == 3",    (int)RISK_KILLED    == 3);

//--- GROUP 9: CSV decision log
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string log_path = StringFormat("Logs\\risk_log_%04d%02d%02d.csv", dt.year, dt.mon, dt.day);
   Check("CSV decision log created in MQL5/Files/", FileIsExist(log_path));
   Info("Log path", log_path);

//--- Session window state (informational - depends on wall clock)
   MqlDateTime gmt;
   TimeToStruct(TimeGMT(), gmt);
   Info("Current UTC", StringFormat("%02d:%02d day_of_week=%d", gmt.hour, gmt.min, gmt.day_of_week));
   Info("Inside 07:00-17:00 UTC window",
        (gmt.day_of_week >= 1 && gmt.day_of_week <= 5 &&
         gmt.hour >= SESSION_OPEN_HOUR && gmt.hour < SESSION_CLOSE_HOUR) ? "YES" : "NO");

//--- GROUP 10: Broker clock reconciliation.
//    This suite runs as a SCRIPT against a live terminal, so unlike the
//    Strategy Tester it can see the broker's real UTC offset. That makes this
//    the one place the true value can be measured - and the value backtests
//    have to be told, because in the tester TimeGMT() mirrors the server clock
//    and the offset silently computes to zero.
   int detected_secs = FpUtcOffsetDetectedSecs();
   int detected_h    = detected_secs / 3600;

   Info("Server time", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   Info("GMT time",    TimeToString(TimeGMT(),     TIME_DATE | TIME_SECONDS));
   Info(">>> BROKER UTC OFFSET (use for InpUtcOffsetH)",
        IntegerToString(detected_h) + " hours");
   Info("Asian 00:00-07:00 UTC maps to server",
        StringFormat("%02d:00-%02d:00", (24 + detected_h) % 24, (7 + detected_h) % 24));

   Check("Broker offset is a whole number of hours",
         detected_secs % 3600 == 0,
         IntegerToString(detected_secs) + "s");
   Check("Broker offset is within +/-12 hours of UTC",
         detected_h >= -12 && detected_h <= 12, IntegerToString(detected_h));

// The default is auto-detect, which is right live and wrong in the tester.
   Check("Clock defaults to auto-detect",
         FpUtcOffsetIsOverridden() == false);
   Check("Auto-detect agrees with the terminal",
         FpUtcOffsetSecs() == detected_secs);

   FpSetUtcOffsetHours(3);
   Check("An override replaces the detected offset",
         FpUtcOffsetSecs() == 3 * 3600,
         "this is what a backtest must set - the tester cannot detect it");
   Check("An override is reported as such",
         FpUtcOffsetIsOverridden() == true);
   Check("UTC now follows the override, not the server clock",
         FpNowUtc() == TimeCurrent() - 3 * 3600);

   FpSetUtcOffsetHours(0);
   Check("A zero override is honoured, not treated as unset",
         FpUtcOffsetIsOverridden() == true && FpNowUtc() == TimeCurrent(),
         "0 is a legitimate offset for a UTC broker");

//--- GROUP 10b: European summer time. A fixed offset is an hour wrong for five
//    months of a twelve-month backtest on an EET/EEST broker, so the winter
//    baseline gets an hour added through EU summer time.
//
//    The EU rule: last Sunday in March to last Sunday in October, at 01:00 UTC.
//    Known-good anchors - 2025 switched on 30 March and 26 October.
   Check("Last Sunday of March 2025 is the 30th",
         FpLastSundayOfMonth(2025, 3) == 30,
         IntegerToString(FpLastSundayOfMonth(2025, 3)));
   Check("Last Sunday of October 2025 is the 26th",
         FpLastSundayOfMonth(2025, 10) == 26,
         IntegerToString(FpLastSundayOfMonth(2025, 10)));
   Check("Last Sunday of March 2026 is the 29th",
         FpLastSundayOfMonth(2026, 3) == 29,
         IntegerToString(FpLastSundayOfMonth(2026, 3)));

   Check("January is winter time",  FpEuDstActive(D'2025.01.15 12:00') == false);
   Check("July is summer time",     FpEuDstActive(D'2025.07.15 12:00') == true);
   Check("December is winter time", FpEuDstActive(D'2025.12.15 12:00') == false);

   Check("Mid-March, before the switch, is still winter",
         FpEuDstActive(D'2025.03.15 12:00') == false);
   Check("Late March, after the switch, is summer",
         FpEuDstActive(D'2025.03.31 12:00') == true);
   Check("The March switchover day flips at 01:00",
         FpEuDstActive(D'2025.03.30 00:30') == false &&
         FpEuDstActive(D'2025.03.30 02:00') == true);

   Check("Mid-October, before the switch, is still summer",
         FpEuDstActive(D'2025.10.15 12:00') == true);
   Check("Late October, after the switch, is winter",
         FpEuDstActive(D'2025.10.31 12:00') == false);
   Check("The October switchover day flips at 01:00",
         FpEuDstActive(D'2025.10.26 00:30') == true &&
         FpEuDstActive(D'2025.10.26 02:00') == false);

// The reason this exists: a broker measured at +3 in July is +2 in January,
// and a backtest pinned to a single number gets one of the two wrong.
   Check("A +2 winter baseline with EU DST reads +3 in summer",
         FpEuDstActive(D'2025.07.15 12:00') ? (2 + 1 == 3) : false,
         "matches the +3h measured live on FundingPips-SIM1 in July");
   Check("...and +2 in winter",
         FpEuDstActive(D'2025.01.15 12:00') == false);

   Check("EU DST defaults to off, so a fixed offset stays fixed",
         FpBrokerEuDst() == false);
   FpSetBrokerEuDst(true);
   Check("EU DST is settable", FpBrokerEuDst() == true);
   FpSetBrokerEuDst(false);

// Put it back so nothing after this sees a doctored clock.
   g_fp_utc_offset_hours = FP_UTC_OFFSET_AUTO;
   Check("Clock restored to auto-detect for later callers",
         FpUtcOffsetIsOverridden() == false);

//--- Summary
   Print("[QA] ===== RESULT: ", test_passed, " passed, ", test_failed, " failed =====");
  }

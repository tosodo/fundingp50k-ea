//+------------------------------------------------------------------+
//| BacktestValidator_tests.mq5                                       |
//| FP50K-EA | Sprint 4 Unit Tests                                    |
//| Tests: equity curve, daily walls, floor breach, phase targets     |
//+------------------------------------------------------------------+
//
// The validator is driven entirely through Feed(time, equity, balance), so a
// whole challenge can be simulated here from a hand-written equity curve -
// no account, no broker, no Strategy Tester. That is the point of the design:
// the arithmetic that decides "this run failed the challenge" is checked
// against known numbers rather than trusted because it looked right.

#property script_show_inputs

#include <fp50k\BacktestValidator.mqh>

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

void Info(string label, string value)
  {
   Print("[QA] INFO | ", label, " | ", value);
  }

//--- A fixed calendar so every timestamp in this file is readable. Midnight of
//    any date is an exact multiple of 86400, so day N starts exactly where
//    DayIndexOf() says it does.
datetime D(int day, int hour)
  {
   return D'2024.01.01 00:00:00' + day * 86400 + hour * 3600;
  }

void OnStart()
  {
   Print("=== FP50K-EA | BacktestValidator Unit Tests ===");

//--- GROUP 1: Thresholds match the briefing's acceptance criteria
   Check("Firm daily wall is $2000",       BT_FIRM_DAILY_WALL   == 2000.0);
   Check("Firm equity floor is $44000",    BT_FIRM_EQUITY_FLOOR == 44000.0);
   Check("Phase 1 target is +10%",         BT_PHASE1_TARGET_PCT == 10.0);
   Check("Phase 2 target is +6%",          BT_PHASE2_TARGET_PCT == 6.0);
   Check("Minimum sample is 300 trades",   BT_MIN_TRADES        == 300);
   Check("Max acceptable drawdown is 8%",  BT_MAX_DD_PCT        == 8.0);
   Check("Minimum win rate is 45%",        BT_MIN_WIN_RATE_PCT  == 45.0);
   Check("Phase 1 allowed 30 sessions",    BT_PHASE1_MAX_SESSIONS == 30);

// Our internal stops must sit strictly inside the firm's wall, or the whole
// buffer design is decorative.
   Check("Our hard stop is inside the firm's daily wall",
         FP_DAILY_HARD_STOP < BT_FIRM_DAILY_WALL);
   Check("Our emergency floor is above the firm's equity floor",
         FP_DD_EMERGENCY_FLOOR > BT_FIRM_EQUITY_FLOOR);
   Check("The 8% drawdown ceiling leaves room inside the 12% wall",
         BT_MAX_DD_PCT < 12.0);

//--- GROUP 2: Pure helpers
   Check("DayIndexOf: midnight starts a new day",
         CBacktestValidator::DayIndexOf(D(1, 0)) ==
         CBacktestValidator::DayIndexOf(D(0, 0)) + 1);
   Check("DayIndexOf: 23:00 is still the same day",
         CBacktestValidator::DayIndexOf(D(0, 23)) ==
         CBacktestValidator::DayIndexOf(D(0, 0)));

   Check("DrawdownPct: at the peak is zero",
         CBacktestValidator::DrawdownPct(50000, 50000) == 0.0);
   Check("DrawdownPct: above the peak is still zero, never negative",
         CBacktestValidator::DrawdownPct(50000, 51000) == 0.0);
   Check("DrawdownPct: 10% below a 50k peak reads 10%",
         MathAbs(CBacktestValidator::DrawdownPct(50000, 45000) - 10.0) < 0.0001);
   Check("DrawdownPct: a zero peak cannot divide by zero",
         CBacktestValidator::DrawdownPct(0, 45000) == 0.0);

   Check("IsNearMiss: $1440 is exactly 80% of the hard stop",
         CBacktestValidator::IsNearMiss(1440.0));
   Check("IsNearMiss: $1439 is below the near-miss band",
         CBacktestValidator::IsNearMiss(1439.0) == false);
   Check("IsNearMiss: $1799 is still a near miss",
         CBacktestValidator::IsNearMiss(1799.0));
   Check("IsNearMiss: $1800 is a real hit, not a near miss",
         CBacktestValidator::IsNearMiss(1800.0) == false,
         "a day that trips the stop is counted as a hit instead");

   Check("WinRatePct: 45 of 100 reads 45%",
         MathAbs(CBacktestValidator::WinRatePct(45, 100) - 45.0) < 0.0001);
   Check("WinRatePct: no trades cannot divide by zero",
         CBacktestValidator::WinRatePct(0, 0) == 0.0);

   Check("ProfitFactorOf: 2000 won against 1000 lost is 2.0",
         MathAbs(CBacktestValidator::ProfitFactorOf(2000, 1000) - 2.0) < 0.0001);
   Check("ProfitFactorOf: no losses returns the 999 sentinel",
         CBacktestValidator::ProfitFactorOf(2000, 0) == 999.0);
   Check("ProfitFactorOf: no trades at all returns zero",
         CBacktestValidator::ProfitFactorOf(0, 0) == 0.0);

   Check("TargetEquity: +10% of 50k is 55k",
         MathAbs(CBacktestValidator::TargetEquity(50000, 10.0) - 55000.0) < 0.0001);
   Check("TargetEquity: +6% of 50k is 53k",
         MathAbs(CBacktestValidator::TargetEquity(50000, 6.0) - 53000.0) < 0.0001);

//--- GROUP 3: Init guards
   CBacktestValidator bad;
   Check("Init refuses a zero starting balance",  bad.Init(0.0) == false);
   Check("Init refuses a negative balance",       bad.Init(-500.0) == false);

   CBacktestValidator good;
   Check("Init accepts a $50,000 start",          good.Init(50000.0));
   Check("A fresh validator has no drawdown",     good.MaxDDPct() == 0.0);
   Check("A fresh validator has breached nothing", good.FloorBreached() == false);

// Feed must ignore a zero-equity reading. Offline, AccountInfoDouble() returns
// 0.00, and treating that as real equity would report an instant $50,000 loss.
   good.Feed(D(0, 1), 0.0, 0.0);
   Check("Feed ignores a zero equity reading",
         good.MaxDDPct() == 0.0 && good.FloorBreached() == false,
         "an offline terminal reads equity as 0.00");

//--- GROUP 4: Equity curve tracking
   CBacktestValidator curve;
   curve.Init(50000.0);
   curve.Feed(D(0, 1), 50000.0, 50000.0);
   curve.Feed(D(0, 2), 51000.0, 51000.0);   // new peak
   curve.Feed(D(0, 3), 49980.0, 49980.0);   // 1020 below the 51000 peak = 2%
   curve.Feed(D(0, 4), 50500.0, 50500.0);   // recovers, peak unchanged

   Check("Max drawdown measures from the running peak, not the start",
         MathAbs(curve.MaxDDPct() - 2.0) < 0.0001,
         DoubleToString(curve.MaxDDPct(), 4) + "%");
   Check("Lowest equity is remembered",
         MathAbs(curve.MinEquity() - 49980.0) < 0.0001);
   Check("A recovery does not erase the recorded drawdown",
         curve.MaxDDPct() > 0.0);

//--- GROUP 5: The daily wall. One day down $2,100 must be caught.
   CBacktestValidator wall;
   wall.Init(50000.0);
   wall.Feed(D(0, 1),  50000.0, 50000.0);
   wall.Feed(D(0, 10), 47900.0, 47900.0);   // -$2,100 on the day
   wall.Feed(D(0, 16), 49000.0, 49000.0);   // partial recovery, same day
   wall.Feed(D(1, 1),  49000.0, 49000.0);   // next day - closes day 0

   Check("A $2,100 day breaches the firm's $2,000 wall",
         wall.WallHits() == 1, "wall hits: " + IntegerToString(wall.WallHits()));
   Check("The same day also trips our own $1,800 hard stop",
         wall.HardStopHits() == 1);
   Check("The worst daily loss is the intraday low, not the close",
         MathAbs(wall.WorstDailyLoss() - 2100.0) < 0.0001,
         "recovering by the end of the day does not undo the breach");
   Check("A breached day fails rule compliance",
         wall.CompliancePassed() == false);
   Check("A non-compliant run scores zero for the optimiser",
         wall.OptimisationScore() == 0.0);

//--- GROUP 6: Near misses are counted separately from hits
   CBacktestValidator near;
   near.Init(50000.0);
   near.Feed(D(0, 1), 50000.0, 50000.0);
   near.Feed(D(0, 9), 48500.0, 48500.0);    // -$1,500: 83% of the hard stop
   near.Feed(D(1, 1), 48500.0, 48500.0);    // closes day 0

   Check("A $1,500 day is recorded as a near miss",
         near.NearMisses() == 1);
   Check("A near miss is not counted as a hard-stop hit",
         near.HardStopHits() == 0);
   Check("A near miss is not a wall breach",
         near.WallHits() == 0);
   Check("A near miss still passes rule compliance",
         near.CompliancePassed(),
         "it is a warning about the strategy, not a challenge failure");
   Check("A $1,500 day also passes the $1,000 soft stop",
         near.SoftStopHits() == 1);

//--- GROUP 7: The daily allowance resets each day.
//    Three consecutive $1,500 losing days are three separate legal days, not
//    one $4,500 breach. Getting this wrong in either direction is serious:
//    too strict and the EA stops trading a challenge it was passing, too
//    loose and it trades through the wall that ends it.
   CBacktestValidator fresh;
   fresh.Init(50000.0);
   fresh.Feed(D(0, 1), 50000.0, 50000.0);
   fresh.Feed(D(0, 9), 48500.0, 48500.0);   // day 0: -1500 from 50000
   fresh.Feed(D(1, 1), 48500.0, 48500.0);   // day 1 opens here
   fresh.Feed(D(1, 9), 47000.0, 47000.0);   // day 1: -1500 from 48500
   fresh.Feed(D(2, 1), 47000.0, 47000.0);   // day 2 opens here
   fresh.Feed(D(2, 9), 45500.0, 45500.0);   // day 2: -1500 from 47000
   fresh.Finalise(0);

   Check("Three $1,500 days are three days, not one $4,500 breach",
         fresh.WallHits() == 0 && fresh.HardStopHits() == 0,
         "each day is measured from its own opening equity");
   Check("Each of the three days is logged as a near miss",
         fresh.NearMisses() == 3, IntegerToString(fresh.NearMisses()));
   Check("The worst single day is $1,500, not the cumulative loss",
         MathAbs(fresh.WorstDailyLoss() - 1500.0) < 0.0001);
   Check("Three days were counted",
         fresh.DaysTracked() == 3, IntegerToString(fresh.DaysTracked()));
   Check("The cumulative 9% slide still shows in the drawdown",
         fresh.MaxDDPct() > 8.0,
         DoubleToString(fresh.MaxDDPct(), 2) + "% - this is what fails the run");

//--- GROUP 8: The equity floor. One breach ends the challenge.
   CBacktestValidator floor;
   floor.Init(50000.0);
   floor.Feed(D(0, 1), 50000.0, 50000.0);
   floor.Feed(D(0, 8), 44001.0, 44001.0);   // one dollar above the floor
   Check("A dollar above the floor is not a breach",
         floor.FloorBreached() == false);

   floor.Feed(D(0, 9), 43999.0, 43999.0);   // one dollar below
   Check("A dollar below the floor is a breach",
         floor.FloorBreached());
   Check("A floor breach fails rule compliance",
         floor.CompliancePassed() == false);
   Check("A floor breach fails acceptance",
         floor.CriteriaPassed() == false);
   Check("A floor breach fails both phases",
         floor.Phase1Passed() == false && floor.Phase2Passed() == false);

//--- GROUP 9: Phase targets
   CBacktestValidator phase;
   phase.Init(50000.0);
   phase.Feed(D(0, 1), 50000.0, 50000.0);
   Check("Neither target is reached at the start",
         phase.Phase1Reached() == false && phase.Phase2Reached() == false);

   phase.Feed(D(0, 12), 53000.0, 53000.0);  // exactly +6%
   Check("Exactly +6% reaches the Phase 2 target",
         phase.Phase2Reached());
   Check("+6% does not yet reach the Phase 1 target",
         phase.Phase1Reached() == false);
   Check("Phase 2 was reached on session 1",
         phase.Phase2Sessions() == 1, IntegerToString(phase.Phase2Sessions()));

   phase.Feed(D(1, 12), 55000.0, 55000.0);  // exactly +10%, next day
   Check("Exactly +10% reaches the Phase 1 target",
         phase.Phase1Reached());
   Check("Phase 1 was reached on session 2",
         phase.Phase1Sessions() == 2, IntegerToString(phase.Phase1Sessions()));
   Check("A clean run passes both phases",
         phase.Phase1Passed() && phase.Phase2Passed());
   Check("Session 2 is well inside the 30-session budget",
         phase.Phase1Sessions() <= BT_PHASE1_MAX_SESSIONS);

//--- A run that never reaches the target fails Phase 1 even with no breach
   CBacktestValidator flat;
   flat.Init(50000.0);
   flat.Feed(D(0, 1), 50000.0, 50000.0);
   flat.Feed(D(0, 9), 50100.0, 50100.0);
   Check("A flat, compliant run still fails Phase 1",
         flat.CompliancePassed() && flat.Phase1Passed() == false,
         "surviving is not the same as passing");

//--- GROUP 10: News blackout counting
   CBacktestValidator news;
   news.Init(50000.0);
   datetime ev = D(0, 13);

   news.NoteNewsBlock(0);
   Check("A zero event time is not counted", news.NewsBlocks() == 0);

   news.NoteNewsBlock(ev);
   news.NoteNewsBlock(ev);
   news.NoteNewsBlock(ev);
   Check("The same release blocking repeatedly counts once",
         news.NewsBlocks() == 1,
         "a single event blocks for ten minutes of ticks");

   news.NoteNewsBlock(ev + 3600);
   Check("A different release counts separately", news.NewsBlocks() == 2);

//--- GROUP 11: Acceptance verdict
   CBacktestValidator verdict;
   verdict.Init(50000.0);
   verdict.Feed(D(0, 1), 50000.0, 50000.0);
   verdict.Feed(D(0, 9), 55000.0, 55000.0);

   Check("A compliant run with no trades still fails acceptance",
         verdict.CriteriaPassed() == false,
         "the 300-trade minimum is not met by an empty sample");
   Check("Too few trades score zero for the optimiser",
         verdict.OptimisationScore() == 0.0);
   Check("Rule compliance and acceptance are separate verdicts",
         verdict.CompliancePassed() && verdict.CriteriaPassed() == false,
         "a run can break no rules and still not justify buying a challenge");

//--- Summary
   Print("[QA] ===== RESULT: ", test_passed, " passed, ", test_failed, " failed =====");
  }

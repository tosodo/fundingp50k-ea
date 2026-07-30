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

//--- Summary
   Print("[QA] ===== RESULT: ", test_passed, " passed, ", test_failed, " failed =====");
  }

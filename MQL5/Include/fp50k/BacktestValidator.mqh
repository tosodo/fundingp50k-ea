//+------------------------------------------------------------------+
//| BacktestValidator.mqh                                             |
//| FP50K-EA | Sprint 4 - Strategy Tester validation overlay          |
//| Watches the equity curve and reports challenge survival           |
//| Author: Tee (aigentforce.io) | Built: July 2026                   |
//+------------------------------------------------------------------+
//
// This class never opens, closes or modifies a position. It only observes.
// Its whole job is to answer one question at the end of a Strategy Tester
// run: would this run have survived the FundingPips challenge?
//
// It measures against the FIRM's hard walls - the $2,000 daily loss limit and
// the $44,000 equity floor - and not against the EA's own tighter internal
// buffers. That distinction is the point. The EA is supposed to stop trading
// well before the firm's limits are reached; this overlay is the evidence
// that it actually did, rather than an assumption that it would.
//
// Testability: everything the class knows arrives through Feed(), which takes
// time, equity and balance as explicit parameters. Nothing here reads
// AccountInfoDouble() on its own. That is deliberate - a unit test can drive a
// synthetic equity curve through Feed() and check the arithmetic offline,
// which is impossible for code that reads live account state directly.

#ifndef _BACKTESTVALIDATOR_MQH_
#define _BACKTESTVALIDATOR_MQH_

// Included for the FundingPips constants, which live in exactly one place.
#include "RiskManager.mqh"

//--- The firm's own hard walls, which our internal limits sit inside
#define BT_FIRM_DAILY_WALL     2000.0
#define BT_FIRM_EQUITY_FLOOR   FP_EQUITY_FLOOR

//--- A day that reaches this fraction of our $1,800 hard stop without
//    tripping it is recorded as a near miss. Near misses are the early
//    warning: a strategy that keeps grazing the stop will eventually hit it.
#define BT_NEAR_MISS_FRACTION  0.80

//--- Challenge targets, as a percentage of the starting balance
#define BT_PHASE1_TARGET_PCT   10.0
#define BT_PHASE2_TARGET_PCT    6.0

//--- Minimum acceptance criteria before a challenge is worth buying
//    (briefing Task 5). These are thresholds for the verdict, not tuning
//    parameters - do not relax them to make a run pass.
#define BT_MIN_TRADES          300
#define BT_MAX_DD_PCT            8.0
#define BT_MIN_WIN_RATE_PCT     45.0
#define BT_PHASE1_MAX_SESSIONS  30

//--- Sweep & fade acceptance targets (July 2026 upgrade spec). At 2.5:1 the
//    break-even hit rate is 28.6%, so 38% is a real margin rather than a
//    rounding error - which is the whole point of stating it in advance.
#define BT_SWEEP_MIN_WIN_PCT    38.0
#define BT_MAX_DAILY_DD_PCT      4.0
#define BT_MAX_OVERALL_DD_PCT    9.0

class CBacktestValidator {
private:
  bool     m_active;
  double   m_start_balance;

  //--- Equity curve
  double   m_peak_equity;
  double   m_max_dd_pct;
  double   m_min_equity;
  datetime m_min_equity_time;
  double   m_last_equity;
  datetime m_last_time;

  //--- Per-day accounting
  long     m_day_index;        // days since epoch of the day currently open
  bool     m_day_open;
  double   m_day_anchor;       // equity at the moment the day opened
  double   m_day_worst_loss;   // deepest intraday loss so far today

  int      m_days;
  int      m_wall_hits;        // days touching the firm's $2,000 wall
  int      m_hard_hits;        // days touching our $1,800 hard stop
  int      m_near_misses;      // days reaching 80% of the hard stop, not it
  int      m_soft_hits;        // days touching our $1,000 soft stop
  double   m_worst_daily_loss;
  datetime m_worst_day;

  // Worst intraday fall as a percentage of the baseline that day opened at.
  // Tracked separately from the peak-to-trough figure above because the firm
  // judges the two by different rules and a run can pass one and fail the other.
  double   m_worst_daily_dd_pct;

  //--- Equity floor
  bool     m_floor_breached;
  datetime m_floor_time;
  double   m_floor_equity;

  //--- Phase targets
  bool     m_p1_hit;  datetime m_p1_time;  int m_p1_days;
  bool     m_p2_hit;  datetime m_p2_time;  int m_p2_days;

  //--- News blackouts actually observed during the run
  int      m_news_blocks;
  datetime m_last_news_seen;

  //--- Closed-trade statistics, gathered once at the end of the run
  int      m_trades, m_wins, m_losses;
  double   m_gross_win, m_gross_loss, m_net_profit;
  bool     m_stats_done;

  void     CloseDay();
  void     Emit(int fh, string line);

public:
  CBacktestValidator();

  bool     Init(double start_balance);
  void     Feed(datetime now, double equity, double balance);
  void     NoteNewsBlock(datetime event_time);
  void     CollectTradeStats(ulong magic);
  void     Finalise(ulong magic);
  void     Report(ulong magic);

  //--- Pure helpers. No account, market or calendar access, so a unit test can
  //    call them directly with known numbers. Defined inline so they stay
  //    beside the rule each one encodes.

  //--- Whole days since the epoch. Day boundaries follow the server clock the
  //    tester is modelling, which is the clock the firm's daily reset uses.
  static long DayIndexOf(datetime t) { return (long)t / 86400; }

  //--- How far below the running peak, as a percentage of that peak
  static double DrawdownPct(double peak, double equity) {
    if(peak <= 0.0) return 0.0;
    if(equity >= peak) return 0.0;
    return (peak - equity) / peak * 100.0;
  }

  //--- Close to the hard stop without tripping it
  static bool IsNearMiss(double daily_loss) {
    double threshold = FP_DAILY_HARD_STOP * BT_NEAR_MISS_FRACTION;
    return (daily_loss >= threshold && daily_loss < FP_DAILY_HARD_STOP);
  }

  static double WinRatePct(int wins, int trades) {
    if(trades <= 0) return 0.0;
    return (double)wins * 100.0 / (double)trades;
  }

  //--- Expected value per trade: what one trade is worth on average, in
  //    dollars. This is the number that decides whether a strategy is worth
  //    running at all - a positive win rate at a good R:R still loses money if
  //    the average loss is bigger than the arithmetic assumed.
  static double ExpectedValuePerTrade(double net_profit, int trades) {
    if(trades <= 0) return 0.0;
    return net_profit / (double)trades;
  }

  //--- The same figure in R multiples, which travels between account sizes.
  //    avg_loss is given as a positive number.
  static double ExpectancyR(double win_rate_pct, double avg_win, double avg_loss) {
    if(avg_loss <= 0.0) return 0.0;
    double p = win_rate_pct / 100.0;
    return (p * avg_win - (1.0 - p) * avg_loss) / avg_loss;
  }

  //--- The hit rate a given reward-to-risk ratio needs just to break even,
  //    before costs. Printed beside the measured rate so the verdict does not
  //    depend on the reader doing the arithmetic.
  static double BreakEvenWinRatePct(double rr) {
    if(rr <= 0.0) return 100.0;
    return 100.0 / (1.0 + rr);
  }

  //--- Gross win over gross loss, both given as positive numbers. With no
  //    losing trades the ratio is undefined; 999 is returned as a
  //    recognisable sentinel rather than an infinity that formats badly.
  static double ProfitFactorOf(double gross_win, double gross_loss) {
    if(gross_loss <= 0.0) return (gross_win > 0.0) ? 999.0 : 0.0;
    return gross_win / gross_loss;
  }

  //--- Rounded to the cent deliberately. 50000 * (1 + 10/100) evaluates to
  //    55000.000000000004 in binary floating point, so an account sitting at
  //    exactly $55,000.00 would never be seen to reach a +10% target. Money
  //    compares at cent resolution; anything finer is an artefact.
  static double TargetEquity(double start_balance, double target_pct) {
    return NormalizeDouble(start_balance * (1.0 + target_pct / 100.0), 2);
  }

  //--- Verdicts
  bool     CompliancePassed();
  bool     CriteriaPassed();
  bool     Phase1Passed();
  bool     Phase2Passed();
  double   OptimisationScore();

  //--- Getters, used by the report and by the tests
  double   MaxDDPct()        { return m_max_dd_pct; }
  double   WorstDailyLoss()  { return m_worst_daily_loss; }
  double   WorstDailyDDPct() { return m_worst_daily_dd_pct; }
  double   AvgWin()          { return (m_wins   > 0) ? m_gross_win  / m_wins   : 0.0; }
  double   AvgLoss()         { return (m_losses > 0) ? m_gross_loss / m_losses : 0.0; }
  double   EVPerTrade()      { return ExpectedValuePerTrade(m_net_profit, m_trades); }
  int      DaysTracked()     { return m_days; }
  int      WallHits()        { return m_wall_hits; }
  int      HardStopHits()    { return m_hard_hits; }
  int      NearMisses()      { return m_near_misses; }
  int      SoftStopHits()    { return m_soft_hits; }
  bool     FloorBreached()   { return m_floor_breached; }
  bool     Phase1Reached()   { return m_p1_hit; }
  bool     Phase2Reached()   { return m_p2_hit; }
  int      Phase1Sessions()  { return m_p1_days; }
  int      Phase2Sessions()  { return m_p2_days; }
  int      NewsBlocks()      { return m_news_blocks; }
  int      Trades()          { return m_trades; }
  double   NetProfit()       { return m_net_profit; }
  double   MinEquity()       { return m_min_equity; }
};

//--- Constructor
CBacktestValidator::CBacktestValidator() {
  m_active           = false;
  m_start_balance    = FP_INITIAL_BALANCE;
  m_peak_equity      = FP_INITIAL_BALANCE;
  m_max_dd_pct       = 0.0;
  m_min_equity       = FP_INITIAL_BALANCE;
  m_min_equity_time  = 0;
  m_last_equity      = FP_INITIAL_BALANCE;
  m_last_time        = 0;

  m_day_index        = 0;
  m_day_open         = false;
  m_day_anchor       = FP_INITIAL_BALANCE;
  m_day_worst_loss   = 0.0;

  m_days             = 0;
  m_wall_hits        = 0;
  m_hard_hits        = 0;
  m_near_misses      = 0;
  m_soft_hits        = 0;
  m_worst_daily_loss = 0.0;
  m_worst_day        = 0;
  m_worst_daily_dd_pct = 0.0;

  m_floor_breached   = false;
  m_floor_time       = 0;
  m_floor_equity     = 0.0;

  m_p1_hit = false; m_p1_time = 0; m_p1_days = 0;
  m_p2_hit = false; m_p2_time = 0; m_p2_days = 0;

  m_news_blocks      = 0;
  m_last_news_seen   = 0;

  m_trades = 0; m_wins = 0; m_losses = 0;
  m_gross_win = 0.0; m_gross_loss = 0.0; m_net_profit = 0.0;
  m_stats_done = false;
}

//--- Init: anchor everything to the balance the run actually started with
bool CBacktestValidator::Init(double start_balance) {
  if(start_balance <= 0.0) {
    Print("[Validator] ERROR: start balance must be positive, got ", start_balance);
    return false;
  }

  m_active        = true;
  m_start_balance = start_balance;
  m_peak_equity   = start_balance;
  m_min_equity    = start_balance;
  m_last_equity   = start_balance;
  m_day_anchor    = start_balance;

  // Every dollar threshold in this file assumes a $50,000 account. If the
  // tester was configured with a different deposit, the percentages still
  // mean something but the dollar walls do not - say so loudly rather than
  // producing a confident-looking report about the wrong account size.
  if(MathAbs(start_balance - FP_INITIAL_BALANCE) > 1.0) {
    Print("[Validator] WARNING: run started at $", DoubleToString(start_balance, 2),
          " but the FundingPips walls assume $", DoubleToString(FP_INITIAL_BALANCE, 2),
          ". Dollar limits in this report will NOT match the real challenge.");
  }

  Print("[Validator] Backtest validation active | start=$",
        DoubleToString(start_balance, 2),
        " | Phase 1 target $", DoubleToString(TargetEquity(start_balance, BT_PHASE1_TARGET_PCT), 2),
        " | Phase 2 target $", DoubleToString(TargetEquity(start_balance, BT_PHASE2_TARGET_PCT), 2),
        " | equity floor $", DoubleToString(BT_FIRM_EQUITY_FLOOR, 2));
  return true;
}

//--- CloseDay: fold the day just finished into the running counters
void CBacktestValidator::CloseDay() {
  if(!m_day_open) return;
  m_day_open = false;
  m_days++;

  if(m_day_worst_loss > m_worst_daily_loss) {
    m_worst_daily_loss = m_day_worst_loss;
    m_worst_day        = m_last_time;
  }

  // Same fall, expressed against the baseline the day opened at - the form the
  // firm's 5% daily rule is actually written in.
  if(m_day_anchor > 0.0) {
    double day_dd_pct = m_day_worst_loss / m_day_anchor * 100.0;
    if(day_dd_pct > m_worst_daily_dd_pct) m_worst_daily_dd_pct = day_dd_pct;
  }

  if(m_day_worst_loss >= BT_FIRM_DAILY_WALL) {
    m_wall_hits++;
    Print("[Validator] DAILY WALL BREACHED on ", TimeToString(m_last_time, TIME_DATE),
          ": intraday loss $", DoubleToString(m_day_worst_loss, 2),
          " reached the firm's $", DoubleToString(BT_FIRM_DAILY_WALL, 2), " limit.");
  }

  if(m_day_worst_loss >= FP_DAILY_HARD_STOP) {
    m_hard_hits++;
    Print("[Validator] Hard stop reached on ", TimeToString(m_last_time, TIME_DATE),
          ": intraday loss $", DoubleToString(m_day_worst_loss, 2));
  } else if(IsNearMiss(m_day_worst_loss)) {
    m_near_misses++;
    Print("[Validator] Near miss on ", TimeToString(m_last_time, TIME_DATE),
          ": intraday loss $", DoubleToString(m_day_worst_loss, 2),
          " (", DoubleToString(BT_NEAR_MISS_FRACTION * 100.0, 0),
          "% of the $", DoubleToString(FP_DAILY_HARD_STOP, 2), " hard stop)");
  }

  if(m_day_worst_loss >= FP_DAILY_SOFT_STOP) m_soft_hits++;
}

//--- Feed: one equity sample. Called on every tick in the tester, but the
//    work here is a handful of comparisons, so it stays off the hot path.
void CBacktestValidator::Feed(datetime now, double equity, double balance) {
  if(!m_active) return;
  if(equity <= 0.0) return;   // no account state yet - nothing to measure

  m_last_time   = now;
  m_last_equity = equity;

  //--- Day rollover
  // The baseline is the HIGHER of balance and equity, matching the rule the
  // firm applies at the 00:00 platform-time reset. On a day opened with a
  // position floating at a loss, anchoring to equity alone would quietly
  // forgive the money already down and understate the day's drawdown.
  long idx = DayIndexOf(now);
  double baseline = MathMax(balance, equity);
  if(!m_day_open) {
    m_day_open       = true;
    m_day_index      = idx;
    m_day_anchor     = baseline;
    m_day_worst_loss = 0.0;
  } else if(idx != m_day_index) {
    CloseDay();
    m_day_open       = true;
    m_day_index      = idx;
    m_day_anchor     = baseline;
    m_day_worst_loss = 0.0;
  }

  //--- Intraday loss, measured from the equity the day opened at. This is how
  //    the firm measures it: a fresh allowance every day, not a running total.
  double day_loss = m_day_anchor - equity;
  if(day_loss > m_day_worst_loss) m_day_worst_loss = day_loss;

  //--- Peak, trough and drawdown
  if(equity > m_peak_equity) m_peak_equity = equity;
  if(equity < m_min_equity) {
    m_min_equity      = equity;
    m_min_equity_time = now;
  }

  double dd = DrawdownPct(m_peak_equity, equity);
  if(dd > m_max_dd_pct) m_max_dd_pct = dd;

  //--- Equity floor. One breach fails the whole run, so record only the first.
  if(!m_floor_breached && equity < BT_FIRM_EQUITY_FLOOR) {
    m_floor_breached = true;
    m_floor_time     = now;
    m_floor_equity   = equity;
    Print("[Validator] EQUITY FLOOR BREACHED at ", TimeToString(now),
          ": equity $", DoubleToString(equity, 2),
          " fell below $", DoubleToString(BT_FIRM_EQUITY_FLOOR, 2),
          ". This run is a challenge failure.");
  }

  //--- Phase targets, recorded the first time each is crossed
  if(!m_p2_hit && equity >= TargetEquity(m_start_balance, BT_PHASE2_TARGET_PCT)) {
    m_p2_hit  = true;
    m_p2_time = now;
    m_p2_days = m_days + 1;
    Print("[Validator] Phase 2 target (+", DoubleToString(BT_PHASE2_TARGET_PCT, 0),
          "%) reached at ", TimeToString(now), " on session ", m_p2_days);
  }
  if(!m_p1_hit && equity >= TargetEquity(m_start_balance, BT_PHASE1_TARGET_PCT)) {
    m_p1_hit  = true;
    m_p1_time = now;
    m_p1_days = m_days + 1;
    Print("[Validator] Phase 1 target (+", DoubleToString(BT_PHASE1_TARGET_PCT, 0),
          "%) reached at ", TimeToString(now), " on session ", m_p1_days);
  }
}

//--- NoteNewsBlock: count distinct events that caused a blackout. Deduped by
//    event time, because the same release blocks repeatedly for ten minutes.
void CBacktestValidator::NoteNewsBlock(datetime event_time) {
  if(!m_active) return;
  if(event_time <= 0) return;
  if(event_time == m_last_news_seen) return;
  m_last_news_seen = event_time;
  m_news_blocks++;
}

//--- CollectTradeStats: read the closed deals the run produced.
//    DEAL_ENTRY_OUT is the closing side of a position; counting those counts
//    round-trip trades rather than double-counting entries and exits.
void CBacktestValidator::CollectTradeStats(ulong magic) {
  if(m_stats_done) return;
  m_stats_done = true;

  if(!HistorySelect(0, TimeCurrent())) {
    Print("[Validator] WARNING: could not read trade history - trade statistics unavailable.");
    return;
  }

  int total = HistoryDealsTotal();
  for(int i = 0; i < total; i++) {
    ulong ticket = HistoryDealGetTicket(i);
    if(ticket == 0) continue;
    if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;

    long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
    if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

    double pnl = HistoryDealGetDouble(ticket, DEAL_PROFIT)
               + HistoryDealGetDouble(ticket, DEAL_SWAP)
               + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

    m_trades++;
    m_net_profit += pnl;
    if(pnl >= 0.0) { m_wins++;   m_gross_win  += pnl; }
    else           { m_losses++; m_gross_loss += -pnl; }
  }
}

//--- Finalise: close the books. Idempotent, because the Strategy Tester calls
//    OnTester() before OnDeinit() and both need the totals to be complete.
void CBacktestValidator::Finalise(ulong magic) {
  if(!m_active) return;
  CollectTradeStats(magic);
  CloseDay();
}

//--- CompliancePassed: did the run stay inside the firm's rules at all times?
bool CBacktestValidator::CompliancePassed() {
  return (!m_floor_breached && m_wall_hits == 0 && m_hard_hits == 0);
}

//--- CriteriaPassed: the full "is this worth buying a challenge for" test.
//
//    The win-rate bar moved from 45% to 38% when the strategy moved from a 2:1
//    to a 2.5:1 target. That is a restatement, not a relaxation: 45% at 2:1 is
//    0.35 R per trade and 38% at 2.5:1 is 0.33 R - the same demand, expressed
//    for the new geometry. The EV floor below is what stops the lower headline
//    number becoming a loophole; a strategy can clear 38% and still lose money
//    if its average loss is bigger than the arithmetic assumed, and that has
//    already happened once on this project.
bool CBacktestValidator::CriteriaPassed() {
  if(!CompliancePassed()) return false;
  if(m_trades < BT_MIN_TRADES) return false;
  if(m_max_dd_pct >= BT_MAX_DD_PCT) return false;
  if(m_worst_daily_dd_pct >= BT_MAX_DAILY_DD_PCT) return false;
  if(WinRatePct(m_wins, m_trades) < BT_SWEEP_MIN_WIN_PCT) return false;
  if(EVPerTrade() <= 0.0) return false;
  return true;
}

bool CBacktestValidator::Phase1Passed() {
  return (m_p1_hit && CompliancePassed() && m_p1_days <= BT_PHASE1_MAX_SESSIONS);
}

bool CBacktestValidator::Phase2Passed() {
  return (m_p2_hit && CompliancePassed());
}

//--- OptimisationScore: what the Strategy Tester's optimiser should maximise.
//    Returning zero for any non-compliant run is the important part - without
//    it the optimiser happily picks the parameter set that makes the most
//    money by breaking the rules that end the challenge.
double CBacktestValidator::OptimisationScore() {
  if(!CompliancePassed()) return 0.0;
  if(m_trades < 30)       return 0.0;   // too few trades to mean anything
  if(m_net_profit <= 0.0) return 0.0;
  return m_net_profit / MathMax(m_max_dd_pct, 0.5);
}

//--- Emit: one line to the journal and, when open, to the summary file
void CBacktestValidator::Emit(int fh, string line) {
  Print(line);
  if(fh != INVALID_HANDLE) FileWrite(fh, line);
}

//--- Report: the OnDeinit() summary
void CBacktestValidator::Report(ulong magic) {
  if(!m_active) return;

  Finalise(magic);

  double win_rate = WinRatePct(m_wins, m_trades);
  double pf       = ProfitFactorOf(m_gross_win, m_gross_loss);

  // FILE_COMMON puts this in the shared Files folder rather than the tester
  // agent's own sandbox, which is a temporary directory wiped between runs.
  int fh = FileOpen("fp50k_backtest_summary.txt",
                    FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);

  Emit(fh, "==================================================================");
  Emit(fh, " FP50K-EA | BACKTEST VALIDATION SUMMARY");
  Emit(fh, "==================================================================");
  Emit(fh, StringFormat(" Start balance      : $%.2f", m_start_balance));
  Emit(fh, StringFormat(" Trading sessions   : %d", m_days));
  Emit(fh, StringFormat(" Closed trades      : %d   (minimum required: %d)",
                        m_trades, BT_MIN_TRADES));
  Emit(fh, StringFormat(" Net profit         : $%.2f", m_net_profit));
  Emit(fh, StringFormat(" Win rate           : %.1f%%  (minimum required: %.1f%%)",
                        win_rate, BT_MIN_WIN_RATE_PCT));
  Emit(fh, StringFormat(" Profit factor      : %.2f", pf));
  Emit(fh, "------------------------------------------------------------------");
  Emit(fh, StringFormat(" EV per trade       : $%.2f   <-- the number that decides it",
                        EVPerTrade()));
  Emit(fh, StringFormat(" Average win        : $%.2f", AvgWin()));
  Emit(fh, StringFormat(" Average loss       : $%.2f", AvgLoss()));
  Emit(fh, StringFormat(" Expectancy         : %.3f R per trade",
                        ExpectancyR(win_rate, AvgWin(), AvgLoss())));
  Emit(fh, StringFormat(" Sweep-model target : %.1f%% win rate (break-even at 2.5:1 is %.1f%%)",
                        BT_SWEEP_MIN_WIN_PCT, BreakEvenWinRatePct(2.5)));
  Emit(fh, "------------------------------------------------------------------");
  Emit(fh, StringFormat(" Max drawdown       : %.2f%%  (must stay under %.1f%%)",
                        m_max_dd_pct, BT_MAX_DD_PCT));
  Emit(fh, StringFormat(" Worst DAILY drawdown : %.2f%%  (must stay under %.1f%%)",
                        m_worst_daily_dd_pct, BT_MAX_DAILY_DD_PCT));
  Emit(fh, StringFormat(" Overall DD headroom  : %.2f%% used of %.1f%% allowed",
                        m_max_dd_pct, BT_MAX_OVERALL_DD_PCT));
  Emit(fh, StringFormat(" Lowest equity      : $%.2f  at %s",
                        m_min_equity, TimeToString(m_min_equity_time)));
  Emit(fh, StringFormat(" Worst daily loss   : $%.2f  on %s",
                        m_worst_daily_loss, TimeToString(m_worst_day, TIME_DATE)));
  Emit(fh, "------------------------------------------------------------------");
  Emit(fh, StringFormat(" Firm $%.0f daily wall breached : %d day(s)",
                        BT_FIRM_DAILY_WALL, m_wall_hits));
  Emit(fh, StringFormat(" Our  $%.0f hard stop reached   : %d day(s)",
                        FP_DAILY_HARD_STOP, m_hard_hits));
  Emit(fh, StringFormat(" Near misses (>= %.0f%% of hard stop) : %d day(s)",
                        BT_NEAR_MISS_FRACTION * 100.0, m_near_misses));
  Emit(fh, StringFormat(" Our  $%.0f soft stop reached   : %d day(s)",
                        FP_DAILY_SOFT_STOP, m_soft_hits));
  Emit(fh, StringFormat(" Firm $%.0f equity floor        : %s",
                        BT_FIRM_EQUITY_FLOOR,
                        m_floor_breached
                          ? StringFormat("BREACHED at %s with $%.2f",
                                         TimeToString(m_floor_time), m_floor_equity)
                          : "never breached"));
  Emit(fh, "------------------------------------------------------------------");
  Emit(fh, StringFormat(" News blackouts observed : %d", m_news_blocks));
  if(m_news_blocks == 0) {
    // A zero here is ambiguous and the ambiguity is dangerous. Over a
    // multi-year sample there are hundreds of red-folder releases, so zero
    // almost certainly means the tester had no calendar database rather than
    // that no event ever fell in a trading window - and that would make this
    // whole run optimistic, because it traded straight through every release.
    Emit(fh, "   WARNING: zero blackouts over the whole run. Either the sample is");
    Emit(fh, "   very short, or the Strategy Tester had no economic calendar data.");
    Emit(fh, "   In the second case this run is OPTIMISTIC - it never paid the cost");
    Emit(fh, "   of a news release. Open the terminal's Calendar tab to populate it,");
    Emit(fh, "   then re-run before trusting these numbers.");
  }
  Emit(fh, "------------------------------------------------------------------");
  Emit(fh, StringFormat(" Phase 1 (+%.0f%%) : %s",
                        BT_PHASE1_TARGET_PCT,
                        m_p1_hit
                          ? StringFormat("reached on session %d of %d allowed - %s",
                                         m_p1_days, BT_PHASE1_MAX_SESSIONS,
                                         Phase1Passed() ? "PASS" : "FAIL")
                          : "never reached - FAIL"));
  Emit(fh, StringFormat(" Phase 2 (+%.0f%%) : %s",
                        BT_PHASE2_TARGET_PCT,
                        m_p2_hit
                          ? StringFormat("reached on session %d - %s",
                                         m_p2_days, Phase2Passed() ? "PASS" : "FAIL")
                          : "never reached - FAIL"));
  Emit(fh, "==================================================================");
  Emit(fh, StringFormat(" RULE COMPLIANCE  : %s",
                        CompliancePassed() ? "PASS - no wall, stop or floor breach"
                                           : "FAIL - see the breaches listed above"));
  Emit(fh, StringFormat(" ACCEPTANCE       : %s",
                        CriteriaPassed()
                          ? "PASS - this sample meets every minimum criterion"
                          : "FAIL - does not yet justify buying a challenge"));
  Emit(fh, "==================================================================");

  if(fh != INVALID_HANDLE) {
    FileClose(fh);
    Print("[Validator] Summary also written to the shared Files folder as ",
          "fp50k_backtest_summary.txt");
  } else {
    Print("[Validator] NOTE: could not write the summary file - journal output above ",
          "is the full report.");
  }
}

#endif

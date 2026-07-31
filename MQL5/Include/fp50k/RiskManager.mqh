//+------------------------------------------------------------------+
//| RiskManager.mqh                                                   |
//| FP50K-EA | Risk Governor Layer 1                                  |
//| Enforces all FundingPips $50k 2-Step Flex rules                  |
//| 8-layer pre-trade gate, daily state machine, emergency kill       |
//+------------------------------------------------------------------+

#ifndef _RISKMANAGER_MQH_
#define _RISKMANAGER_MQH_

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>
#include "NewsFilter.mqh"
#include "Clock.mqh"

//--- FundingPips Hard Limits (verified July 2026)
#define FP_INITIAL_BALANCE     50000.0
#define FP_EQUITY_FLOOR        44000.0
#define FP_DD_EMERGENCY_FLOOR  44500.0
#define FP_DAILY_HARD_STOP     1800.0
#define FP_DAILY_SOFT_STOP     1000.0
#define FP_MAX_TRADE_RISK_USD  1000.0

//--- Percentage limits, expressed as a safety buffer inside the firm's rules.
//
//    These sit ALONGSIDE the dollar constants above; they never replace them.
//    Every runtime limit is the TIGHTER of the two, so adding this layer can
//    only ever restrict the EA further. That matters because the dollar
//    constants were sized for one specific programme and one specific account
//    size, whereas the percentages travel - and if the two ever disagree, the
//    safe reading is the one that trades less.
#define FP_DAILY_DD_PCT        4.0    // buffer inside the firm's 5.0% daily rule
#define FP_OVERALL_DD_PCT      9.0    // buffer inside the firm's 10.0% overall rule
#define FP_RISK_PER_TRADE_PCT  0.75   // % of live equity risked on one trade

//--- Session Windows (UTC)
#define SESSION_OPEN_HOUR      7      // 07:00 UTC - London open
#define SESSION_CLOSE_HOUR     17     // 17:00 UTC - NY afternoon
#define FRIDAY_FLATTEN_HOUR    20     // 20:00 UTC Friday - close all before weekend

//--- NEWS_BLOCK_MINUTES (+/-5 min red-folder blackout) is defined in
//    NewsFilter.mqh, which owns the calendar logic this class delegates to.

//+------------------------------------------------------------------+
//| RiskStatus - one answer to "may I trade, and how big?"            |
//|                                                                   |
//| Returned by EvaluateRisk(). Always check isTradingAllowed first;   |
//| every other field is diagnostic and is populated even when the    |
//| answer is no, so a refusal can be logged with its reason rather   |
//| than disappearing as a silent zero.                               |
//+------------------------------------------------------------------+
struct RiskStatus {
  bool   isTradingAllowed;    // Master flag to halt trade entries
  double maxAllowedLotSize;   // Max volume for next trade based on risk cap
  double riskUsd;             // Dollar risk the lot size was derived from
  double currentDailyLoss;    // Current loss accrued today ($)
  double dailyFloor;          // Absolute equity level that triggers daily stop
  double overallFloor;        // Absolute equity level that breaches challenge
  string statusReason;        // Status message for logging

  RiskStatus() {
    isTradingAllowed  = false;
    maxAllowedLotSize = 0.0;
    riskUsd           = 0.0;
    currentDailyLoss  = 0.0;
    dailyFloor        = 0.0;
    overallFloor      = 0.0;
    statusReason      = "";
  }
};

//--- Risk Manager States
enum RISK_STATE {
  RISK_OK = 0,           // All systems go
  RISK_SOFT_STOP = 1,    // Daily loss reached $1,000 soft-stop - no new entries
  RISK_HARD_STOP = 2,    // Daily loss reached $1,800 hard-stop - no new entries
  RISK_KILLED = 3        // Equity floor breached or emergency condition - EA halted
};

class CRiskManager {
private:
  // State tracking
  RISK_STATE m_state;
  bool       m_killed;
  datetime   m_last_day;

  // Daily accumulator. m_day_anchor_equity is the equity the CURRENT day
  // opened at, not the equity the challenge started at - the firm grants a
  // fresh daily allowance every day, so the anchor has to move with it.
  double     m_daily_loss_usd;
  double     m_day_anchor_equity;

  // The balance the challenge started at. The overall floor is measured from
  // this and never moves - unlike the daily anchor, which resets every day.
  double     m_initial_balance;
  double     m_overall_floor;

  // News blackout half-width in minutes. Settable because the firm's own
  // guidance and the strategy's tolerance for a release are different numbers.
  int        m_news_block_min;

  // Trading window in UTC hours. Mirrors the signal engine's hunt window.
  int        m_session_open_hour;
  int        m_session_close_hour;

  // Log file
  int        m_log_file;
  string     m_log_filename;

  // Magic number for position filtering
  ulong      m_magic_number;

  // Economic calendar. Owned by CNewsFilter - see NewsFilter.mqh for why the
  // events are cached rather than queried on demand.
  CNewsFilter m_news;

  // Helper methods
  bool   IsInsideSessionWindow();
  bool   IsFridayFlatten();
  void   LogDecision(string symbol, string decision, double equity, double daily_loss, bool blocked);
  void   WriteCSVHeader();

public:
  CRiskManager();
  ~CRiskManager();

  bool   Init(double initial_balance = FP_INITIAL_BALANCE, ulong magic = 50001);
  void   OnNewDay();
  void   OnTick();
  bool   CanOpenTrade(double sl_pips, double risk_usd, string symbol, string &block_reason);
  double CalculateLotSize(double risk_usd, double sl_pips, string symbol);
  void   KillSwitch();
  void   FridayFlatten();

  // OnTickUpdate: the per-tick entry point named in the upgrade spec. OnTick()
  // already does exactly this work, so this is a name, not a second code path -
  // two implementations of the daily reset is precisely the bug that would end
  // a challenge quietly.
  void   OnTickUpdate() { OnTick(); }

  // EvaluateRisk: the single call an execution layer needs before sending.
  // Answers "may I trade, and at what size", with every gate already applied
  // and the reason attached when the answer is no.
  RiskStatus EvaluateRisk(double sl_pips, string symbol = "");

  void   SetNewsBlockMinutes(int minutes) {
    m_news_block_min = (minutes > 0) ? minutes : NEWS_BLOCK_MINUTES;
  }
  int    GetNewsBlockMinutes() { return m_news_block_min; }

  //--- Trading window, UTC hours. Must track the signal engine's hunt window:
  //    this gate refuses entries outside it, so a hunt window the governor does
  //    not know about produces a strategy that finds setups and is blocked from
  //    taking every one of them.
  void   SetSessionWindow(int open_hour, int close_hour) {
    if(open_hour < 0 || open_hour > 23 || close_hour < 0 || close_hour > 23) return;
    if(open_hour == close_hour) return;
    m_session_open_hour  = open_hour;
    m_session_close_hour = close_hour;
  }
  int    SessionOpenHour()  { return m_session_open_hour; }
  int    SessionCloseHour() { return m_session_close_hour; }

  //--- Same wrap-aware test the signal engine uses, kept static so both agree
  //    by construction rather than by two matching comments.
  static bool HourInSession(int hour, int open_hour, int close_hour) {
    if(open_hour == close_hour) return false;
    if(open_hour < close_hour)  return (hour >= open_hour && hour < close_hour);
    return (hour >= open_hour || hour < close_hour);
  }

  // Pure helpers - no account access, so tests can drive them with known
  // numbers instead of needing a live balance the sandbox does not have.

  // Loss so far today, measured from the day's opening equity. Positive means
  // down on the day; negative means up on the day.
  static double DailyLossFrom(double day_anchor, double equity) {
    return day_anchor - equity;
  }

  // Which gate the day's loss puts us behind.
  static RISK_STATE StateFromDailyLoss(double daily_loss) {
    if(daily_loss >= FP_DAILY_HARD_STOP) return RISK_HARD_STOP;
    if(daily_loss >= FP_DAILY_SOFT_STOP) return RISK_SOFT_STOP;
    return RISK_OK;
  }

  // The equity a new day should measure its loss from. A non-positive reading
  // means there is no account state to read - an offline terminal, or a script
  // with no login - and re-anchoring to zero there would report a $50,000 loss
  // and hard-stop instantly. In that case the previous anchor is kept.
  static double NextDayAnchor(double prev_anchor, double equity) {
    return (equity > 0.0) ? equity : prev_anchor;
  }

  // The high-water baseline a new day is measured from. FundingPips resets the
  // daily allowance at 00:00 platform time (17:00 New York) against the HIGHER
  // of balance or equity, not against equity alone. The difference bites on a
  // day opened with a position still floating at a loss: anchoring to equity
  // there would quietly hand the EA back the money it was already down.
  static double NextDayBaseline(double prev_baseline, double balance, double equity) {
    double hwm = MathMax(balance, equity);
    return (hwm > 0.0) ? hwm : prev_baseline;
  }

  // The equity level at which the day stops. Percentage of the day's baseline.
  static double DailyFloorOf(double baseline, double pct) {
    return baseline * (1.0 - pct / 100.0);
  }

  // The equity level that ends the challenge. Percentage of the STARTING
  // balance - this one never moves with the account.
  static double OverallFloorOf(double initial_balance, double pct) {
    return initial_balance * (1.0 - pct / 100.0);
  }

  // The dollar loss that stops the day: the tighter of the fixed hard stop and
  // the percentage rule. Taking the minimum is what makes this layer additive -
  // it can restrict the EA further but can never grant it more room.
  static double EffectiveDailyStopUsd(double baseline, double pct) {
    return MathMin(FP_DAILY_HARD_STOP, baseline * pct / 100.0);
  }

  // The binding equity floor: the HIGHER of the fixed emergency floor and the
  // percentage floor. Same reasoning in the opposite direction - a higher floor
  // is the more cautious one.
  static double EffectiveOverallFloor(double initial_balance, double pct) {
    return MathMax(FP_DD_EMERGENCY_FLOOR, OverallFloorOf(initial_balance, pct));
  }

  // What one trade is allowed to risk, in dollars. Three ceilings apply and the
  // lowest wins: the percentage of equity, the firm's per-trade cap, and
  // whatever is left of today's allowance. The last one is the important one -
  // without it a full-size trade taken when the day is already most of the way
  // to its stop can push straight through it.
  static double RiskBudgetUsd(double equity, double pct,
                              double daily_loss, double daily_stop_usd) {
    if(equity <= 0.0) return 0.0;

    double by_pct    = equity * pct / 100.0;
    double remaining = daily_stop_usd - daily_loss;
    if(remaining < 0.0) remaining = 0.0;

    double budget = MathMin(by_pct, FP_MAX_TRADE_RISK_USD);
    return MathMin(budget, remaining);
  }

  // Dollar risk over stop distance, snapped to the broker's volume ladder.
  // Rounds DOWN, always: rounding up spends more than the budget approved.
  static double LotsFromRisk(double risk_usd, double sl_pips, double pip_value,
                             double step, double vmin, double vmax) {
    if(risk_usd <= 0.0 || sl_pips <= 0.0 || pip_value <= 0.0) return 0.0;
    if(step <= 0.0) step = 0.01;

    double lots = risk_usd / (sl_pips * pip_value);
    lots = MathFloor(lots / step) * step;
    lots = NormalizeDouble(lots, 2);

    if(vmax > 0.0 && lots > vmax) lots = vmax;
    if(lots < vmin) return 0.0;
    return lots;
  }

  // Getters
  RISK_STATE GetState() { return m_state; }
  bool       IsKilled() { return m_killed; }
  double     GetDailyLoss()    { return m_daily_loss_usd; }
  double     GetDayAnchor()    { return m_day_anchor_equity; }
  double     GetOverallFloor() { return m_overall_floor; }
  double     GetDailyFloor()   {
    return MathMax(DailyFloorOf(m_day_anchor_equity, FP_DAILY_DD_PCT),
                   m_day_anchor_equity - FP_DAILY_HARD_STOP);
  }

  // Exposed so the EA can reuse the same cached calendar for its pre-news
  // position close, rather than opening a second one and paying the fetch twice.
  CNewsFilter *News() { return GetPointer(m_news); }
};

//--- Constructor
CRiskManager::CRiskManager() {
  m_state = RISK_OK;
  m_killed = false;
  m_last_day = 0;
  m_daily_loss_usd = 0.0;
  m_day_anchor_equity = FP_INITIAL_BALANCE;
  m_initial_balance = FP_INITIAL_BALANCE;
  m_overall_floor = EffectiveOverallFloor(FP_INITIAL_BALANCE, FP_OVERALL_DD_PCT);
  m_news_block_min = NEWS_BLOCK_MINUTES;
  m_session_open_hour  = SESSION_OPEN_HOUR;
  m_session_close_hour = SESSION_CLOSE_HOUR;
  m_log_file = INVALID_HANDLE;
  m_magic_number = 50001;
}

//--- Destructor
CRiskManager::~CRiskManager() {
  if(m_log_file != INVALID_HANDLE) {
    FileClose(m_log_file);
    m_log_file = INVALID_HANDLE;
  }
}

//--- Init: Called once at EA start
bool CRiskManager::Init(double initial_balance, ulong magic) {
  m_day_anchor_equity = initial_balance;
  m_initial_balance   = initial_balance;
  m_overall_floor     = EffectiveOverallFloor(initial_balance, FP_OVERALL_DD_PCT);
  m_daily_loss_usd = 0.0;
  m_state = RISK_OK;
  m_killed = false;
  m_last_day = TimeCurrent();
  m_magic_number = magic;

  Print("[RiskManager] Limits | daily stop $",
        DoubleToString(EffectiveDailyStopUsd(initial_balance, FP_DAILY_DD_PCT), 2),
        " (tighter of $", DoubleToString(FP_DAILY_HARD_STOP, 0), " and ",
        DoubleToString(FP_DAILY_DD_PCT, 1), "%)",
        " | overall floor $", DoubleToString(m_overall_floor, 2),
        " (tighter of $", DoubleToString(FP_DD_EMERGENCY_FLOOR, 0), " and ",
        DoubleToString(FP_OVERALL_DD_PCT, 1), "% of $",
        DoubleToString(initial_balance, 0), ")",
        " | risk/trade ", DoubleToString(FP_RISK_PER_TRADE_PCT, 2), "% of equity");

  // Create log file (MQL5/Files/Logs/)
  MqlDateTime dt;
  TimeToStruct(TimeCurrent(), dt);
  FolderCreate("Logs");
  m_log_filename = StringFormat("Logs\\risk_log_%04d%02d%02d.csv", dt.year, dt.mon, dt.day);

  m_log_file = FileOpen(m_log_filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI);
  if(m_log_file != INVALID_HANDLE) {
    WriteCSVHeader();
    Print("[RiskManager] Initialized. Log: ", m_log_filename);
  } else {
    Print("[RiskManager] WARNING: Could not open log file: ", m_log_filename);
  }

  // Warm the calendar cache here, at attach time, so the one-off download cost
  // is paid before trading starts rather than stalling a live entry decision.
  m_news.Init();

  return true;
}

//--- OnNewDay: Called when date changes
void CRiskManager::OnNewDay() {
  datetime current_time = TimeCurrent();
  string current_date = TimeToString(current_time, TIME_DATE);
  string last_date = TimeToString(m_last_day, TIME_DATE);

  if(current_date != last_date) {
    // Re-anchor to today's high-water mark. Without this the "daily" loss is
    // really the loss since the challenge began, which never resets - one bad
    // week would hard-stop the EA permanently, and a good week would hand it
    // an allowance far larger than the firm actually grants.
    //
    // TimeCurrent() is broker server time, and the rollover therefore happens
    // at 00:00 on the platform clock - which is 17:00 New York, the moment
    // FundingPips resets the daily allowance. Using TimeGMT() here would reset
    // it at the wrong hour and mis-state every daily loss by up to a session.
    m_day_anchor_equity = NextDayBaseline(m_day_anchor_equity,
                                          AccountInfoDouble(ACCOUNT_BALANCE),
                                          AccountInfoDouble(ACCOUNT_EQUITY));
    m_daily_loss_usd = 0.0;
    m_state = RISK_OK;
    m_last_day = current_time;
    Print("[RiskManager] New trading day (00:00 platform / 17:00 New York). ",
          "Daily loss reset to $0. Baseline $",
          DoubleToString(m_day_anchor_equity, 2),
          " | daily floor $", DoubleToString(GetDailyFloor(), 2),
          " | overall floor $", DoubleToString(m_overall_floor, 2));
  }
}

//--- OnTick: State machine - called every tick
void CRiskManager::OnTick() {
  // Check for new day
  OnNewDay();

  // Check equity floor (absolute kill condition). m_overall_floor is the
  // tighter of the fixed emergency floor and the 9% rule, so this triggers at
  // whichever level protects the challenge soonest.
  if(AccountInfoDouble(ACCOUNT_EQUITY) < m_overall_floor) {
    Print("[RiskManager] EMERGENCY: Equity ", AccountInfoDouble(ACCOUNT_EQUITY),
          " below overall floor ", DoubleToString(m_overall_floor, 2), ". Killing EA.");
    KillSwitch();
    return;
  }

  // Check daily loss accumulation, measured from today's opening baseline
  m_daily_loss_usd = DailyLossFrom(m_day_anchor_equity,
                                   AccountInfoDouble(ACCOUNT_EQUITY));

  RISK_STATE new_state = StateFromDailyLoss(m_daily_loss_usd);

  // The percentage rule can be tighter than the fixed hard stop on a smaller
  // baseline. When it is, it binds - a stop that only fires at the looser of
  // two limits is not a safety buffer, it is decoration.
  if(new_state != RISK_HARD_STOP &&
     m_daily_loss_usd >= EffectiveDailyStopUsd(m_day_anchor_equity, FP_DAILY_DD_PCT))
    new_state = RISK_HARD_STOP;

  // Log only on transition. This runs every tick, and printing the same
  // stop message thousands of times buries everything else in the journal.
  if(new_state != m_state) {
    if(new_state == RISK_HARD_STOP)
      Print("[RiskManager] HARD STOP: Daily loss $", DoubleToString(m_daily_loss_usd, 2),
            " >= $", FP_DAILY_HARD_STOP, ". No new entries.");
    else if(new_state == RISK_SOFT_STOP)
      Print("[RiskManager] SOFT STOP: Daily loss $", DoubleToString(m_daily_loss_usd, 2),
            " >= $", FP_DAILY_SOFT_STOP, ". No new entries.");
    else
      Print("[RiskManager] Daily loss back under the soft stop ($",
            DoubleToString(m_daily_loss_usd, 2), "). Entries re-enabled.");
  }
  m_state = new_state;

  // Check Friday close-all
  if(IsFridayFlatten()) {
    FridayFlatten();
  }
}

//--- CanOpenTrade: 8-layer pre-trade gate
bool CRiskManager::CanOpenTrade(double sl_pips, double risk_usd, string symbol, string &block_reason) {
  block_reason = "";

  // Layer 1: State machine check
  if(m_state != RISK_OK) {
    block_reason = StringFormat("State not OK (state=%d, daily_loss=$%.2f)", (int)m_state, m_daily_loss_usd);
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 2: Killed check
  if(m_killed) {
    block_reason = "EA killed by KillSwitch";
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 3: Session window
  if(!IsInsideSessionWindow()) {
    block_reason = StringFormat("Outside the trading window (%02d:00-%02d:00 UTC)",
      m_session_open_hour, m_session_close_hour);
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 4: Equity floor
  if(AccountInfoDouble(ACCOUNT_EQUITY) < m_overall_floor) {
    block_reason = StringFormat("Equity $%.2f below overall floor $%.2f",
      AccountInfoDouble(ACCOUNT_EQUITY), m_overall_floor);
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 5: News blackout
  if(m_news.IsBlackedOut(symbol, m_news_block_min)) {
    block_reason = StringFormat("High-impact news event within +/-%d min", m_news_block_min);
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 5b: Spread gate
  int current_spread = (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
  int max_spread = (StringFind(symbol, "XAU") >= 0) ? 50 :
                   (StringFind(symbol, "GBP") >= 0) ? 25 : 20;
  if(current_spread > max_spread) {
    block_reason = StringFormat("Spread %d points exceeds max %d for %s",
      current_spread, max_spread, symbol);
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 6: Risk per trade cap
  if(risk_usd > FP_MAX_TRADE_RISK_USD) {
    block_reason = StringFormat("Risk $%.2f exceeds max $%.2f per trade", risk_usd, FP_MAX_TRADE_RISK_USD);
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 7: Daily loss projection, against the tighter of the two daily rules
  double daily_stop = EffectiveDailyStopUsd(m_day_anchor_equity, FP_DAILY_DD_PCT);
  if(m_daily_loss_usd + risk_usd > daily_stop) {
    block_reason = StringFormat("Trade risk $%.2f would exceed the $%.2f daily stop (current daily loss $%.2f + trade = $%.2f)",
      risk_usd, daily_stop, m_daily_loss_usd, m_daily_loss_usd + risk_usd);
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 8: Symbol validity
  if(!SymbolSelect(symbol, true)) {
    block_reason = StringFormat("Symbol %s not available for trading", symbol);
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // All gates pass
  LogDecision(symbol, "APPROVED: Signal passed all 8 gates", AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, false);
  return true;
}

//--- CalculateLotSize: USD risk -> lot size
double CRiskManager::CalculateLotSize(double risk_usd, double sl_pips, string symbol) {
  if(sl_pips <= 0) {
    Print("[RiskManager] ERROR: SL pips must be > 0");
    return 0.0;
  }

  if(risk_usd <= 0) {
    Print("[RiskManager] ERROR: Risk USD must be > 0");
    return 0.0;
  }

  // Ensure symbol is available
  if(!SymbolSelect(symbol, true)) {
    Print("[RiskManager] ERROR: Symbol not available: ", symbol);
    return 0.0;
  }

  double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
  double tick_val  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

  if(point <= 0.0 || tick_size <= 0.0 || tick_val <= 0.0) {
    Print("[RiskManager] ERROR: Invalid tick data for ", symbol,
          " point=", point, " tick_size=", tick_size, " tick_value=", tick_val);
    return 0.0;
  }

  // Pip size - JPY pairs quote to 3 decimals, others to 5
  double pip_size = point * 10.0;
  if(StringFind(symbol, "JPY") >= 0) pip_size = point * 100.0;

  // USD value of one pip for one lot
  double pip_value = tick_val * (pip_size / tick_size);
  if(pip_value <= 0.0) {
    Print("[RiskManager] ERROR: Computed pip value <= 0 for ", symbol);
    return 0.0;
  }

  // Cap the requested risk at the firm's per-trade ceiling
  double effective_risk = risk_usd;
  if(effective_risk > FP_MAX_TRADE_RISK_USD) {
    effective_risk = FP_MAX_TRADE_RISK_USD;
    Print("[RiskManager] Risk capped from $", risk_usd, " to $", FP_MAX_TRADE_RISK_USD);
  }

  // Broker volume constraints
  double min_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double max_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
  double step    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

  // One implementation of the sizing arithmetic, shared with the unit tests.
  double lot_size = LotsFromRisk(effective_risk, sl_pips, pip_value,
                                 step, min_lot, max_lot);

  if(lot_size <= 0.0) {
    Print("[RiskManager] WARNING: Calculated lot for $", effective_risk,
          " risk over ", sl_pips, " pips falls below the broker minimum ",
          min_lot, " - no trade");
    return 0.0;
  }

  Print("[RiskManager] CalculateLotSize: symbol=", symbol, " risk=$", effective_risk,
        " sl_pips=", sl_pips, " pip_value=$", pip_value, " -> lot=", lot_size);

  return lot_size;
}

//--- EvaluateRisk: the whole pre-trade decision in one call.
//    Sizing is derived from live equity rather than a fixed dollar figure, so
//    the position shrinks automatically as the account draws down instead of
//    holding a constant dollar risk against a shrinking cushion.
RiskStatus CRiskManager::EvaluateRisk(double sl_pips, string symbol) {
  RiskStatus st;

  if(symbol == "") symbol = _Symbol;

  double equity = AccountInfoDouble(ACCOUNT_EQUITY);

  st.currentDailyLoss = m_daily_loss_usd;
  st.dailyFloor       = GetDailyFloor();
  st.overallFloor     = m_overall_floor;

  if(sl_pips <= 0.0) {
    st.statusReason = "Stop distance is not positive - nothing to size against";
    return st;
  }

  // An offline terminal reads equity as 0.00. Sizing off that would compute a
  // zero budget and look like a risk decision rather than a missing connection.
  if(equity <= 0.0) {
    st.statusReason = "No account equity reading available";
    return st;
  }

  double daily_stop = EffectiveDailyStopUsd(m_day_anchor_equity, FP_DAILY_DD_PCT);
  double risk_usd   = RiskBudgetUsd(equity, FP_RISK_PER_TRADE_PCT,
                                    m_daily_loss_usd, daily_stop);

  st.riskUsd = risk_usd;

  if(risk_usd <= 0.0) {
    st.statusReason = StringFormat(
      "No risk budget left today (loss $%.2f of $%.2f allowance)",
      m_daily_loss_usd, daily_stop);
    return st;
  }

  string block_reason = "";
  if(!CanOpenTrade(sl_pips, risk_usd, symbol, block_reason)) {
    st.statusReason = block_reason;
    return st;
  }

  double lots = CalculateLotSize(risk_usd, sl_pips, symbol);
  if(lots <= 0.0) {
    st.statusReason = "Computed lot size rounds below the broker minimum";
    return st;
  }

  st.isTradingAllowed  = true;
  st.maxAllowedLotSize = lots;
  st.statusReason      = StringFormat(
    "OK | risk $%.2f (%.2f%% of $%.2f) | %.1f pip stop | %.2f lots",
    risk_usd, FP_RISK_PER_TRADE_PCT, equity, sl_pips, lots);

  return st;
}

//--- KillSwitch: Close all positions + remove EA
void CRiskManager::KillSwitch() {
  if(m_killed) return;  // Already killed

  m_killed = true;

  // Close all open positions with our magic number
  CTrade trade;
  int total = PositionsTotal();

  Print("[RiskManager] KillSwitch activated. Closing ", total, " positions.");

  for(int i = total - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if((ulong)PositionGetInteger(POSITION_MAGIC) == m_magic_number) {
      trade.PositionClose(ticket);
    }
  }

  Print("[RiskManager] EA removing itself from chart.");
  ExpertRemove();
}

//--- FridayFlatten: Close all before Friday 21:00 UTC
void CRiskManager::FridayFlatten() {
  if(!IsFridayFlatten()) return;

  CTrade trade;
  int total = PositionsTotal();

  if(total > 0) {
    Print("[RiskManager] Friday close-all: closing ", total, " positions before weekend.");
    for(int i = total - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if((ulong)PositionGetInteger(POSITION_MAGIC) == m_magic_number) {
        trade.PositionClose(ticket);
      }
    }
  }
}

//--- IsInsideSessionWindow: 07:00-17:00 UTC Monday-Friday
bool CRiskManager::IsInsideSessionWindow() {
  MqlDateTime dt;
  TimeToStruct(FpNowUtc(), dt);

  // Check day (1=Monday, 5=Friday)
  if(dt.day_of_week < 1 || dt.day_of_week > 5) return false;

  return HourInSession(dt.hour, m_session_open_hour, m_session_close_hour);
}

//--- IsFridayFlatten: Friday 20:00 UTC approaching?
bool CRiskManager::IsFridayFlatten() {
  MqlDateTime dt;
  TimeToStruct(FpNowUtc(), dt);

  return (dt.day_of_week == 5 && dt.hour >= FRIDAY_FLATTEN_HOUR);
}

//--- WriteCSVHeader: Initialize CSV log
void CRiskManager::WriteCSVHeader() {
  if(m_log_file == INVALID_HANDLE) return;
  FileSeek(m_log_file, 0, SEEK_END);
  FileWrite(m_log_file, "Time", "Symbol", "Decision", "Equity", "DailyLoss", "Blocked");
}

//--- LogDecision: Append to CSV log
void CRiskManager::LogDecision(string symbol, string decision, double equity, double daily_loss, bool blocked) {
  if(m_log_file == INVALID_HANDLE) return;

  string time_str = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
  string blocked_str = blocked ? "TRUE" : "FALSE";

  FileWrite(m_log_file, time_str, symbol, decision, DoubleToString(equity, 2),
            DoubleToString(daily_loss, 2), blocked_str);
  FileFlush(m_log_file);
}

#endif

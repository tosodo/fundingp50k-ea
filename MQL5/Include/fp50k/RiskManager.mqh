//+------------------------------------------------------------------+
//| RiskManager.mqh                                                   |
//| FP50K-EA · Risk Governor Layer 1                                  |
//| Enforces all FundingPips $50k 2-Step Flex rules                  |
//| 8-layer pre-trade gate, daily state machine, emergency kill       |
//+------------------------------------------------------------------+

#ifndef _RISKMANAGER_MQH_
#define _RISKMANAGER_MQH_

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//--- FundingPips Hard Limits (verified July 2026)
#define FP_INITIAL_BALANCE     50000.0
#define FP_EQUITY_FLOOR        44000.0
#define FP_DD_EMERGENCY_FLOOR  44500.0
#define FP_DAILY_HARD_STOP     1800.0
#define FP_DAILY_SOFT_STOP     1000.0
#define FP_MAX_TRADE_RISK_USD  1000.0

//--- Session Windows (UTC)
#define SESSION_OPEN_HOUR      7      // 07:00 UTC — London open
#define SESSION_CLOSE_HOUR     17     // 17:00 UTC — NY afternoon
#define FRIDAY_FLATTEN_HOUR    20     // 20:00 UTC Friday — close all before weekend
#define NEWS_BLOCK_MINUTES     5      // ±5 min red-folder event blackout

//--- Risk Manager States
enum RISK_STATE {
  RISK_OK = 0,           // All systems go
  RISK_SOFT_STOP = 1,    // Daily loss reached $1,000 soft-stop — no new entries
  RISK_HARD_STOP = 2,    // Daily loss reached $1,800 hard-stop — no new entries
  RISK_KILLED = 3        // Equity floor breached or emergency condition — EA halted
};

//--- CSV Log structure
struct SRiskLog {
  datetime time;
  string   symbol;
  string   decision;
  double   equity;
  double   daily_loss;
  bool     block;
};

class CRiskManager {
private:
  // State tracking
  RISK_STATE m_state;
  bool       m_killed;
  datetime   m_last_day;

  // Daily accumulator
  double     m_daily_loss_usd;
  double     m_starting_equity;

  // Log file
  int        m_log_file;
  string     m_log_filename;

  // Magic number for position filtering
  ulong      m_magic_number;

  // Helper methods
  bool   IsNewsBlackout(string symbol);
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

  // Getters
  RISK_STATE GetState() { return m_state; }
  bool       IsKilled() { return m_killed; }
  double     GetDailyLoss() { return m_daily_loss_usd; }
};

//--- Constructor
CRiskManager::CRiskManager() {
  m_state = RISK_OK;
  m_killed = false;
  m_last_day = 0;
  m_daily_loss_usd = 0.0;
  m_starting_equity = FP_INITIAL_BALANCE;
  m_log_file = -1;
  m_magic_number = 50001;
}

//--- Destructor
CRiskManager::~CRiskManager() {
  if(m_log_file != -1) {
    FileClose(m_log_file);
  }
}

//--- Init: Called once at EA start
bool CRiskManager::Init(double initial_balance, ulong magic) {
  m_starting_equity = initial_balance;
  m_daily_loss_usd = 0.0;
  m_state = RISK_OK;
  m_killed = false;
  m_last_day = TimeCurrent();
  m_magic_number = magic;

  // Create log file
  m_log_filename = StringFormat("Logs/risk_log_%04d%02d%02d.csv",
    TimeYear(TimeCurrent()), TimeMonth(TimeCurrent()), TimeDay(TimeCurrent()));

  m_log_file = FileOpen(m_log_filename, FILE_READ | FILE_WRITE | FILE_CSV);
  if(m_log_file != INVALID_HANDLE) {
    WriteCSVHeader();
    Print("[RiskManager] Initialized. Log: ", m_log_filename);
  } else {
    Print("[RiskManager] WARNING: Could not open log file: ", m_log_filename);
  }

  return true;
}

//--- OnNewDay: Called when date changes
void CRiskManager::OnNewDay() {
  datetime current_time = TimeCurrent();
  string current_date = TimeToString(current_time, TIME_DATE);
  string last_date = TimeToString(m_last_day, TIME_DATE);

  if(current_date != last_date) {
    m_daily_loss_usd = 0.0;
    m_state = RISK_OK;
    m_last_day = current_time;
    Print("[RiskManager] New trading day. Daily loss reset to $0.");
  }
}

//--- OnTick: State machine — called every tick
void CRiskManager::OnTick() {
  // Check for new day
  OnNewDay();

  // Check equity floor (absolute kill condition)
  if(AccountInfoDouble(ACCOUNT_EQUITY) < FP_DD_EMERGENCY_FLOOR) {
    Print("[RiskManager] EMERGENCY: Equity ", AccountInfoDouble(ACCOUNT_EQUITY),
          " below emergency floor ", FP_DD_EMERGENCY_FLOOR, ". Killing EA.");
    KillSwitch();
    return;
  }

  // Check daily loss accumulation
  double current_daily_loss = m_starting_equity - AccountInfoDouble(ACCOUNT_EQUITY);
  m_daily_loss_usd = current_daily_loss;

  if(m_daily_loss_usd >= FP_DAILY_HARD_STOP) {
    m_state = RISK_HARD_STOP;
    Print("[RiskManager] HARD STOP: Daily loss $", m_daily_loss_usd, " >= $",
          FP_DAILY_HARD_STOP, ". No new entries.");
  } else if(m_daily_loss_usd >= FP_DAILY_SOFT_STOP) {
    m_state = RISK_SOFT_STOP;
    Print("[RiskManager] SOFT STOP: Daily loss $", m_daily_loss_usd, " >= $",
          FP_DAILY_SOFT_STOP, ". No new entries.");
  } else {
    m_state = RISK_OK;
  }

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
    block_reason = StringFormat("State not OK (state=%d, daily_loss=$%.2f)", m_state, m_daily_loss_usd);
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
    block_reason = "Outside London session window (07:00-17:00 UTC)";
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 4: Equity floor
  if(AccountInfoDouble(ACCOUNT_EQUITY) < FP_DD_EMERGENCY_FLOOR) {
    block_reason = StringFormat("Equity $%.2f below emergency floor $%.2f",
      AccountInfoDouble(ACCOUNT_EQUITY), FP_DD_EMERGENCY_FLOOR);
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 5: News blackout
  if(IsNewsBlackout(symbol)) {
    block_reason = "High-impact news event within ±5 min";
    LogDecision(symbol, block_reason, AccountInfoDouble(ACCOUNT_EQUITY), m_daily_loss_usd, true);
    return false;
  }

  // Layer 5b: Spread gate
  long current_spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
  long max_spread = (StringFind(symbol, "XAU") >= 0) ? 50 :
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

  // Layer 7: Daily loss projection
  if(m_daily_loss_usd + risk_usd > FP_DAILY_HARD_STOP) {
    block_reason = StringFormat("Trade risk $%.2f would exceed hard stop (current daily loss $%.2f + trade = $%.2f)",
      risk_usd, m_daily_loss_usd, m_daily_loss_usd + risk_usd);
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

//--- CalculateLotSize: USD risk → lot size
double CRiskManager::CalculateLotSize(double risk_usd, double sl_pips, string symbol) {
  if(sl_pips <= 0) {
    Print("[RiskManager] ERROR: SL pips must be > 0");
    return 0.0;
  }

  if(risk_usd <= 0) {
    Print("[RiskManager] ERROR: Risk USD must be > 0");
    return 0.0;
  }

  // Get symbol info
  if(!SymbolInfoDouble(symbol, SYMBOL_BID)) {
    Print("[RiskManager] ERROR: Cannot get price for ", symbol);
    return 0.0;
  }

  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

  // Adjust for JPY pairs (100x pip size)
  double pip_size = point * 10;
  if(StringFind(symbol, "JPY") >= 0) {
    pip_size = point * 100;
  }

  // Get tick value (USD per pip)
  double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

  // Lot size = risk_usd / (sl_pips × tick_value)
  double lot_size = risk_usd / (sl_pips * tick_value);

  // Cap at hard limit
  double max_lot = FP_MAX_TRADE_RISK_USD / (sl_pips * tick_value);
  if(lot_size > max_lot) {
    lot_size = max_lot;
    Print("[RiskManager] Lot size capped to $", FP_MAX_TRADE_RISK_USD, " max risk");
  }

  // Get min/max lot from symbol
  double min_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double max_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
  double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

  if(lot_size < min_lot) {
    Print("[RiskManager] WARNING: Calculated lot ", lot_size, " below minimum ", min_lot);
    return 0.0;
  }

  if(lot_size > max_volume) {
    lot_size = max_volume;
    Print("[RiskManager] Lot size capped to max ", max_volume);
  }

  // Round to step
  lot_size = MathFloor(lot_size / step) * step;

  Print("[RiskManager] CalculateLotSize: symbol=", symbol, " risk=$", risk_usd,
        " sl_pips=", sl_pips, " → lot=", lot_size);

  return lot_size;
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
    if(PositionGetInteger(POSITION_MAGIC) == m_magic_number) {
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
      if(PositionGetInteger(POSITION_MAGIC) == m_magic_number) {
        trade.PositionClose(ticket);
      }
    }
  }
}

//--- IsNewsBlackout: Check CalendarValueHistory for high-impact events
bool CRiskManager::IsNewsBlackout(string symbol) {
  // Extract currency from symbol (first 3 chars for base, 4-6 for quote)
  string base_curr = StringSubstr(symbol, 0, 3);
  string quote_curr = StringSubstr(symbol, 3, 3);

  datetime block_start = TimeCurrent() - NEWS_BLOCK_MINUTES * 60;
  datetime block_end = TimeCurrent() + NEWS_BLOCK_MINUTES * 60;

  // Query calendar for events
  MqlCalendarValue values[];
  int count = CalendarValueHistory(values, block_start, block_end);

  for(int i = 0; i < count; i++) {
    // Check if event currency matches symbol
    MqlCalendarEvent event;
    if(!CalendarEventById(values[i].event_id, event)) continue;

    if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

    // Match currency
    if(StringFind(event.currency, base_curr) >= 0 || StringFind(event.currency, quote_curr) >= 0) {
      Print("[RiskManager] NEWS BLACKOUT: ", event.name, " (", event.currency,
            ") at ", TimeToString(values[i].time), " — blocking entry");
      return true;
    }
  }

  return false;
}

//--- IsInsideSessionWindow: 07:00-17:00 UTC Monday-Friday
bool CRiskManager::IsInsideSessionWindow() {
  datetime gmt = TimeGMT();
  int hour = TimeHour(gmt);
  int day_of_week = TimeDayOfWeek(gmt);

  // Check day (1=Monday, 5=Friday)
  if(day_of_week < 1 || day_of_week > 5) return false;

  // Check hour (7 to 16, since 17 is outside)
  if(hour < SESSION_OPEN_HOUR || hour >= SESSION_CLOSE_HOUR) return false;

  return true;
}

//--- IsFridayFlatten: Friday 21:00 UTC approaching?
bool CRiskManager::IsFridayFlatten() {
  datetime gmt = TimeGMT();
  int day_of_week = TimeDayOfWeek(gmt);
  int hour = TimeHour(gmt);

  return (day_of_week == 5 && hour >= FRIDAY_FLATTEN_HOUR);
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

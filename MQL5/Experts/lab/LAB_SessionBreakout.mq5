//+------------------------------------------------------------------+
//| LAB_SessionBreakout.mq5                                          |
//| Strategy Lab | Hypothesis H2 - Asian Range Compression Breakout  |
//|                                                                  |
//| Purpose : Measure whether the first decisive break of an          |
//|           unusually narrow overnight range predicts direction     |
//|           well enough to beat its break-even win rate, once       |
//|           realistic costs are charged.                            |
//|                                                                   |
//| Why hours are GMT and not server time                             |
//|   MQL5 stamps every bar in the broker's server time, and brokers  |
//|   sit on different offsets and shift them at daylight saving. A   |
//|   session strategy with server hours hard-coded would measure a   |
//|   different session on a different feed - so the multi-broker     |
//|   robustness test would fail for a clock reason and be read as a  |
//|   strategy reason. The offset is therefore measured at runtime    |
//|   from TimeCurrent() against TimeGMT() and re-checked every bar,  |
//|   which also absorbs the DST changeover mid-backtest.             |
//|                                                                   |
//| DELIBERATELY NOT INCLUDED: the prop-firm risk governor, the daily |
//| stop, the news filter, break-even moves, partial closes and       |
//| trailing stops - same reasoning as H1. Each trade is a flat-sized |
//| bet so the win rate answers the question being asked. Compliance  |
//| is a SECOND gate, applied only to survivors.                      |
//|                                                                   |
//| The end-of-day flat at 20:00 GMT is NOT trade management. It is   |
//| part of the hypothesis: the claim is about a move that develops   |
//| during the London and New York sessions, so a position still open |
//| at the end of them has had its question answered.                 |
//|                                                                   |
//| This EA places no live orders: it is run only under the Strategy  |
//| Tester by run_lab.sh. Attaching it to a chart is a manual step    |
//| and is never performed automatically.                             |
//|                                                                   |
//| Author  : Tee (aigentforce.io)                                   |
//| Project : Strategy Lab (built on the FP50K-EA framework)          |
//+------------------------------------------------------------------+
#property copyright "Tee - aigentforce.io"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <lab\SessionBreakout.mqh>

//--- Structure (all hours GMT) -------------------------------------
input ENUM_TIMEFRAMES InpEntryTF      = PERIOD_M15;  // Entry timeframe
input int             InpAsiaStart    = 0;          // Overnight range opens (GMT)
input int             InpAsiaEnd      = 7;          // Overnight range closes (GMT)
input int             InpBreakStart   = 7;          // Breakout window opens (GMT)
input int             InpBreakEnd     = 12;         // Breakout window shuts (GMT)
input int             InpFlatHour     = 20;         // Flatten anything still open (GMT)
input int             InpAvgDays      = 20;         // Days in compression benchmark
input double          InpRRRatio      = 2.0;        // Reward : risk

//--- Where the stop goes ------------------------------------------
// 1 = the opposite side of the overnight range (H3). This is the
//     current hypothesis. The level comes from the setup itself, so
//     there is no parameter to choose.
// 0 = 1.5 x ATR (H2). Retained ONLY so the rejected H2 run stays
//     reproducible from the same binary. It was rejected because on
//     M15 it produced ~5 pip stops against 2 pips of cost, which no
//     entry signal can overcome. Do not use it for new work.
input int             InpStopMode     = 1;          // 1 = range stop, 0 = ATR stop
input int             InpAtrPeriod    = 20;         // ATR period (mode 0 only)
input double          InpAtrStopMult  = 1.5;        // Stop = N x ATR (mode 0 only)

//--- Sizing --------------------------------------------------------
// Flat percentage of the STARTING deposit, not of live equity, so
// every trade is the same dollar size and the profit series is a
// clean run of R multiples.
input double          InpRiskPct      = 1.0;        // Risk % of starting deposit

//--- Costs ---------------------------------------------------------
input double          InpSlippagePips = 0.5;        // Slippage charged per entry
input double          InpMaxSpreadPips= 3.0;        // Skip entry above this spread

//--- Bookkeeping ---------------------------------------------------
input int             InpMagic        = 60002;      // Magic number
input string          InpRunTag       = "h2";       // Tag for the trade export

CTrade   g_trade;
int      g_h_atr       = INVALID_HANDLE;
datetime g_last_bar    = 0;
double   g_pip         = 0.0;
double   g_risk_usd    = 0.0;
bool     g_in_tester   = false;

//--- Stop width at entry, kept per position so the export can report it.
//    The trade history records where the stop WAS, not how wide it was in pips
//    at the moment of the fill, and that width is what decides whether costs
//    were a rounding error or a third of the risk. H2 was lost to a stop width
//    nobody had written down; this makes it a column instead of an inference.
long     g_ent_pid[];
double   g_ent_slp[];

//--- Session state
int      g_gmt_offset  = 0;
bool     g_offset_seen = false;
long     g_day_id      = -1;
double   g_range_hi    = 0.0;
double   g_range_lo    = 0.0;
bool     g_traded_today= false;
bool     g_counted_today= false;

//--- Compression benchmark: a ring of the last InpAvgDays ranges.
double   g_hist[];
int      g_hist_count  = 0;
int      g_hist_idx    = 0;

//--- Counters, printed at the end so a null result is explainable.
int      g_days        = 0;
int      g_compressed  = 0;
int      g_signals     = 0;
int      g_entries     = 0;
int      g_time_exits  = 0;

//+------------------------------------------------------------------+
//| Pip size. A 5-digit or 3-digit quote prices in tenths of a pip,   |
//| so one pip is ten points; on a 4-digit or 2-digit feed a point IS |
//| the pip. Getting this wrong scales every stop by ten.             |
//+------------------------------------------------------------------+
double PipSize(string symbol) {
  int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
  return (digits == 5 || digits == 3) ? point * 10.0 : point;
}

//--- Money made or lost per pip on one lot.
double PipValue(string symbol, double pip) {
  double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
  double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
  if(tick_size <= 0.0) return 0.0;
  return tick_value * (pip / tick_size);
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit() {
  g_in_tester = (MQLInfoInteger(MQL_TESTER) != 0);

  // The day-grouping below buckets bars by GMT calendar day, which is
  // only correct while the range window sits inside one day. A window
  // that wrapped midnight would be split across two buckets and the
  // range would be silently wrong rather than obviously broken.
  if(InpAsiaStart >= InpAsiaEnd) {
    Print("[LAB] FATAL: the overnight range window must not wrap midnight ",
          "(InpAsiaStart ", InpAsiaStart, " >= InpAsiaEnd ", InpAsiaEnd, ").");
    return INIT_FAILED;
  }
  if(InpBreakStart >= InpBreakEnd || InpBreakEnd > InpFlatHour) {
    Print("[LAB] FATAL: breakout window and flatten hour are inconsistent.");
    return INIT_FAILED;
  }
  if(InpAvgDays < 2) {
    Print("[LAB] FATAL: InpAvgDays must be at least 2.");
    return INIT_FAILED;
  }
  if(InpStopMode != 0 && InpStopMode != 1) {
    Print("[LAB] FATAL: InpStopMode must be 1 (range stop) or 0 (ATR stop).");
    return INIT_FAILED;
  }

  g_h_atr = iATR(_Symbol, InpEntryTF, InpAtrPeriod);
  if(g_h_atr == INVALID_HANDLE) {
    Print("[LAB] FATAL: ATR handle failed to create.");
    return INIT_FAILED;
  }

  g_pip = PipSize(_Symbol);
  if(g_pip <= 0.0) {
    Print("[LAB] FATAL: could not determine pip size for ", _Symbol);
    return INIT_FAILED;
  }

  ArrayResize(g_hist, InpAvgDays);
  ArrayInitialize(g_hist, 0.0);
  g_hist_count = 0;
  g_hist_idx   = 0;

  double deposit = AccountInfoDouble(ACCOUNT_BALANCE);
  if(deposit <= 0.0) deposit = 50000.0;
  g_risk_usd = deposit * InpRiskPct / 100.0;

  g_trade.SetExpertMagicNumber((ulong)InpMagic);
  g_trade.SetTypeFillingBySymbol(_Symbol);
  g_trade.SetDeviationInPoints(20);

  Print("[LAB] SessionBreakout | ", _Symbol, " | ", EnumToString(InpEntryTF),
        " | range ", InpAsiaStart, ":00-", InpAsiaEnd, ":00 GMT",
        " | break ", InpBreakStart, ":00-", InpBreakEnd, ":00 GMT",
        " | flat ", InpFlatHour, ":00 GMT");
  string stop_desc = (InpStopMode == 1)
      ? "far side of the range"
      : (DoubleToString(InpAtrStopMult, 1) + "xATR(" + IntegerToString(InpAtrPeriod) + ")");
  Print("[LAB] Compression: range < ", InpAvgDays, "-day average",
        " | stop ", stop_desc,
        " | RR ", DoubleToString(InpRRRatio, 1),
        " | risk $", DoubleToString(g_risk_usd, 2));
  Print("[LAB] Break-even win rate at this RR: ",
        DoubleToString(LabBreakEvenWinPct(InpRRRatio), 2), "%");
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if(g_h_atr != INVALID_HANDLE) IndicatorRelease(g_h_atr);

  Print("[LAB] Days seen: ", g_days, " | compressed: ", g_compressed,
        " | signals: ", g_signals, " | entries: ", g_entries,
        " | closed on time: ", g_time_exits);
  if(g_in_tester) ExportTrades();
}

//+------------------------------------------------------------------+
//| Is a position of ours already open? One at a time, always.        |
//| Structural, not a tuned limit: overlapping trades in the same     |
//| direction are one bet held twice, and they would make the         |
//| per-trade series statistically dependent, which breaks the test.  |
//+------------------------------------------------------------------+
bool HasOpenPosition() {
  for(int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if(ticket == 0) continue;
    if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
    if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
    return true;
  }
  return false;
}

void CloseOurPositions() {
  for(int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if(ticket == 0) continue;
    if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
    if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
    if(g_trade.PositionClose(ticket)) g_time_exits++;
    else Print("[LAB] Time exit FAILED | retcode ", g_trade.ResultRetcode());
  }
}

//--- One indicator value, from a closed bar.
bool ReadBuffer(int handle, int shift, double &out) {
  double buf[];
  if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return false;
  out = buf[0];
  return (out > 0.0);
}

//--- Record a finished overnight range into the rolling benchmark.
void PushRange(double range) {
  if(range <= 0.0) return;
  g_hist[g_hist_idx] = range;
  g_hist_idx = (g_hist_idx + 1) % InpAvgDays;
  if(g_hist_count < InpAvgDays) g_hist_count++;
}

//+------------------------------------------------------------------+
//| OnTick - all decisions are taken on closed bars only              |
//|                                                                   |
//| Reading bar 1 rather than bar 0 everywhere is what keeps this      |
//| honest. Bar 0 is still forming: its high, low and close change     |
//| after a decision would have been made, which is lookahead by       |
//| accident and the single most common way a backtest lies.           |
//+------------------------------------------------------------------+
void OnTick() {
  datetime bar_time = iTime(_Symbol, InpEntryTF, 0);
  if(bar_time == 0 || bar_time == g_last_bar) return;
  g_last_bar = bar_time;

  //--- Server clock to GMT, re-measured every bar so the DST shift is
  //--- picked up in the middle of a backtest rather than ignored.
  int offset = SbGmtOffsetSeconds(TimeCurrent(), TimeGMT());
  if(!g_offset_seen || offset != g_gmt_offset) {
    Print("[LAB] Server clock is GMT", (offset >= 0 ? "+" : ""), offset / 3600,
          " as of ", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
    g_gmt_offset  = offset;
    g_offset_seen = true;
  }

  datetime bar_srv = iTime(_Symbol, InpEntryTF, 1);
  if(bar_srv == 0) return;
  datetime bar_gmt = (datetime)((long)bar_srv - g_gmt_offset);

  MqlDateTime dt;
  TimeToStruct(bar_gmt, dt);
  int  hour   = dt.hour;
  long day_id = (long)bar_gmt / 86400;

  //--- New GMT day: bank yesterday's range, then start clean.
  if(day_id != g_day_id) {
    if(g_range_hi > 0.0 && g_range_lo > 0.0 && g_range_hi > g_range_lo)
      PushRange(g_range_hi - g_range_lo);
    g_day_id        = day_id;
    g_range_hi      = 0.0;
    g_range_lo      = 0.0;
    g_traded_today  = false;
    g_counted_today = false;
    g_days++;
  }

  //--- Anything still open outside the trading day is closed. The
  //--- hypothesis is about a move that develops during London and New
  //--- York; past that, the question has been answered either way.
  if(HasOpenPosition()) {
    if(hour < InpBreakStart || hour >= InpFlatHour) CloseOurPositions();
    return;                                   // one position at a time
  }

  //--- Build the overnight range.
  if(SbInAsianSession(hour)) {
    double hi = iHigh(_Symbol, InpEntryTF, 1);
    double lo = iLow(_Symbol,  InpEntryTF, 1);
    if(hi > 0.0 && lo > 0.0) {
      if(g_range_hi <= 0.0 || hi > g_range_hi) g_range_hi = hi;
      if(g_range_lo <= 0.0 || lo < g_range_lo) g_range_lo = lo;
    }
    return;
  }

  if(!SbInBreakoutWindow(hour)) return;
  if(g_traded_today)            return;
  if(g_range_hi <= 0.0 || g_range_lo <= 0.0) return;   // no overnight data

  //--- The benchmark must be full before it means anything. A partial
  //--- average would call the first few days compressed at random.
  if(g_hist_count < InpAvgDays) return;

  double range = g_range_hi - g_range_lo;
  double avg   = SbAverage(g_hist, g_hist_count);
  if(!SbIsCompressed(range, avg)) return;

  // Once per DAY, not once per bar. Gating on the hour instead counted
  // every M15 bar inside 07:00 and reported four times as many
  // compressed days as there were days - visibly impossible, which is
  // the only reason it was caught. Diagnostics that cannot be wrong
  // out loud are worse than no diagnostics.
  if(!g_counted_today) { g_compressed++; g_counted_today = true; }

  double bar_close = iClose(_Symbol, InpEntryTF, 1);
  LAB_DIR dir = SbBreakoutDir(bar_close, g_range_hi, g_range_lo);
  if(dir == LAB_NONE) return;

  //--- One attempt per day, taken or missed. Retrying after a blocked
  //--- entry would sample the same setup repeatedly and inflate N.
  g_traded_today = true;
  g_signals++;

  //--- Cost gate. A signal taken at a spread the strategy cannot pay
  //--- for is not a trade, it is a donation.
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  if(ask <= 0.0 || bid <= 0.0) return;
  double spread_pips = (ask - bid) / g_pip;
  if(spread_pips > InpMaxSpreadPips) {
    Print("[LAB] Signal skipped: spread ", DoubleToString(spread_pips, 2),
          " pips above the ", DoubleToString(InpMaxSpreadPips, 2), " limit.");
    return;
  }

  LabSignal sig;
  if(InpStopMode == 1) {
    sig = SbBuildRangeSignal(dir, ask, bid, g_range_hi, g_range_lo,
                             g_pip, InpRRRatio, InpSlippagePips);
  } else {
    double atr = 0.0;
    if(!ReadBuffer(g_h_atr, 1, atr)) return;
    sig = LabBuildSignal(dir, ask, bid, atr, g_pip,
                         InpAtrStopMult, InpRRRatio, InpSlippagePips);
  }
  if(sig.dir == LAB_NONE) {
    Print("[LAB] Signal rejected: ", sig.reason);
    return;
  }

  double pip_value = PipValue(_Symbol, g_pip);
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double lots = LabLotsFromRisk(g_risk_usd, sig.sl_pips, pip_value, step, vmin, vmax);
  if(lots <= 0.0) {
    Print("[LAB] Signal rejected: computed lot size is below the broker minimum.");
    return;
  }

  int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  double sl = NormalizeDouble(sig.stop_loss,   digits);
  double tp = NormalizeDouble(sig.take_profit, digits);
  bool   is_long = (dir == LAB_LONG);

  bool ok = is_long ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, "SB-long")
                    : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, "SB-short");
  if(!ok) {
    Print("[LAB] Order REJECTED | retcode ", g_trade.ResultRetcode(),
          " | ", g_trade.ResultRetcodeDescription());
    return;
  }

  g_entries++;

  // Position id, so the width can be matched to the result later. Read it from
  // the deal rather than assuming the order ticket doubles as the position id.
  long pid = 0;
  ulong deal = g_trade.ResultDeal();
  if(deal > 0 && HistoryDealSelect(deal))
    pid = (long)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
  if(pid == 0) pid = (long)g_trade.ResultOrder();
  if(pid > 0) {
    int ei = ArraySize(g_ent_pid);
    ArrayResize(g_ent_pid, ei + 1); g_ent_pid[ei] = pid;
    ArrayResize(g_ent_slp, ei + 1); g_ent_slp[ei] = sig.sl_pips;
  }

  Print("[LAB] ENTRY ", (is_long ? "LONG " : "SHORT"),
        " | ", TimeToString(bar_gmt, TIME_DATE | TIME_MINUTES), " GMT",
        " | range ", DoubleToString(range / g_pip, 1), " pips vs avg ",
        DoubleToString(avg / g_pip, 1),
        " | lots ", DoubleToString(lots, 2),
        " | stop ", DoubleToString(sig.sl_pips, 1), " pips");
}

//+------------------------------------------------------------------+
//| ExportTrades                                                      |
//|                                                                   |
//| Writes one row per CLOSED position: the realised result in dollars |
//| and in R multiples. The statistics are computed outside MQL5 from  |
//| this file, so the significance test is run on the trades that      |
//| actually happened rather than on a summary the tester chose to     |
//| print. Costs are included - profit here is net of swap and         |
//| commission, not gross.                                             |
//+------------------------------------------------------------------+
//--- Stop width recorded at entry for this position. Returns 0 when the
//    position is not ours or the id was never captured; the export writes that
//    through as 0.0 rather than guessing a plausible width.
double EntryStopPips(long pid) {
  for(int i = 0; i < ArraySize(g_ent_pid); i++)
    if(g_ent_pid[i] == pid) return g_ent_slp[i];
  return 0.0;
}

void ExportTrades() {
  if(!HistorySelect(0, TimeCurrent())) {
    Print("[LAB] ERROR: could not select trade history for export.");
    return;
  }

  int total = HistoryDealsTotal();
  long   ids[];    ArrayResize(ids, 0);
  double pnl[];    ArrayResize(pnl, 0);
  long   closed[]; ArrayResize(closed, 0);

  for(int i = 0; i < total; i++) {
    ulong ticket = HistoryDealGetTicket(i);
    if(ticket == 0) continue;
    if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;

    long type = HistoryDealGetInteger(ticket, DEAL_TYPE);
    if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;

    long pid = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
    double p = HistoryDealGetDouble(ticket, DEAL_PROFIT)
             + HistoryDealGetDouble(ticket, DEAL_SWAP)
             + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

    int idx = -1;
    for(int k = 0; k < ArraySize(ids); k++) { if(ids[k] == pid) { idx = k; break; } }
    if(idx < 0) {
      idx = ArraySize(ids);
      ArrayResize(ids,    idx + 1);  ids[idx]    = pid;
      ArrayResize(pnl,    idx + 1);  pnl[idx]    = 0.0;
      ArrayResize(closed, idx + 1);  closed[idx] = 0;
    }
    pnl[idx] += p;

    long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
    if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      closed[idx] = (long)HistoryDealGetInteger(ticket, DEAL_TIME);
  }

  string path = "lab_trades_" + InpRunTag + ".csv";
  int fh = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
  if(fh == INVALID_HANDLE) {
    Print("[LAB] ERROR: could not open ", path, " for writing. Code ", GetLastError());
    return;
  }

  FileWrite(fh, "n", "close_time", "profit_usd", "r_multiple", "sl_pips");
  int n = 0;
  for(int k = 0; k < ArraySize(ids); k++) {
    if(closed[k] == 0) continue;          // still open: not a completed bet
    n++;
    double r = (g_risk_usd > 0.0) ? pnl[k] / g_risk_usd : 0.0;
    FileWrite(fh, n,
              TimeToString((datetime)closed[k], TIME_DATE | TIME_MINUTES),
              DoubleToString(pnl[k], 2),
              DoubleToString(r, 4),
              DoubleToString(EntryStopPips(ids[k]), 1));
  }
  FileClose(fh);
  Print("[LAB] Exported ", n, " closed trades to Common\\Files\\", path,
        " | risk per trade $", DoubleToString(g_risk_usd, 2));
}

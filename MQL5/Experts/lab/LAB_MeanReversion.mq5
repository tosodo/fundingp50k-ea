//+------------------------------------------------------------------+
//| LAB_MeanReversion.mq5                                            |
//| Strategy Lab | Hypothesis H4 - Overextension Fade                |
//|                                                                  |
//| Purpose : Measure whether fading a close that has stretched far   |
//|           from its own recent mean beats the break-even win rate  |
//|           implied by its geometry, once real costs are charged.   |
//|                                                                   |
//| Why H1 bars and not M15                                           |
//|   H2 died because a 1.5 x ATR stop on M15 EURUSD came to about    |
//|   five pips against two pips of cost, which made the trade        |
//|   arithmetically unwinnable before any signal was considered.     |
//|   On H1 bars ATR(20) is roughly three times larger, so a 2.0 ATR  |
//|   stop is tens of pips and costs fall to well under a tenth of    |
//|   the risk. The timeframe is a consequence of the cost            |
//|   arithmetic, not a setting that was tried until it worked.       |
//|                                                                   |
//| Why hours are GMT and not server time                             |
//|   Same reason as H2/H3: brokers sit on different offsets and      |
//|   shift at daylight saving, so hard-coded server hours would      |
//|   measure a different session on a different feed and corrupt the |
//|   multi-broker robustness test. The offset is measured at runtime |
//|   from TimeCurrent() against TimeGMT().                           |
//|                                                                   |
//| DELIBERATELY NOT INCLUDED: the prop-firm risk governor, the daily |
//| stop, the news filter, break-even moves, partial closes and       |
//| trailing stops - same reasoning as H1-H3. Each trade is a         |
//| flat-sized bet so the win rate answers the question being asked.  |
//| Compliance is a SECOND gate, applied only to survivors.           |
//|                                                                   |
//| The 24-bar holding limit is NOT trade management. It is part of   |
//| the hypothesis: the claim is that an overextension reverts within |
//| about a day, so a position still open after a day of bars has     |
//| had its question answered and its outcome is a real result.       |
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
#include <lab\MeanReversion.mqh>

//--- Structure ------------------------------------------------------
input ENUM_TIMEFRAMES InpEntryTF      = PERIOD_H1;   // Entry timeframe
input int             InpMaPeriod     = 20;         // Bars in the mean
input int             InpAtrPeriod    = 20;         // Bars in the ATR
input double          InpEntryAtr     = 2.0;        // Overextended at N x ATR from mean
input double          InpStopAtr      = 2.0;        // Stop = N x ATR beyond the fill
input int             InpHoldBars     = 24;         // Give up after N bars
input int             InpHourStart    = 7;          // Entries allowed from (GMT)
input int             InpHourEnd      = 20;         // Entries allowed until (GMT)

//--- Sizing --------------------------------------------------------
// Flat percentage of the STARTING deposit, not of live equity, so
// every trade is the same dollar size and the profit series is a
// clean run of R multiples.
input double          InpRiskPct      = 1.0;        // Risk % of starting deposit

//--- Costs ---------------------------------------------------------
input double          InpSlippagePips = 0.5;        // Slippage charged per entry
input double          InpMaxSpreadPips= 3.0;        // Skip entry above this spread

//--- Bookkeeping ---------------------------------------------------
input int             InpMagic        = 60003;      // Magic number
input string          InpRunTag       = "h4";       // Tag for the trade export

CTrade   g_trade;
int      g_h_atr       = INVALID_HANDLE;
int      g_h_ma        = INVALID_HANDLE;
datetime g_last_bar    = 0;
double   g_pip         = 0.0;
double   g_risk_usd    = 0.0;
bool     g_in_tester   = false;

//--- Stop width at entry, kept per position so the export can report it.
//    H2 was lost to a stop width nobody had written down; this makes it
//    a column in the results instead of something to be inferred later.
long     g_ent_pid[];
double   g_ent_slp[];

//--- Session state
int      g_gmt_offset  = 0;
bool     g_offset_seen = false;

//--- Open-trade state. Bars held is counted in entry-timeframe bars
//    rather than in clock time, so a weekend gap does not silently
//    expire a position that has only seen a handful of bars.
int      g_bars_held   = 0;

//--- Counters, printed at the end so a null result is explainable.
int      g_bars_seen   = 0;
int      g_stretched   = 0;
int      g_signals     = 0;
int      g_entries     = 0;
int      g_time_exits  = 0;
int      g_skip_hour   = 0;
int      g_skip_spread = 0;

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

  if(InpMaPeriod < 2 || InpAtrPeriod < 2) {
    Print("[LAB] FATAL: mean and ATR periods must both be at least 2.");
    return INIT_FAILED;
  }
  if(InpEntryAtr <= 0.0 || InpStopAtr <= 0.0) {
    Print("[LAB] FATAL: entry and stop ATR multiples must both be positive.");
    return INIT_FAILED;
  }
  if(InpHoldBars < 1) {
    Print("[LAB] FATAL: InpHoldBars must be at least 1.");
    return INIT_FAILED;
  }
  // A wrapped entry window is legal arithmetic but nothing here needs one,
  // and allowing it would make the "realism, not filter" argument harder to
  // check by eye. Refuse rather than quietly accept.
  if(InpHourStart >= InpHourEnd) {
    Print("[LAB] FATAL: the entry window must not wrap midnight ",
          "(InpHourStart ", InpHourStart, " >= InpHourEnd ", InpHourEnd, ").");
    return INIT_FAILED;
  }

  g_h_atr = iATR(_Symbol, InpEntryTF, InpAtrPeriod);
  g_h_ma  = iMA(_Symbol, InpEntryTF, InpMaPeriod, 0, MODE_SMA, PRICE_CLOSE);
  if(g_h_atr == INVALID_HANDLE || g_h_ma == INVALID_HANDLE) {
    Print("[LAB] FATAL: indicator handle failed to create.");
    return INIT_FAILED;
  }

  g_pip = PipSize(_Symbol);
  if(g_pip <= 0.0) {
    Print("[LAB] FATAL: could not determine pip size for ", _Symbol);
    return INIT_FAILED;
  }

  double deposit = AccountInfoDouble(ACCOUNT_BALANCE);
  if(deposit <= 0.0) deposit = 50000.0;
  g_risk_usd = deposit * InpRiskPct / 100.0;

  g_trade.SetExpertMagicNumber((ulong)InpMagic);
  g_trade.SetTypeFillingBySymbol(_Symbol);
  g_trade.SetDeviationInPoints(20);

  Print("[LAB] MeanReversion | ", _Symbol, " | ", EnumToString(InpEntryTF),
        " | mean SMA(", InpMaPeriod, ") | ATR(", InpAtrPeriod, ")");
  Print("[LAB] Fade a close ", DoubleToString(InpEntryAtr, 1),
        " ATR from the mean | stop ", DoubleToString(InpStopAtr, 1),
        " ATR | target the mean | hold <= ", InpHoldBars, " bars");
  Print("[LAB] Entries ", InpHourStart, ":00-", InpHourEnd, ":00 GMT",
        " | risk $", DoubleToString(g_risk_usd, 2));
  // The reward is set by the distance to the mean, so the break-even win
  // rate is not a constant here. At the entry threshold the geometry is
  // about entry_atr : stop_atr, which is what this prints - the realised
  // figure per trade is recorded in the export.
  Print("[LAB] Nominal RR at the threshold: ",
        DoubleToString(InpEntryAtr / InpStopAtr, 2),
        " -> break-even win rate ",
        DoubleToString(LabBreakEvenWinPct(InpEntryAtr / InpStopAtr), 2), "%");
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if(g_h_atr != INVALID_HANDLE) IndicatorRelease(g_h_atr);
  if(g_h_ma  != INVALID_HANDLE) IndicatorRelease(g_h_ma);

  Print("[LAB] Bars seen: ", g_bars_seen, " | stretched: ", g_stretched,
        " | signals: ", g_signals, " | entries: ", g_entries,
        " | closed on time: ", g_time_exits,
        " | skipped (hour): ", g_skip_hour,
        " | skipped (spread): ", g_skip_spread);
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

//+------------------------------------------------------------------+
//| OnTick - decisions on closed bars only.                           |
//|                                                                   |
//| Bar 0 is still forming: its close will change. Reading it would   |
//| be lookahead by accident, which is the most common way a backtest |
//| reports an edge that does not exist. Everything here reads bar 1. |
//+------------------------------------------------------------------+
void OnTick() {
  datetime bar_time = iTime(_Symbol, InpEntryTF, 0);
  if(bar_time == 0 || bar_time == g_last_bar) return;
  g_last_bar = bar_time;
  g_bars_seen++;

  int offset = SbLikeGmtOffset(TimeCurrent(), TimeGMT());
  if(!g_offset_seen || offset != g_gmt_offset) {
    Print("[LAB] Server clock is GMT", (offset >= 0 ? "+" : ""),
          DoubleToString(offset / 3600.0, 1), " as of ",
          TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
    g_gmt_offset  = offset;
    g_offset_seen = true;
  }

  //--- A position is open: age it, and give up once the hypothesis has
  //    had its day. The stop and target are server-side, so they can
  //    already have closed it without this code running.
  if(HasOpenPosition()) {
    g_bars_held++;
    if(MrHoldExpired(g_bars_held, InpHoldBars)) CloseOurPositions();
    return;
  }
  g_bars_held = 0;

  datetime bar_srv = iTime(_Symbol, InpEntryTF, 1);
  if(bar_srv == 0) return;
  datetime bar_gmt = (datetime)((long)bar_srv - g_gmt_offset);
  MqlDateTime dt;
  TimeToStruct(bar_gmt, dt);

  double ma = 0.0, atr = 0.0;
  if(!ReadBuffer(g_h_ma,  1, ma))  return;
  if(!ReadBuffer(g_h_atr, 1, atr)) return;

  double bar_close = iClose(_Symbol, InpEntryTF, 1);
  if(bar_close <= 0.0) return;

  LAB_DIR dir = MrStretchDir(bar_close, ma, atr, InpEntryAtr);
  if(dir == LAB_NONE) return;
  g_stretched++;

  //--- Counted as stretched above, so the hour and spread skips below are
  //    visible as skips rather than disappearing into a lower signal count.
  if(!LabHourInWindow(dt.hour, InpHourStart, InpHourEnd)) { g_skip_hour++; return; }

  g_signals++;

  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  if(ask <= 0.0 || bid <= 0.0) return;
  double spread_pips = (ask - bid) / g_pip;
  if(spread_pips > InpMaxSpreadPips) {
    g_skip_spread++;
    return;
  }

  LabSignal sig = MrBuildSignal(dir, ask, bid, ma, atr, g_pip,
                                InpStopAtr, InpSlippagePips);
  if(sig.dir == LAB_NONE) {
    Print("[LAB] Signal rejected | ", sig.reason);
    return;
  }

  double pip_value = PipValue(_Symbol, g_pip);
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double lots = LabLotsFromRisk(g_risk_usd, sig.sl_pips, pip_value, step, vmin, vmax);
  if(lots <= 0.0) {
    Print("[LAB] Lot size came out at zero | stop ",
          DoubleToString(sig.sl_pips, 1), " pips");
    return;
  }

  int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  double sl = NormalizeDouble(sig.stop_loss,   digits);
  double tp = NormalizeDouble(sig.take_profit, digits);
  bool   is_long = (dir == LAB_LONG);

  bool ok = is_long ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, "MR-long")
                    : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, "MR-short");
  if(!ok) {
    Print("[LAB] Order REJECTED | retcode ", g_trade.ResultRetcode(),
          " | ", g_trade.ResultRetcodeDescription());
    return;
  }

  g_entries++;
  g_bars_held = 0;

  // Position id, so the stop width can be matched to the result later.
  // Read from the deal rather than assuming the order ticket doubles as it.
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
        " | stretch ", DoubleToString(MrStretchAtrs(bar_close, ma, atr), 2), " ATR",
        " | lots ", DoubleToString(lots, 2),
        " | stop ", DoubleToString(sig.sl_pips, 1), " pips",
        " | RR ", DoubleToString(MrRealisedRR(sig), 2));
}

//+------------------------------------------------------------------+
//| Server clock to GMT, rounded to the nearest hour.                 |
//|                                                                   |
//| Same arithmetic as SbGmtOffsetSeconds in SessionBreakout.mqh. It  |
//| is repeated here rather than shared because pulling it into       |
//| LabCore would make every hypothesis depend on a session concept   |
//| that only some of them use; the function is four lines and the    |
//| duplication is cheaper than the coupling.                         |
//+------------------------------------------------------------------+
int SbLikeGmtOffset(datetime server_now, datetime gmt_now) {
  if(server_now == 0 || gmt_now == 0) return 0;
  double diff = (double)((long)server_now - (long)gmt_now);
  return (int)(MathRound(diff / 3600.0) * 3600.0);
}

//--- Stop width recorded at entry for this position. Returns 0 when the
//    position is not ours or the id was never captured; the export writes
//    that through as 0.0 rather than guessing a plausible width.
double EntryStopPips(long pid) {
  for(int i = 0; i < ArraySize(g_ent_pid); i++)
    if(g_ent_pid[i] == pid) return g_ent_slp[i];
  return 0.0;
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

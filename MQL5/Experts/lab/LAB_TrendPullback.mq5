//+------------------------------------------------------------------+
//| LAB_TrendPullback.mq5                                            |
//| Strategy Lab | Hypothesis H1 - Trend Pullback Continuation       |
//|                                                                  |
//| Purpose : Measure whether the trend-pullback entry predicts       |
//|           direction well enough to beat its own break-even win    |
//|           rate, once realistic costs are charged.                 |
//|                                                                  |
//| DELIBERATELY NOT INCLUDED: the prop-firm risk governor, the daily |
//| stop, the news filter, the session window, break-even moves,      |
//| partial closes and trailing stops. Every one of those alters the  |
//| outcome of a trade AFTER the entry decision, so leaving them in   |
//| would mean measuring the manager instead of the signal. Each      |
//| trade here is a clean win-or-lose bet of the same size, which is  |
//| the only arrangement where the win rate answers the question      |
//| being asked. Compliance is a SECOND gate, applied to survivors.   |
//|                                                                  |
//| This EA places no live orders: it is run only under the Strategy  |
//| Tester by run_lab.sh. Attaching it to a chart is a manual step    |
//| and is never performed automatically.                             |
//|                                                                  |
//| Author  : Tee (aigentforce.io)                                   |
//| Project : Strategy Lab (built on the FP50K-EA framework)          |
//+------------------------------------------------------------------+
#property copyright "Tee - aigentforce.io"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <lab\TrendPullback.mqh>

//--- Structure -----------------------------------------------------
input ENUM_TIMEFRAMES InpEntryTF      = PERIOD_H1;   // Entry timeframe
input ENUM_TIMEFRAMES InpTrendTF      = PERIOD_H4;   // Regime timeframe
input int             InpEmaTrend     = 200;         // Regime EMA period
input int             InpEmaPullback  = 50;          // Pullback EMA period
input int             InpAtrPeriod    = 20;          // ATR period
input double          InpAtrStopMult  = 2.0;         // Stop = N x ATR
input double          InpRRRatio      = 2.0;         // Reward : risk

//--- Sizing --------------------------------------------------------
// A flat percentage of the STARTING deposit, not of live equity. That
// keeps every trade the same dollar size, so the profit series is a
// clean run of R multiples. Compounding would make late trades count
// for more than early ones and quietly distort the statistics.
input double          InpRiskPct      = 1.0;         // Risk % of starting deposit

//--- Costs ---------------------------------------------------------
input double          InpSlippagePips = 0.5;         // Slippage charged per entry
input double          InpMaxSpreadPips= 3.0;         // Skip entry above this spread

//--- Bookkeeping ---------------------------------------------------
input int             InpMagic        = 60001;       // Magic number
input string          InpRunTag       = "h1";        // Tag for the trade export

CTrade   g_trade;
int      g_h_ema_trend    = INVALID_HANDLE;
int      g_h_ema_pullback = INVALID_HANDLE;
int      g_h_atr          = INVALID_HANDLE;
datetime g_last_bar       = 0;
double   g_pip            = 0.0;
double   g_risk_usd       = 0.0;
bool     g_in_tester      = false;
int      g_signals        = 0;
int      g_entries        = 0;

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

  g_h_ema_trend    = iMA(_Symbol, InpTrendTF, InpEmaTrend,    0, MODE_EMA, PRICE_CLOSE);
  g_h_ema_pullback = iMA(_Symbol, InpEntryTF, InpEmaPullback, 0, MODE_EMA, PRICE_CLOSE);
  g_h_atr          = iATR(_Symbol, InpEntryTF, InpAtrPeriod);

  if(g_h_ema_trend == INVALID_HANDLE || g_h_ema_pullback == INVALID_HANDLE ||
     g_h_atr == INVALID_HANDLE) {
    Print("[LAB] FATAL: indicator handles failed to create.");
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

  Print("[LAB] TrendPullback | ", _Symbol,
        " | entry ", EnumToString(InpEntryTF), " trend ", EnumToString(InpTrendTF),
        " | EMA ", InpEmaPullback, "/", InpEmaTrend,
        " | stop ", DoubleToString(InpAtrStopMult, 1), "xATR(", InpAtrPeriod, ")",
        " | RR ", DoubleToString(InpRRRatio, 1),
        " | risk $", DoubleToString(g_risk_usd, 2));
  Print("[LAB] Break-even win rate at this RR: ",
        DoubleToString(TpBreakEvenWinPct(InpRRRatio), 2), "%");
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if(g_h_ema_trend    != INVALID_HANDLE) IndicatorRelease(g_h_ema_trend);
  if(g_h_ema_pullback != INVALID_HANDLE) IndicatorRelease(g_h_ema_pullback);
  if(g_h_atr          != INVALID_HANDLE) IndicatorRelease(g_h_atr);

  Print("[LAB] Signals fired: ", g_signals, " | entries sent: ", g_entries);
  if(g_in_tester) ExportTrades();
}

//+------------------------------------------------------------------+
//| Is a position of ours already open? One at a time, always.        |
//| This is a structural rule, not a tuned limit: overlapping trades  |
//| in the same direction are one bet held twice, and they would make |
//| the per-trade series statistically dependent.                     |
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

//--- One indicator value, from a closed bar.
bool ReadBuffer(int handle, int shift, double &out) {
  double buf[];
  if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return false;
  out = buf[0];
  return (out > 0.0);
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

  if(HasOpenPosition()) return;

  //--- Regime, from the last CLOSED higher-timeframe bar.
  double trend_ema = 0.0;
  if(!ReadBuffer(g_h_ema_trend, 1, trend_ema)) return;
  double trend_close = iClose(_Symbol, InpTrendTF, 1);
  TP_DIR regime = TpRegime(trend_close, trend_ema);
  if(regime == TP_NONE) return;

  //--- Pullback test, on the bar that has just closed.
  double pull_ema = 0.0, atr = 0.0;
  if(!ReadBuffer(g_h_ema_pullback, 1, pull_ema)) return;
  if(!ReadBuffer(g_h_atr, 1, atr)) return;

  double bar_high  = iHigh(_Symbol,  InpEntryTF, 1);
  double bar_low   = iLow(_Symbol,   InpEntryTF, 1);
  double bar_close = iClose(_Symbol, InpEntryTF, 1);
  if(bar_high <= 0.0 || bar_low <= 0.0 || bar_close <= 0.0) return;

  bool is_long = (regime == TP_LONG);
  if(!TpIsSignalBar(bar_high, bar_low, bar_close, pull_ema, is_long)) return;

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

  TPSignal sig = TpBuildSignal(regime, ask, bid, atr, g_pip,
                               InpAtrStopMult, InpRRRatio, InpSlippagePips);
  if(sig.dir == TP_NONE) {
    Print("[LAB] Signal rejected: ", sig.reason);
    return;
  }

  double pip_value = PipValue(_Symbol, g_pip);
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double lots = TpLotsFromRisk(g_risk_usd, sig.sl_pips, pip_value, step, vmin, vmax);
  if(lots <= 0.0) {
    Print("[LAB] Signal rejected: computed lot size is below the broker minimum.");
    return;
  }

  int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  double sl = NormalizeDouble(sig.stop_loss,   digits);
  double tp = NormalizeDouble(sig.take_profit, digits);

  bool ok = is_long ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, "TP-long")
                    : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, "TP-short");

  if(!ok) {
    Print("[LAB] Order REJECTED | retcode ", g_trade.ResultRetcode(),
          " | ", g_trade.ResultRetcodeDescription());
    return;
  }

  g_entries++;
  Print("[LAB] ENTRY ", (is_long ? "LONG " : "SHORT"),
        " | lots ", DoubleToString(lots, 2),
        " | stop ", DoubleToString(sig.sl_pips, 1), " pips",
        " | SL ", DoubleToString(sl, digits), " TP ", DoubleToString(tp, digits));
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

  FileWrite(fh, "n", "close_time", "profit_usd", "r_multiple");
  int n = 0;
  for(int k = 0; k < ArraySize(ids); k++) {
    if(closed[k] == 0) continue;          // still open: not a completed bet
    n++;
    double r = (g_risk_usd > 0.0) ? pnl[k] / g_risk_usd : 0.0;
    FileWrite(fh, n,
              TimeToString((datetime)closed[k], TIME_DATE | TIME_MINUTES),
              DoubleToString(pnl[k], 2),
              DoubleToString(r, 4));
  }
  FileClose(fh);
  Print("[LAB] Exported ", n, " closed trades to Common\\Files\\", path,
        " | risk per trade $", DoubleToString(g_risk_usd, 2));
}

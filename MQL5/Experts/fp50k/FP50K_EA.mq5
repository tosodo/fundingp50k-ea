//+------------------------------------------------------------------+
//| FP50K_EA.mq5                                                      |
//| FundingPips $50k 2-Step Flex - Main Expert Advisor                |
//| Autonomous Asian Range Breakout Strategy                          |
//| Author: Tee (aigentforce.io) | Built: July 2026                   |
//+------------------------------------------------------------------+
//
// Execution layer only. Every decision this file makes is subordinate to
// CRiskManager - it proposes, the risk governor disposes. Nothing here may
// open a position that CanOpenTrade() has not approved.
//
// Stops and targets are always sent to the broker with the order. There are
// no virtual stops anywhere in this EA: if the terminal, the VPS or the
// network dies mid-trade, the protective stop must still be sitting on the
// broker's server. That is not a preference, it is the difference between a
// bad day and a failed challenge.

#property copyright "Tee (aigentforce.io)"
#property version   "1.00"
#property strict

#include <fp50k\RiskManager.mqh>
#include <fp50k\SignalEngine.mqh>
#include <fp50k\NewsFilter.mqh>

//--- Risk
input double   InpRiskUSD       = 500.0;   // Risk per trade (USD)
input double   InpRRRatio       = 2.0;     // R:R ratio target
input int      InpMaxSpreadEUR  = 20;      // Max spread EURUSD (points)
input int      InpMaxSpreadGBP  = 25;      // Max spread GBPUSD (points)
//--- Strategy
input bool     InpTradeEURUSD   = true;    // Enable EURUSD
input bool     InpTradeGBPUSD   = true;    // Enable GBPUSD
//--- Trade management
input double   InpPartialPct    = 50.0;    // Partial close at 1R (% of position)
input double   InpAtrTrailMult  = 0.5;     // ATR multiple for trailing stop
input int      InpNewsCloseMin  = 3;       // Close open trades N min before news
//--- Execution
input int      InpEntryOffsetMs = 100;     // Entry time offset ms (0=disable)
input int      InpMagicNumber   = 50001;   // EA magic number

//--- Modules
CRiskManager  g_risk;
CSignalEngine g_signal_eur;
CSignalEngine g_signal_gbp;
CTrade        g_trade;

//--- Per-symbol new-bar tracking
datetime g_last_bar_eur = 0;
datetime g_last_bar_gbp = 0;

//--- ATR handles. iATR() returns a HANDLE in MQL5, not a value - the reading
//    comes from CopyBuffer(). Created once here rather than per tick, because
//    indicator handles are a finite resource and leak if recreated in a loop.
int g_atr_eur = INVALID_HANDLE;
int g_atr_gbp = INVALID_HANDLE;

//--- Tickets whose 1R partial close has already been taken
ulong g_partial_done[];

#define SYM_EUR "EURUSD"
#define SYM_GBP "GBPUSD"

//+------------------------------------------------------------------+
//| Partial-close bookkeeping                                        |
//+------------------------------------------------------------------+
bool IsPartialDone(ulong ticket) {
  for(int i = 0; i < ArraySize(g_partial_done); i++)
    if(g_partial_done[i] == ticket) return true;
  return false;
}

void MarkPartialDone(ulong ticket) {
  if(IsPartialDone(ticket)) return;
  int n = ArraySize(g_partial_done);
  ArrayResize(g_partial_done, n + 1);
  g_partial_done[n] = ticket;
}

//--- Drop tickets that are no longer open, so the list cannot grow without
//    bound over a multi-week challenge.
void PruneClosedTickets() {
  ulong still_open[];
  for(int i = 0; i < ArraySize(g_partial_done); i++) {
    if(PositionSelectByTicket(g_partial_done[i])) {
      int n = ArraySize(still_open);
      ArrayResize(still_open, n + 1);
      still_open[n] = g_partial_done[i];
    }
  }
  ArrayFree(g_partial_done);
  ArrayCopy(g_partial_done, still_open);
}

//--- Rebuild the partial-done list after a restart. A stop at or beyond entry
//    can only have got there by our own breakeven move, which happens exactly
//    once, immediately after the partial close. Without this, an EA restarted
//    mid-trade would take a second 50% off a position already halved.
void RecoverPartialState() {
  ArrayFree(g_partial_done);

  for(int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if(ticket == 0) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl    = PositionGetDouble(POSITION_SL);
    if(sl <= 0.0) continue;

    long type = PositionGetInteger(POSITION_TYPE);
    bool at_breakeven = (type == POSITION_TYPE_BUY)  ? (sl >= entry)
                                                     : (sl <= entry);
    if(at_breakeven) {
      MarkPartialDone(ticket);
      Print("[FP50K] Recovered state: ticket ", ticket,
            " already past 1R partial (stop at/beyond entry).");
    }
  }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool HasOpenPosition(string symbol) {
  for(int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if(ticket == 0) continue;
    if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
    return true;
  }
  return false;
}

double NormalizeLots(string symbol, double lots) {
  double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
  if(step <= 0.0) return 0.0;

  // Round DOWN - never size up into more risk than was approved.
  double v = MathFloor(lots / step) * step;
  if(v < vmin) return 0.0;
  if(v > vmax) v = vmax;
  return NormalizeDouble(v, 2);
}

double NormalizePrice(string symbol, double price) {
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  return NormalizeDouble(price, digits);
}

//--- Brokers reject stops closer to price than SYMBOL_TRADE_STOPS_LEVEL.
//    Checking here turns a silent order rejection into a logged, explained skip.
bool StopDistanceOk(string symbol, double price, double sl, double tp, string &why) {
  long   level  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
  double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if(level <= 0 || point <= 0.0) return true;

  double min_dist = level * point;

  if(MathAbs(price - sl) < min_dist) {
    why = StringFormat("Stop %.1f points from price, broker minimum is %d",
                       MathAbs(price - sl) / point, (int)level);
    return false;
  }
  if(tp > 0.0 && MathAbs(tp - price) < min_dist) {
    why = StringFormat("Target %.1f points from price, broker minimum is %d",
                       MathAbs(tp - price) / point, (int)level);
    return false;
  }
  return true;
}

int MaxSpreadFor(string symbol) {
  return (symbol == SYM_GBP) ? InpMaxSpreadGBP : InpMaxSpreadEUR;
}

double AtrValue(int handle) {
  if(handle == INVALID_HANDLE) return 0.0;
  double buf[];
  // Bar 1, not 0: the forming bar's ATR repaints tick by tick.
  if(CopyBuffer(handle, 0, 1, 1, buf) < 1) return 0.0;
  return buf[0];
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit() {
  if(InpRiskUSD <= 0.0 || InpRiskUSD > FP_MAX_TRADE_RISK_USD) {
    Print("[FP50K] FATAL: InpRiskUSD $", InpRiskUSD,
          " outside permitted range $0-$", FP_MAX_TRADE_RISK_USD, ". Refusing to start.");
    return INIT_PARAMETERS_INCORRECT;
  }
  if(!InpTradeEURUSD && !InpTradeGBPUSD) {
    Print("[FP50K] FATAL: no symbols enabled. Refusing to start.");
    return INIT_PARAMETERS_INCORRECT;
  }

  if(!g_risk.Init(FP_INITIAL_BALANCE, (ulong)InpMagicNumber)) {
    Print("[FP50K] FATAL: RiskManager failed to initialise.");
    return INIT_FAILED;
  }

  if(InpTradeEURUSD) {
    if(!g_signal_eur.Init(SYM_EUR, InpRiskUSD, InpRRRatio)) return INIT_FAILED;
    g_atr_eur = iATR(SYM_EUR, PERIOD_H1, 14);
    if(g_atr_eur == INVALID_HANDLE) {
      Print("[FP50K] FATAL: could not create EURUSD ATR handle.");
      return INIT_FAILED;
    }
  }
  if(InpTradeGBPUSD) {
    if(!g_signal_gbp.Init(SYM_GBP, InpRiskUSD, InpRRRatio)) return INIT_FAILED;
    g_atr_gbp = iATR(SYM_GBP, PERIOD_H1, 14);
    if(g_atr_gbp == INVALID_HANDLE) {
      Print("[FP50K] FATAL: could not create GBPUSD ATR handle.");
      return INIT_FAILED;
    }
  }

  if(g_risk.IsKilled()) {
    Print("[FP50K] FATAL: RiskManager reports killed state at startup.");
    return INIT_FAILED;
  }

  g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
  g_trade.SetAsyncMode(false);

  RecoverPartialState();

  Print("[FP50K] FP50K_EA initialised | Risk=$", DoubleToString(InpRiskUSD, 2),
        " | RR=", DoubleToString(InpRRRatio, 1),
        " | Magic=", InpMagicNumber,
        " | EURUSD=", (InpTradeEURUSD ? "on" : "off"),
        " | GBPUSD=", (InpTradeGBPUSD ? "on" : "off"));
  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  if(g_atr_eur != INVALID_HANDLE) IndicatorRelease(g_atr_eur);
  if(g_atr_gbp != INVALID_HANDLE) IndicatorRelease(g_atr_gbp);

  // Positions are deliberately left open. Their stops live on the broker's
  // server, so detaching the EA does not leave them unprotected - whereas
  // force-closing on every recompile or terminal restart would.
  Print("[FP50K] FP50K_EA stopped | Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Trade management for one open position                           |
//+------------------------------------------------------------------+
void ManagePosition(ulong ticket, int atr_handle) {
  if(!PositionSelectByTicket(ticket)) return;

  string symbol = PositionGetString(POSITION_SYMBOL);
  long   type   = PositionGetInteger(POSITION_TYPE);
  double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl     = PositionGetDouble(POSITION_SL);
  double tp     = PositionGetDouble(POSITION_TP);
  double vol    = PositionGetDouble(POSITION_VOLUME);
  bool   is_long = (type == POSITION_TYPE_BUY);

  double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
  double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
  if(bid <= 0.0 || ask <= 0.0) return;

  double price = is_long ? bid : ask;

  // 1. Pre-news close. Slippage through a red-folder release is the single
  //    fastest way to breach a daily loss limit, so we are flat before it.
  if(InpNewsCloseMin > 0 && g_risk.News().IsBlackedOut(symbol, InpNewsCloseMin)) {
    Print("[FP50K] Closing ", symbol, " ticket ", ticket,
          " ahead of high-impact news: ", g_risk.News().LastBlockEvent());
    if(!g_trade.PositionClose(ticket))
      Print("[FP50K] WARNING: pre-news close failed, retcode=", g_trade.ResultRetcode(),
            " - stop remains on the server.");
    return;
  }

  bool partial_done = IsPartialDone(ticket);

  // 2. Partial close at 1R, then stop to breakeven.
  if(!partial_done) {
    if(sl <= 0.0) return;   // no stop = no measurable R; leave it alone

    double r_dist = MathAbs(entry - sl);
    if(r_dist <= 0.0) return;

    double moved = is_long ? (price - entry) : (entry - price);
    if(moved < r_dist) return;

    double step  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double close_vol = NormalizeLots(symbol, vol * (InpPartialPct / 100.0));

    // Only take the partial if BOTH halves remain legal sizes. On a minimum-lot
    // position, halving would leave an unclosable remainder.
    if(close_vol >= vmin && (vol - close_vol) >= vmin && step > 0.0) {
      if(g_trade.PositionClosePartial(ticket, close_vol)) {
        Print("[FP50K] 1R reached on ", symbol, " ticket ", ticket,
              " - closed ", DoubleToString(close_vol, 2), " of ",
              DoubleToString(vol, 2), " lots.");
      } else {
        Print("[FP50K] WARNING: partial close failed, retcode=", g_trade.ResultRetcode());
        return;
      }
    } else {
      Print("[FP50K] 1R reached on ", symbol, " but position too small to split - ",
            "moving to breakeven only.");
    }

    double be = NormalizePrice(symbol, entry);
    if(g_trade.PositionModify(ticket, be, tp)) {
      Print("[FP50K] Stop moved to breakeven on ", symbol, " ticket ", ticket);
      MarkPartialDone(ticket);
    } else {
      Print("[FP50K] WARNING: breakeven move failed, retcode=", g_trade.ResultRetcode());
    }
    return;
  }

  // 3. ATR trailing stop, once the partial is banked.
  double atr = AtrValue(atr_handle);
  if(atr <= 0.0) return;

  double prev_low  = iLow(symbol,  PERIOD_H1, 1);
  double prev_high = iHigh(symbol, PERIOD_H1, 1);
  if(prev_low <= 0.0 || prev_high <= 0.0) return;

  double new_sl;
  if(is_long) {
    new_sl = NormalizePrice(symbol, prev_low - atr * InpAtrTrailMult);
    // Never widen a stop, and never trail it past current price.
    if(new_sl <= sl || new_sl >= price) return;
  } else {
    new_sl = NormalizePrice(symbol, prev_high + atr * InpAtrTrailMult);
    if(new_sl >= sl || new_sl <= price) return;
  }

  string why = "";
  if(!StopDistanceOk(symbol, price, new_sl, tp, why)) return;

  if(g_trade.PositionModify(ticket, new_sl, tp))
    Print("[FP50K] Trailed ", symbol, " ticket ", ticket, " stop to ",
          DoubleToString(new_sl, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
}

void ManageOpenPositions() {
  for(int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if(ticket == 0) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

    string symbol = PositionGetString(POSITION_SYMBOL);
    int handle = (symbol == SYM_GBP) ? g_atr_gbp : g_atr_eur;
    ManagePosition(ticket, handle);
  }
}

//+------------------------------------------------------------------+
//| Entry logic for one symbol                                       |
//+------------------------------------------------------------------+
void ProcessSymbol(string symbol, CSignalEngine *engine, datetime &last_bar) {
  if(engine == NULL) return;

  // New H1 bar - let the range calculator re-evaluate the session.
  datetime bar_time = iTime(symbol, PERIOD_H1, 0);
  if(bar_time > 0 && bar_time != last_bar) {
    last_bar = bar_time;
    engine.OnNewBar(symbol);
  }

  // One position per symbol at a time.
  if(HasOpenPosition(symbol)) return;

  SSignal sig = engine.CheckSignal(symbol);
  if(!sig.valid) return;

  // Spread gate. Checked here as well as in the governor because the spread
  // that matters is the one at the instant of sending.
  long spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
  if(spread > MaxSpreadFor(symbol)) {
    Print("[BLOCKED] ", symbol, " spread ", spread,
          " above limit ", MaxSpreadFor(symbol));
    return;
  }

  string block_reason = "";
  if(!g_risk.CanOpenTrade(sig.sl_pips, sig.risk_usd, symbol, block_reason)) {
    Print("[BLOCKED] ", symbol, ": ", block_reason);
    return;
  }

  double lots = g_risk.CalculateLotSize(sig.risk_usd, sig.sl_pips, symbol);
  lots = NormalizeLots(symbol, lots);
  if(lots <= 0.0) {
    Print("[BLOCKED] ", symbol, ": computed lot size rounds to zero");
    return;
  }

  // Re-read the quote after the gate - it is not the one the signal saw.
  double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
  if(ask <= 0.0 || bid <= 0.0) return;

  double price = sig.is_long ? ask : bid;
  double sl    = NormalizePrice(symbol, sig.stop_loss);
  double tp    = NormalizePrice(symbol, sig.take_profit);

  // Price may have run past the stop while we were checking. Sending anyway
  // would either be rejected or fill with the stop on the wrong side.
  if(sig.is_long  && (price <= sl || tp <= price)) {
    Print("[BLOCKED] ", symbol, ": price moved through the long setup before send");
    return;
  }
  if(!sig.is_long && (price >= sl || tp >= price)) {
    Print("[BLOCKED] ", symbol, ": price moved through the short setup before send");
    return;
  }

  string why = "";
  if(!StopDistanceOk(symbol, price, sl, tp, why)) {
    Print("[BLOCKED] ", symbol, ": ", why);
    return;
  }

  if(InpEntryOffsetMs > 0)
    Sleep(InpEntryOffsetMs + (int)(MathRand() % 50));

  bool sent = sig.is_long
    ? g_trade.Buy(lots, symbol, 0.0, sl, tp, "FP50K Asian Breakout Long")
    : g_trade.Sell(lots, symbol, 0.0, sl, tp, "FP50K Asian Breakout Short");

  if(sent) {
    Print("[FP50K] ORDER SENT ", (sig.is_long ? "LONG " : "SHORT "), symbol,
          " lots=", DoubleToString(lots, 2),
          " sl=", DoubleToString(sl, _Digits),
          " tp=", DoubleToString(tp, _Digits),
          " sl_pips=", DoubleToString(sig.sl_pips, 1),
          " risk=$", DoubleToString(sig.risk_usd, 2),
          " | ticket=", g_trade.ResultOrder());
  } else {
    Print("[FP50K] ORDER FAILED ", symbol,
          " retcode=", g_trade.ResultRetcode(),
          " (", g_trade.ResultRetcodeDescription(), ")");
  }
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick() {
  // 1. Risk governor state machine first, always. It owns the daily reset,
  //    the drawdown kill and the Friday flatten.
  g_risk.OnTick();

  if(g_risk.IsKilled()) return;

  // 2. Manage what is already open even when the governor has stopped new
  //    entries - a soft stop must not strand a live position unmanaged.
  PruneClosedTickets();
  ManageOpenPositions();

  if(g_risk.GetState() != RISK_OK) return;

  // 3. Look for new entries.
  if(InpTradeEURUSD) ProcessSymbol(SYM_EUR, GetPointer(g_signal_eur), g_last_bar_eur);
  if(InpTradeGBPUSD) ProcessSymbol(SYM_GBP, GetPointer(g_signal_gbp), g_last_bar_gbp);
}

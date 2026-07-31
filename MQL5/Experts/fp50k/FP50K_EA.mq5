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
#include <fp50k\BacktestValidator.mqh>

//--- Risk. InpRiskUSD is now a CEILING, not the size actually used: the risk
//    manager sizes from live equity so the position shrinks with the account.
input double   InpRiskUSD       = 375.0;   // Risk ceiling per trade (USD)
input double   InpRRRatio       = 2.5;     // R:R ratio target
input int      InpMaxSpreadEUR  = 20;      // Max spread EURUSD (points)
input int      InpMaxSpreadGBP  = 25;      // Max spread GBPUSD (points)
//--- Strategy
input bool     InpTradeEURUSD   = true;    // Enable EURUSD
input bool     InpTradeGBPUSD   = true;    // Enable GBPUSD
input ENTRY_MODE InpEntryMode   = ENTRY_MODE_SWEEP;  // Entry model (sweep-fade / legacy breakout)
//--- Session windows, UTC hours. An end at or before the start crosses
//    midnight. These are inputs, not constants, because WHICH hours the
//    contraction and the fade happen in is an empirical question - and one this
//    project's own clock defect already raised by accident.
input int      InpAsianStartH   = 0;       // Contraction window start (UTC hour)
input int      InpAsianEndH     = 7;       // Contraction window end (UTC hour, exclusive)
input int      InpHuntStartH    = 7;       // Sweep hunt window start (UTC hour)
input int      InpHuntEndH      = 17;      // Sweep hunt window end (UTC hour, exclusive)
//--- Asian liquidity sweep & fade
input double   InpSweepMinPips  = 3.0;     // Poke beyond the range that counts as a sweep (pips)
input double   InpSweepSLBuffer = 2.0;     // Stop beyond the sweeping wick (pips)
input double   InpRangeMinPips  = 8.0;     // Minimum Asian range (pips)
input double   InpRangeMaxPips  = 40.0;    // Maximum Asian range (pips)
input double   InpRangeAtrFrac  = 0.60;    // Max range as a fraction of D1 ATR(14), 0=off
input int      InpMaxTradesDay  = 2;       // Max entries per symbol per day (0=unlimited)
//--- Execution realism. Charged against the geometry of every entry, so a
//    backtest cannot flatter itself with fills no live account would get.
input double   InpSlippagePips  = 0.5;     // Assumed adverse fill (pips)
input bool     InpUseLimitEntry = false;   // Place a limit at the swept edge instead of market
input int      InpLimitExpiryMin= 60;      // Pending-order lifetime (minutes)
//--- Legacy breakout geometry. Only read when InpEntryMode = BREAKOUT.
input double   InpStopRangeFrac = 0.0;     // Stop distance as x range width (0=far side of range)
input bool     InpConsistentTP  = false;   // Measure target from entry (true) or range (false)
//--- Trade management. Each stage can be switched off independently, which is
//    the only way to measure what the raw entry signal is worth on its own.
input bool     InpUsePartial    = true;    // Take the partial close at 1R
input bool     InpUseBreakeven  = true;    // Move stop to breakeven at 1R
input bool     InpUseTrail      = true;    // Trail the stop after 1R
input double   InpPartialPct    = 50.0;    // Partial close at 1R (% of position)
input double   InpAtrTrailMult  = 0.5;     // ATR multiple for trailing stop
//--- News. The blackout is symmetric: entries are blocked for this many
//    minutes either side of a high-impact release.
input int      InpNewsBlockMin  = 15;      // Block new entries +/- N min around news
input int      InpNewsCloseMin  = 15;      // Close open trades N min before news
//--- Clock. Every session boundary in this EA is written in UTC, but the broker
//    stamps bars in server time. Live, the gap is auto-detected. In the Strategy
//    Tester TimeGMT() mirrors the server clock, so auto-detection returns zero
//    and the session windows silently shift by the broker's offset - set this
//    to the server's real UTC offset in hours for any backtest.
//    Measured on FundingPips-SIM1, 2026-07-31: +3h in summer, so the WINTER
//    baseline is 2 with EU summer time applied on top.
input int      InpUtcOffsetH    = FP_UTC_OFFSET_AUTO;  // Broker UTC offset in WINTER, hours (-9999=auto)
input bool     InpBrokerEuDst   = true;    // Add 1h through European summer time
//--- Execution
input int      InpEntryOffsetMs = 100;     // Entry time offset ms (0=disable)
input int      InpMagicNumber   = 50001;   // EA magic number

//--- Modules
CRiskManager  g_risk;
CSignalEngine g_signal_eur;
CSignalEngine g_signal_gbp;
CTrade        g_trade;

//--- Backtest validation overlay. Observes only, and only inside the Strategy
//    Tester - it must never add work to a live tick.
CBacktestValidator g_validator;
bool               g_in_tester = false;

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

//--- Entries taken today, per symbol. A fade signal can re-arm several times
//    in one London morning; without a ceiling the EA takes the same losing
//    idea four times before lunch and calls it four independent trades.
//    Keyed on the server-time day, which is the day the firm's limits use.
long g_trade_day     = 0;
int  g_trades_eur    = 0;
int  g_trades_gbp    = 0;

#define SYM_EUR "EURUSD"
#define SYM_GBP "GBPUSD"

//--- Roll the per-symbol daily counters when the server date changes.
void RollTradeDay() {
  long today = (long)TimeCurrent() / 86400;
  if(today == g_trade_day) return;
  g_trade_day  = today;
  g_trades_eur = 0;
  g_trades_gbp = 0;
}

int TradesTodayFor(string symbol) {
  return (symbol == SYM_GBP) ? g_trades_gbp : g_trades_eur;
}

void CountTradeFor(string symbol) {
  if(symbol == SYM_GBP) g_trades_gbp++;
  else                  g_trades_eur++;
}

//--- A pending limit occupies the symbol just as a position does. Without this
//    check the EA stacks a new limit on every qualifying bar while the first
//    is still waiting.
bool HasPendingOrder(string symbol) {
  for(int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ticket = OrderGetTicket(i);
    if(ticket == 0) continue;
    if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
    if((int)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
    return true;
  }
  return false;
}

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

  // Clock diagnostic. The Asian range is defined in UTC but bar timestamps
  // arrive in broker server time, so everything downstream depends on the gap
  // between the two being reported honestly. Inside the Strategy Tester that
  // is not guaranteed: if TimeGMT() simply mirrors the server clock, the
  // offset computes as zero, the 00:00-07:00 "UTC" window is really
  // 00:00-07:00 SERVER time, and on a GMT+3 broker the EA has been measuring
  // 21:00-04:00 UTC - a different session entirely, with results to match.
  // Printing it means the assumption is visible in every run's log instead of
  // being taken on trust.
  if(InpUtcOffsetH != FP_UTC_OFFSET_AUTO) {
    FpSetUtcOffsetHours(InpUtcOffsetH);
    FpSetBrokerEuDst(InpBrokerEuDst);
  }

  bool in_tester      = (MQLInfoInteger(MQL_TESTER) != 0);
  int  detected_h     = (int)(TimeCurrent() - TimeGMT()) / 3600;
  int  clock_offset_h = FpUtcOffsetSecs() / 3600;

  Print("[FP50K] CLOCK | server=", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
        " gmt=", TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS),
        " detected=", detected_h, "h",
        " applied=", clock_offset_h, "h",
        (InpUtcOffsetH != FP_UTC_OFFSET_AUTO ? " (override)" : " (auto)"),
        " | asian 00:00-07:00 UTC = ",
        (24 + clock_offset_h) % 24, ":00-", (7 + clock_offset_h) % 24, ":00 server",
        (in_tester ? " | TESTER" : " | LIVE"));

  // A zero offset inside the tester is the signature of TimeGMT() mirroring the
  // server clock, not of a genuinely UTC broker. Saying so is the whole point:
  // this failure is silent, and a silent wrong session produces confident
  // numbers about hours the strategy was never meant to trade.
  if(in_tester && clock_offset_h == 0 && InpUtcOffsetH == FP_UTC_OFFSET_AUTO)
    Print("[FP50K] WARNING: tester clock offset auto-detected as 0h. If this ",
          "broker's server is not actually UTC, every session window in this ",
          "run is shifted and the results describe different hours than the ",
          "code claims. Set InpUtcOffsetH to the server's real UTC offset.");

  g_risk.SetNewsBlockMinutes(InpNewsBlockMin);

  // The governor's gate and the engine's hunt window must be the same window.
  // If they drift apart the EA finds setups and is then blocked from taking
  // them, which looks like a strategy with no signals rather than a config bug.
  g_risk.SetSessionWindow(InpHuntStartH, InpHuntEndH);

  if(InpTradeEURUSD) {
    if(!g_signal_eur.Init(SYM_EUR, InpRiskUSD, InpRRRatio)) return INIT_FAILED;
    g_signal_eur.SetMode(InpEntryMode);
    g_signal_eur.SetGeometry(InpStopRangeFrac, InpConsistentTP);
    g_signal_eur.SetSweepParams(InpSweepMinPips, InpSweepSLBuffer,
                                InpRangeMinPips, InpRangeMaxPips, InpRangeAtrFrac);
    g_signal_eur.SetSessionWindows(InpAsianStartH, InpAsianEndH,
                                    InpHuntStartH, InpHuntEndH);
    g_signal_eur.SetExecution(InpSlippagePips);
    g_atr_eur = iATR(SYM_EUR, PERIOD_H1, 14);
    if(g_atr_eur == INVALID_HANDLE) {
      Print("[FP50K] FATAL: could not create EURUSD ATR handle.");
      return INIT_FAILED;
    }
  }
  if(InpTradeGBPUSD) {
    if(!g_signal_gbp.Init(SYM_GBP, InpRiskUSD, InpRRRatio)) return INIT_FAILED;
    g_signal_gbp.SetMode(InpEntryMode);
    g_signal_gbp.SetGeometry(InpStopRangeFrac, InpConsistentTP);
    g_signal_gbp.SetSweepParams(InpSweepMinPips, InpSweepSLBuffer,
                                InpRangeMinPips, InpRangeMaxPips, InpRangeAtrFrac);
    g_signal_gbp.SetSessionWindows(InpAsianStartH, InpAsianEndH,
                                    InpHuntStartH, InpHuntEndH);
    g_signal_gbp.SetExecution(InpSlippagePips);
    g_atr_gbp = iATR(SYM_GBP, PERIOD_H1, 14);
    if(g_atr_gbp == INVALID_HANDLE) {
      Print("[FP50K] FATAL: could not create GBPUSD ATR handle.");
      return INIT_FAILED;
    }
  }

  RollTradeDay();

  if(g_risk.IsKilled()) {
    Print("[FP50K] FATAL: RiskManager reports killed state at startup.");
    return INIT_FAILED;
  }

  g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
  g_trade.SetAsyncMode(false);

  RecoverPartialState();

  g_in_tester = (MQLInfoInteger(MQL_TESTER) != 0);
  if(g_in_tester) {
    double deposit = AccountInfoDouble(ACCOUNT_BALANCE);
    if(deposit <= 0.0) deposit = FP_INITIAL_BALANCE;
    g_validator.Init(deposit);
  }

  Print("[FP50K] FP50K_EA initialised | Mode=",
        (InpEntryMode == ENTRY_MODE_SWEEP ? "SWEEP-FADE" : "BREAKOUT"),
        " | Risk ceiling=$", DoubleToString(InpRiskUSD, 2),
        " | RR=", DoubleToString(InpRRRatio, 2),
        " | Slippage=", DoubleToString(InpSlippagePips, 2), "p",
        " | News block=+/-", InpNewsBlockMin, "min",
        " | Entry=", (InpUseLimitEntry ? "limit at swept edge" : "market on close"),
        " | Magic=", InpMagicNumber,
        " | EURUSD=", (InpTradeEURUSD ? "on" : "off"),
        " | GBPUSD=", (InpTradeGBPUSD ? "on" : "off"));
  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  if(g_in_tester) g_validator.Report((ulong)InpMagicNumber);

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

  // 2. The 1R checkpoint: partial close, then stop to breakeven. Either half
  //    can be switched off; with both off this stage only records that 1R was
  //    reached, which is what releases the trailing stage below.
  if(!partial_done) {
    if(!InpUsePartial && !InpUseBreakeven && !InpUseTrail) return;

    if(sl <= 0.0) return;   // no stop = no measurable R; leave it alone

    double r_dist = MathAbs(entry - sl);
    if(r_dist <= 0.0) return;

    double moved = is_long ? (price - entry) : (entry - price);
    if(moved < r_dist) return;

    if(InpUsePartial) {
      double step  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double close_vol = NormalizeLots(symbol, vol * (InpPartialPct / 100.0));

      // Only take the partial if BOTH halves remain legal sizes. On a
      // minimum-lot position, halving leaves an unclosable remainder.
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
        Print("[FP50K] 1R reached on ", symbol, " but position too small to split.");
      }
    }

    if(InpUseBreakeven) {
      double be = NormalizePrice(symbol, entry);
      if(g_trade.PositionModify(ticket, be, tp))
        Print("[FP50K] Stop moved to breakeven on ", symbol, " ticket ", ticket);
      else
        Print("[FP50K] WARNING: breakeven move failed, retcode=", g_trade.ResultRetcode());
    }

    // Marked whether or not the modify succeeded: 1R HAS been reached, and
    // re-running this stage on every later tick would spam the broker.
    MarkPartialDone(ticket);
    Print("[FP50K] 1R checkpoint passed on ", symbol, " ticket ", ticket);
    return;
  }

  // 3. ATR trailing stop, once the 1R checkpoint is behind us.
  if(!InpUseTrail) return;

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
bool SendMarketEntry(string symbol, SSignal &sig, double lots,
                     double sl, double tp, double risk_usd,
                     double ask, double bid);
bool SendLimitEntry(string symbol, SSignal &sig, double lots,
                    double sl, double swept_edge, double risk_usd);

void ProcessSymbol(string symbol, CSignalEngine *engine, datetime &last_bar) {
  if(engine == NULL) return;

  // New H1 bar - let the range calculator re-evaluate the session.
  datetime bar_time = iTime(symbol, PERIOD_H1, 0);
  if(bar_time > 0 && bar_time != last_bar) {
    last_bar = bar_time;
    engine.OnNewBar(symbol);
  }

  // One position - or one waiting limit - per symbol at a time.
  if(HasOpenPosition(symbol)) return;
  if(HasPendingOrder(symbol)) return;

  // Daily entry ceiling, checked before the signal so a capped symbol costs
  // nothing but a comparison.
  if(InpMaxTradesDay > 0 && TradesTodayFor(symbol) >= InpMaxTradesDay) return;

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

  // One call answers "may I trade" and "how big". Size comes from live equity,
  // capped by what is left of today's loss allowance, so a day already down
  // cannot be finished off by a full-size trade.
  RiskStatus rs = g_risk.EvaluateRisk(sig.sl_pips, symbol);
  if(!rs.isTradingAllowed) {
    Print("[BLOCKED] ", symbol, ": ", rs.statusReason);
    return;
  }

  double lots = NormalizeLots(symbol, rs.maxAllowedLotSize);
  if(lots <= 0.0) {
    Print("[BLOCKED] ", symbol, ": computed lot size rounds to zero");
    return;
  }

  // Re-read the quote after the gate - it is not the one the signal saw.
  double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
  if(ask <= 0.0 || bid <= 0.0) return;

  double sl = NormalizePrice(symbol, sig.stop_loss);
  double tp = NormalizePrice(symbol, sig.take_profit);

  if(InpEntryOffsetMs > 0)
    Sleep(InpEntryOffsetMs + (int)(MathRand() % 50));

  bool sent;
  if(InpUseLimitEntry) {
    // The limit goes at the edge the market just swept and rejected, which the
    // signal itself does not carry - it only knows the market price it would
    // have filled at. Read it from the range the engine measured.
    double edge = sig.is_long ? engine.Range().GetRangeLow()
                              : engine.Range().GetRangeHigh();
    sent = SendLimitEntry(symbol, sig, lots, sl, edge, rs.riskUsd);
  } else {
    sent = SendMarketEntry(symbol, sig, lots, sl, tp, rs.riskUsd, ask, bid);
  }

  if(sent) CountTradeFor(symbol);
}

//--- SendMarketEntry: fill now, at the close of the confirming candle.
bool SendMarketEntry(string symbol, SSignal &sig, double lots,
                     double sl, double tp, double risk_usd,
                     double ask, double bid) {
  double price = sig.is_long ? ask : bid;

  // Price may have run past the stop while we were checking. Sending anyway
  // would either be rejected or fill with the stop on the wrong side.
  if(sig.is_long  && (price <= sl || tp <= price)) {
    Print("[BLOCKED] ", symbol, ": price moved through the long setup before send");
    return false;
  }
  if(!sig.is_long && (price >= sl || tp >= price)) {
    Print("[BLOCKED] ", symbol, ": price moved through the short setup before send");
    return false;
  }

  string why = "";
  if(!StopDistanceOk(symbol, price, sl, tp, why)) {
    Print("[BLOCKED] ", symbol, ": ", why);
    return false;
  }

  bool sent = sig.is_long
    ? g_trade.Buy(lots, symbol, 0.0, sl, tp, "FP50K sweep fade long")
    : g_trade.Sell(lots, symbol, 0.0, sl, tp, "FP50K sweep fade short");

  if(sent) {
    Print("[FP50K] ORDER SENT ", (sig.is_long ? "LONG " : "SHORT "), symbol,
          " lots=", DoubleToString(lots, 2),
          " sl=", DoubleToString(sl, _Digits),
          " tp=", DoubleToString(tp, _Digits),
          " sl_pips=", DoubleToString(sig.sl_pips, 1),
          " risk=$", DoubleToString(risk_usd, 2),
          " | ticket=", g_trade.ResultOrder());
  } else {
    Print("[FP50K] ORDER FAILED ", symbol,
          " retcode=", g_trade.ResultRetcode(),
          " (", g_trade.ResultRetcodeDescription(), ")");
  }
  return sent;
}

//--- SendLimitEntry: wait for price to come back to the level it just rejected.
//
//    This is a genuinely different trade from the market entry above, not a
//    cheaper version of it. The sweep has already closed back inside the range,
//    so a limit AT the swept edge only fills if price returns to poke again -
//    a better price when it fills, and no trade at all when it does not. Which
//    of the two is better is an empirical question, which is why both exist and
//    why this one is off by default.
bool SendLimitEntry(string symbol, SSignal &sig, double lots,
                    double sl, double swept_edge, double risk_usd) {
  if(swept_edge <= 0.0) {
    Print("[BLOCKED] ", symbol, ": no swept range edge to place a limit at");
    return false;
  }

  double limit_price = NormalizePrice(symbol, swept_edge);

  double ref = SymbolInfoDouble(symbol, sig.is_long ? SYMBOL_ASK : SYMBOL_BID);
  if(ref <= 0.0) return false;

  // A buy limit must sit BELOW the market and a sell limit above it, or the
  // broker rejects the order outright.
  if(sig.is_long  && limit_price >= ref) {
    Print("[BLOCKED] ", symbol, ": buy limit would sit at or above the market");
    return false;
  }
  if(!sig.is_long && limit_price <= ref) {
    Print("[BLOCKED] ", symbol, ": sell limit would sit at or below the market");
    return false;
  }

  // The target must be recomputed. The stop stays where it is - beyond the
  // rejected wick - so filling at the edge instead of at the market shortens
  // the stop distance, and a target copied from the market signal would no
  // longer be the R:R this strategy claims to trade.
  double stop_dist = MathAbs(limit_price - sl);
  if(stop_dist <= 0.0) {
    Print("[BLOCKED] ", symbol, ": limit price and stop coincide");
    return false;
  }

  double tp = NormalizePrice(symbol,
                sig.is_long ? (limit_price + stop_dist * InpRRRatio)
                            : (limit_price - stop_dist * InpRRRatio));

  // Lots were sized against the wider market-entry stop, so the limit fills
  // slightly UNDER the risk budget rather than over it. That is the safe
  // direction to be wrong in, and it is why they are not recomputed here.

  string why = "";
  if(!StopDistanceOk(symbol, limit_price, sl, tp, why)) {
    Print("[BLOCKED] ", symbol, ": ", why);
    return false;
  }

  // The pending order itself must also sit far enough from the market.
  long   level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if(level > 0 && point > 0.0 && MathAbs(ref - limit_price) < level * point) {
    Print("[BLOCKED] ", symbol, ": limit is inside the broker's ", (int)level,
          "-point pending-order distance");
    return false;
  }

  // Expiry matters more here than it looks. An unfilled limit left sitting is
  // a trade taken on tomorrow's conditions using yesterday's reasoning.
  datetime expiry = TimeCurrent() + InpLimitExpiryMin * 60;

  bool sent = sig.is_long
    ? g_trade.BuyLimit(lots, limit_price, symbol, sl, tp,
                       ORDER_TIME_SPECIFIED, expiry, "FP50K sweep fade long limit")
    : g_trade.SellLimit(lots, limit_price, symbol, sl, tp,
                        ORDER_TIME_SPECIFIED, expiry, "FP50K sweep fade short limit");

  if(sent) {
    Print("[FP50K] LIMIT PLACED ", (sig.is_long ? "LONG " : "SHORT "), symbol,
          " lots=", DoubleToString(lots, 2),
          " at=", DoubleToString(limit_price, _Digits),
          " sl=", DoubleToString(sl, _Digits),
          " tp=", DoubleToString(tp, _Digits),
          " expires=", TimeToString(expiry, TIME_DATE | TIME_MINUTES),
          " risk=$", DoubleToString(risk_usd, 2),
          " | ticket=", g_trade.ResultOrder());
  } else {
    Print("[FP50K] LIMIT FAILED ", symbol,
          " retcode=", g_trade.ResultRetcode(),
          " (", g_trade.ResultRetcodeDescription(), ")");
  }
  return sent;
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick() {
  // 0. Backtest bookkeeping. Sampled before anything else so the equity low
  //    of a tick is recorded even if the governor kills the EA on that tick.
  if(g_in_tester) {
    g_validator.Feed(TimeCurrent(),
                     AccountInfoDouble(ACCOUNT_EQUITY),
                     AccountInfoDouble(ACCOUNT_BALANCE));
    g_validator.NoteNewsBlock(g_risk.News().LastBlockTime());
  }

  // 1. Risk governor state machine first, always. It owns the daily reset,
  //    the drawdown kill and the Friday flatten.
  g_risk.OnTickUpdate();

  // Same server-time day boundary the governor just used, so the entry
  // counters reset at 00:00 platform time alongside the loss allowance.
  RollTradeDay();

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

//+------------------------------------------------------------------+
//| OnTester - the value the Strategy Tester's optimiser maximises    |
//+------------------------------------------------------------------+
//
// Left to itself the optimiser maximises net profit, and the most profitable
// parameter set is very often one that breaks a challenge rule on the way.
// This returns zero for any run that breached the daily wall or the equity
// floor, so those settings can never win an optimisation.
double OnTester() {
  g_validator.Finalise((ulong)InpMagicNumber);
  double score = g_validator.OptimisationScore();
  Print("[FP50K] OnTester score=", DoubleToString(score, 2),
        " | compliance=", (g_validator.CompliancePassed() ? "PASS" : "FAIL"),
        " | trades=", g_validator.Trades(),
        " | maxDD=", DoubleToString(g_validator.MaxDDPct(), 2), "%");
  return score;
}

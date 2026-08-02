#!/usr/bin/env python3
"""
Offline hypothesis screener for the Strategy Lab.

WHAT THIS IS FOR
    An MT5 backtest is the verdict. This is the thing that decides what is
    worth taking to a verdict.

    Every hypothesis so far has been judged on two years of one instrument -
    about 300 to 600 trades. That is enough to detect a large edge and not
    nearly enough to tell a small one from noise, which is exactly the
    situation H4 landed in (+0.06 R before costs, p = 0.18: unresolvable).
    The install already holds 8.5 years of H1 bars for EURUSD, GBPUSD and
    EURGBP, each with the broker's own recorded spread on every bar. That is
    roughly twenty times the sample, and it costs seconds to run instead of
    minutes.

WHAT THIS IS NOT
    It is NOT a substitute for the tester, for one specific reason: an H1 bar
    records only open/high/low/close, so when a stop and a target both sit
    inside the same bar's range there is no way to know which was reached
    first. MT5's 1-minute modelling can often resolve that; this cannot.

    Rather than guess, every ambiguous bar is scored as the LOSS. That biases
    the screen against the strategy. It is the right direction for a bias to
    point in a filter: anything that survives a pessimistic screen has earned
    a real backtest, and anything that only passes optimistically was never
    going to survive the tester anyway.

    Two further gaps, stated so no result from here is read as more than it
    is: there is no news filter, and drawdown is closed-trade only. Both are
    true of the MT5 runs as well.

COSTS
    Charged from the CSV's own <SPREAD> column by default - the actual spread
    the broker recorded on that bar, which is more honest than the single
    forced value the tester runs use. Slippage is charged on entry at the same
    0.5 pips the EAs charge. --spread-pips overrides the column with a fixed
    value, which is what the calibration run against MT5 needs.

CALIBRATION
    Run --strategy fade over the same window as the h4eur MT5 run and the
    trade count and mean R should land close to it. They will not match
    exactly - the tie-break rule alone guarantees a difference - but a large
    gap means this file is measuring something other than what the EA does,
    and no number it produces should then be believed.

Author : Tee (aigentforce.io)
Project: Strategy Lab
"""

import argparse
import csv
import math
import sys
from datetime import datetime


# --------------------------------------------------------------------------
# Statistics. Same maths as tools/edge_stats.py - a per-trade two-sided t-test
# on the R series. scipy is not installed, so the incomplete beta function is
# implemented directly (Numerical Recipes continued fraction).
# --------------------------------------------------------------------------

def _betacf(a, b, x):
    MAXIT, EPS, FPMIN = 300, 3.0e-16, 1.0e-300
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < FPMIN:
        d = FPMIN
    d = 1.0 / d
    h = d
    for m in range(1, MAXIT + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        c = 1.0 + aa / c
        if abs(d) < FPMIN:
            d = FPMIN
        if abs(c) < FPMIN:
            c = FPMIN
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        c = 1.0 + aa / c
        if abs(d) < FPMIN:
            d = FPMIN
        if abs(c) < FPMIN:
            c = FPMIN
        d = 1.0 / d
        de = d * c
        h *= de
        if abs(de - 1.0) < EPS:
            break
    return h


def _betai(a, b, x):
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    lbt = (math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
           + a * math.log(x) + b * math.log(1.0 - x))
    bt = math.exp(lbt)
    if x < (a + 1.0) / (a + b + 2.0):
        return bt * _betacf(a, b, x) / a
    return 1.0 - bt * _betacf(b, a, 1.0 - x) / b


def t_test(values):
    """Mean, sample sd (n-1), t-statistic and two-sided p for a series."""
    n = len(values)
    if n < 2:
        return n, 0.0, 0.0, 0.0, 1.0
    mean = sum(values) / n
    var = sum((v - mean) ** 2 for v in values) / (n - 1)
    sd = math.sqrt(var)
    if sd <= 0.0:
        return n, mean, sd, 0.0, 1.0
    t = mean / (sd / math.sqrt(n))
    df = n - 1
    p = _betai(df / 2.0, 0.5, df / (df + t * t))
    return n, mean, sd, t, p


# --------------------------------------------------------------------------
# Data
# --------------------------------------------------------------------------

class Bar:
    __slots__ = ("t", "o", "h", "l", "c", "spread_pts", "tickvol")

    def __init__(self, t, o, h, l, c, spread_pts, tickvol=0.0):
        self.t, self.o, self.h, self.l, self.c = t, o, h, l, c
        self.spread_pts = spread_pts
        self.tickvol = tickvol


def load_bars(path, date_from, date_to, hour_shift):
    """Read an MT5 'Save as CSV' bar export.

    Timestamps are broker server time. hour_shift is added to convert them to
    GMT and is a declared input rather than something inferred, because a
    wrong guess here silently moves the trading-hours window and there would
    be no symptom other than a different result.
    """
    bars = []
    with open(path, newline="") as fh:
        rdr = csv.reader(fh, delimiter="\t")
        header = next(rdr)
        if not header or not header[0].startswith("<DATE>"):
            raise SystemExit("Unexpected CSV header: %r" % (header[:3],))
        for row in rdr:
            if len(row) < 7:
                continue
            t = datetime.strptime(row[0] + " " + row[1], "%Y.%m.%d %H:%M:%S")
            if date_from and t < date_from:
                continue
            if date_to and t > date_to:
                continue
            bars.append(Bar(t,
                            float(row[2]), float(row[3]),
                            float(row[4]), float(row[5]),
                            float(row[8]) if len(row) > 8 else 0.0,
                            float(row[6])))
    bars.sort(key=lambda b: b.t)
    if hour_shift:
        # Applied to the stored time so every later hour test reads GMT.
        from datetime import timedelta
        for b in bars:
            b.t = b.t + timedelta(hours=hour_shift)
    return bars


def sma(values, period, i):
    """Simple mean of the `period` values ending at index i, or None."""
    if i + 1 < period:
        return None
    return sum(values[i - period + 1:i + 1]) / period


def true_ranges(bars):
    tr = [0.0] * len(bars)
    for i, b in enumerate(bars):
        if i == 0:
            tr[i] = b.h - b.l
        else:
            pc = bars[i - 1].c
            tr[i] = max(b.h - b.l, abs(b.h - pc), abs(b.l - pc))
    return tr


# --------------------------------------------------------------------------
# The simulation
# --------------------------------------------------------------------------

class Result:
    def __init__(self):
        self.r = []            # R multiple per trade
        self.exits = {"target": 0, "stop": 0, "time": 0, "ambiguous": 0}
        self.stops_pips = []
        self.rr = []
        self.stretched = 0
        self.skip_hour = 0
        self.skip_spread = 0
        self.skip_geometry = 0
        self.skip_vol = 0


def run_fade(bars, args, pip):
    """H4's rule: fade a close more than N x ATR from its own mean.

    Deliberately written to mirror LAB_MeanReversion.mq5 decision for
    decision, including reading the CLOSED bar and entering on the next bar's
    open, so that a disagreement between the two is a real disagreement and
    not a difference in what was implemented.
    """
    res = Result()
    closes = [b.c for b in bars]
    tr = true_ranges(bars)

    pos = None   # dict when a trade is open
    n = len(bars)

    for i in range(n - 1):
        entry_bar = bars[i + 1]

        # ---- manage an open position on this bar --------------------------
        if pos is not None:
            b = entry_bar
            sp = (args.spread_pips * pip if args.spread_pips is not None
                  else b.spread_pts * pip)
            if pos["long"]:
                hit_sl = b.l <= pos["sl"]
                hit_tp = b.h >= pos["tp"]
            else:
                hit_sl = (b.h + sp) >= pos["sl"]
                hit_tp = (b.l + sp) <= pos["tp"]

            exit_px = None
            kind = None
            if hit_sl and hit_tp:
                # Cannot be resolved from OHLC. Scored as the loss, always.
                exit_px, kind = pos["sl"], "ambiguous"
            elif hit_sl:
                exit_px, kind = pos["sl"], "stop"
            elif hit_tp:
                exit_px, kind = pos["tp"], "target"
            else:
                pos["bars"] += 1
                if pos["bars"] >= args.hold:
                    exit_px = b.c if pos["long"] else (b.c + sp)
                    kind = "time"

            if exit_px is not None:
                if pos["long"]:
                    r = (exit_px - pos["entry"]) / pos["risk"]
                else:
                    r = (pos["entry"] - exit_px) / pos["risk"]
                res.r.append(r)
                res.exits[kind] += 1
                pos = None
            # Whether or not it exited, no new trade can start on this bar.
            # The EA sees the open position when the bar opens and returns
            # immediately; the exit happens later, inside the bar, on the
            # server. Entering here would be entering at an open that had
            # already passed by the time the slot was actually free - a
            # lookahead worth about a hundred extra trades in the first
            # calibration run, all of them impossible.
            continue

        # ---- look for a signal on the closed bar i ------------------------
        ma = sma(closes, args.ma, i)
        atr = sma(tr, args.atr, i)
        if ma is None or atr is None or atr <= 0.0:
            continue

        stretch = args.entry_atr * atr
        eps = atr * 1e-6
        c = bars[i].c
        if c < ma - stretch - eps:
            long = True
        elif c > ma + stretch + eps:
            long = False
        else:
            continue
        res.stretched += 1

        if not (args.hour_start <= bars[i].t.hour < args.hour_end):
            res.skip_hour += 1
            continue

        # ---- H5: split the same trade by how busy the signal bar was ------
        # Compared against the median of the PRECEDING bars, never including
        # the signal bar itself - a bar cannot be judged busy relative to a
        # window it is a member of.
        if args.vol_side != "any":
            if i < args.vol_lookback:
                continue
            window = sorted(b.tickvol for b in bars[i - args.vol_lookback:i])
            k = len(window)
            med = (window[k // 2] if k % 2
                   else 0.5 * (window[k // 2 - 1] + window[k // 2]))
            busy = bars[i].tickvol > med
            if (args.vol_side == "high") != busy:
                res.skip_vol += 1
                continue

        b = entry_bar
        sp_pts = (args.spread_pips * pip / pip if args.spread_pips is not None
                  else b.spread_pts)
        sp = (args.spread_pips * pip if args.spread_pips is not None
              else b.spread_pts * pip)
        if sp / pip > args.max_spread_pips:
            res.skip_spread += 1
            continue

        slip = args.slippage_pips * pip
        stop_d = args.stop_atr * atr
        bid_open = b.o
        ask_open = b.o + sp
        entry = (ask_open + slip) if long else (bid_open - slip)
        sl = (entry - stop_d) if long else (entry + stop_d)
        tp = ma
        reward = (tp - entry) if long else (entry - tp)
        if reward <= 0.0:
            res.skip_geometry += 1
            continue

        pos = {"long": long, "entry": entry, "sl": sl, "tp": tp,
               "risk": stop_d, "bars": 0}
        res.stops_pips.append(stop_d / pip)
        res.rr.append(reward / stop_d)

    return res


STRATEGIES = {"fade": run_fade}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--strategy", default="fade", choices=sorted(STRATEGIES))
    ap.add_argument("--from", dest="dfrom", default=None)
    ap.add_argument("--to", dest="dto", default=None)
    ap.add_argument("--hour-shift", type=int, default=0,
                    help="hours added to server time to reach GMT")
    ap.add_argument("--ma", type=int, default=20)
    ap.add_argument("--atr", type=int, default=20)
    ap.add_argument("--entry-atr", type=float, default=2.0)
    ap.add_argument("--stop-atr", type=float, default=2.0)
    ap.add_argument("--hold", type=int, default=24)
    ap.add_argument("--hour-start", type=int, default=7)
    ap.add_argument("--hour-end", type=int, default=20)
    ap.add_argument("--slippage-pips", type=float, default=0.5)
    ap.add_argument("--max-spread-pips", type=float, default=3.0)
    ap.add_argument("--spread-pips", type=float, default=None,
                    help="force a fixed spread instead of the CSV column")
    ap.add_argument("--jpy", action="store_true",
                    help="2/3-digit quote: pip = 0.01 instead of 0.0001")
    ap.add_argument("--vol-side", default="any", choices=("any", "low", "high"),
                    help="restrict to signal bars whose tick volume is below "
                         "or above the median of the preceding bars")
    ap.add_argument("--vol-lookback", type=int, default=20)
    ap.add_argument("--label", default=None)
    args = ap.parse_args()

    pip = 0.01 if args.jpy else 0.0001
    dfrom = datetime.strptime(args.dfrom, "%Y-%m-%d") if args.dfrom else None
    dto = datetime.strptime(args.dto, "%Y-%m-%d") if args.dto else None

    bars = load_bars(args.csv, dfrom, dto, args.hour_shift)
    if len(bars) < 200:
        raise SystemExit("Only %d bars in range - nothing to measure." % len(bars))

    res = STRATEGIES[args.strategy](bars, args, pip)
    n, mean, sd, t, p = t_test(res.r)
    if n == 0:
        raise SystemExit("No trades taken.")

    wins = sum(1 for v in res.r if v > 0)
    gross_win = sum(v for v in res.r if v > 0)
    gross_loss = -sum(v for v in res.r if v < 0)
    pf = (gross_win / gross_loss) if gross_loss > 0 else float("inf")

    # Closed-trade drawdown on the R curve.
    peak, dd, eq = 0.0, 0.0, 0.0
    for v in res.r:
        eq += v
        peak = max(peak, eq)
        dd = max(dd, peak - eq)

    label = args.label or args.csv.split("/")[-1].split("_")[0]
    print("=" * 62)
    print("  SCREEN: %s | %s" % (label, args.strategy))
    print("=" * 62)
    print("  Bars               : %d  (%s -> %s GMT)"
          % (len(bars), bars[0].t.date(), bars[-1].t.date()))
    print("  Spread             : %s"
          % ("forced %.1f pips" % args.spread_pips if args.spread_pips is not None
             else "broker's recorded per-bar spread"))
    print("  Trades             : %d" % n)
    print("  Win rate           : %.2f%%" % (100.0 * wins / n))
    print("  Profit factor      : %.3f" % pf)
    print("  Mean R             : %+.4f" % mean)
    print("  Std dev per trade  : %.4f R" % sd)
    print("  t-statistic        : %+.3f   (df %d)" % (t, n - 1))
    print("  p-value (2-sided)  : %.4f" % p)
    print("  Max drawdown       : %.2f R  (closed-trade basis)" % dd)
    if res.stops_pips:
        print("  Stop width         : mean %.1f pips  (min %.1f, max %.1f)"
              % (sum(res.stops_pips) / len(res.stops_pips),
                 min(res.stops_pips), max(res.stops_pips)))
    if res.rr:
        print("  Reward:risk        : mean %.2f" % (sum(res.rr) / len(res.rr)))
    print("  Exits              : target %d | stop %d | time %d | ambiguous->loss %d"
          % (res.exits["target"], res.exits["stop"],
             res.exits["time"], res.exits["ambiguous"]))
    print("  Signals filtered   : hour %d | spread %d | geometry %d | volume %d"
          "  (stretched %d)"
          % (res.skip_hour, res.skip_spread, res.skip_geometry, res.skip_vol,
             res.stretched))

    if mean > 0 and p < 0.05:
        print("\n  SCREEN RESULT: worth a real backtest.")
    elif mean > 0:
        print("\n  SCREEN RESULT: right sign, not significant (p >= 0.05).")
    else:
        print("\n  SCREEN RESULT: mean trade loses. No backtest warranted.")
    print("=" * 62)
    return 0


if __name__ == "__main__":
    sys.exit(main())

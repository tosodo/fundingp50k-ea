#!/usr/bin/env python3
"""
edge_stats.py - statistical significance of a trade series.

Purpose
    A backtest that made money is not the same thing as a backtest that found
    an edge. With enough trades, a coin flip produces winning runs; the only
    question worth asking is whether this run's average result is far enough
    from zero that chance is an implausible explanation. That is what this
    computes, from the trades that actually happened.

Input
    The CSV exported by a lab EA: n, close_time, profit_usd, r_multiple

Output
    Win rate, profit factor, expectancy, Sharpe, a t-test on the per-trade R
    series, and the peak-to-trough drawdown of the equity curve.

Deliberately not here
    Any judgement about whether the strategy should be traded. The pass/fail
    thresholds live in the loop that calls this, agreed before the run, so a
    disappointing result cannot quietly move the bar it was measured against.

Author : Tee (aigentforce.io)
Project: Strategy Lab
"""

import csv
import math
import sys
from datetime import datetime


# --------------------------------------------------------------------------
# Student's t distribution, without scipy.
#
# The regularised incomplete beta function, via the continued fraction in
# Numerical Recipes. This is here rather than imported because scipy is not
# installed and a normal approximation, while close at a few hundred trades,
# is optimistic in exactly the small-sample case where the answer matters
# most.
# --------------------------------------------------------------------------
def _betacf(a, b, x, itmax=200, eps=3.0e-12):
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < 1.0e-30:
        d = 1.0e-30
    d = 1.0 / d
    h = d
    for m in range(1, itmax + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < 1.0e-30:
            d = 1.0e-30
        c = 1.0 + aa / c
        if abs(c) < 1.0e-30:
            c = 1.0e-30
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < 1.0e-30:
            d = 1.0e-30
        c = 1.0 + aa / c
        if abs(c) < 1.0e-30:
            c = 1.0e-30
        d = 1.0 / d
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < eps:
            break
    return h


def _betai(a, b, x):
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    lbeta = (math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
             + a * math.log(x) + b * math.log(1.0 - x))
    front = math.exp(lbeta)
    if x < (a + 1.0) / (a + b + 2.0):
        return front * _betacf(a, b, x) / a
    return 1.0 - front * _betacf(b, a, 1.0 - x) / b


def t_pvalue_two_sided(t, df):
    """P(|T| >= |t|) for a t distribution with df degrees of freedom."""
    if df <= 0:
        return float("nan")
    return _betai(0.5 * df, 0.5, df / (df + t * t))


# --------------------------------------------------------------------------
def load(path):
    rows = []
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            try:
                rows.append({
                    "time": datetime.strptime(row["close_time"].strip(),
                                              "%Y.%m.%d %H:%M"),
                    "usd": float(row["profit_usd"]),
                    "r": float(row["r_multiple"]),
                })
            except (ValueError, KeyError):
                continue
    rows.sort(key=lambda x: x["time"])
    return rows


def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def stdev(xs):
    """Sample standard deviation - n-1, not n. With n-1 the estimate is
    unbiased; with n it is systematically too small, which inflates every
    t-statistic computed from it."""
    if len(xs) < 2:
        return 0.0
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def max_drawdown_pct(usd, deposit):
    """Peak-to-trough of the closed-trade equity curve, as a percentage of the
    starting deposit. This is measured trade to trade, so it does NOT see
    intra-trade excursions - the real drawdown is deeper than this figure."""
    equity, peak, worst = deposit, deposit, 0.0
    for p in usd:
        equity += p
        peak = max(peak, equity)
        if peak > 0:
            worst = max(worst, (peak - equity) / peak * 100.0)
    return worst


def daily_series(rows):
    """Trade P&L collapsed onto calendar days, with flat weekdays filled in as
    zeros. Omitting the flat days would compute the Sharpe of trading days
    only, which overstates it - the strategy is exposed to the calendar, not
    only to the days it happened to act."""
    by_day = {}
    for r in rows:
        by_day[r["time"].date()] = by_day.get(r["time"].date(), 0.0) + r["usd"]
    if not by_day:
        return []
    first, last = min(by_day), max(by_day)
    out, day = [], first
    from datetime import timedelta
    while day <= last:
        if day.weekday() < 5:
            out.append(by_day.get(day, 0.0))
        day += timedelta(days=1)
    return out


def main():
    if len(sys.argv) < 2:
        print("Usage: edge_stats.py <trades.csv> [tag] [deposit]")
        return 1

    path = sys.argv[1]
    tag = sys.argv[2] if len(sys.argv) > 2 else "run"
    deposit = float(sys.argv[3]) if len(sys.argv) > 3 else 50000.0

    rows = load(path)
    n = len(rows)
    if n == 0:
        print(f"[{tag}] NO TRADES in {path} - nothing to test.")
        return 1

    r = [x["r"] for x in rows]
    usd = [x["usd"] for x in rows]

    wins = [x for x in usd if x > 0]
    losses = [x for x in usd if x <= 0]
    win_pct = len(wins) / n * 100.0
    gross_win = sum(wins)
    gross_loss = abs(sum(losses))
    pf = (gross_win / gross_loss) if gross_loss > 0 else float("inf")

    mean_r, sd_r = mean(r), stdev(r)
    ev_usd = mean(usd)
    net = sum(usd)

    # t-test on the per-trade R series: is the average trade different from
    # zero, or is a mean this far from zero an ordinary run of luck?
    df = n - 1
    if sd_r > 0 and n > 1:
        t_stat = mean_r / (sd_r / math.sqrt(n))
        p_val = t_pvalue_two_sided(t_stat, df)
    else:
        t_stat, p_val = float("nan"), float("nan")

    daily = daily_series(rows)
    md, sdd = mean(daily), stdev(daily)
    sharpe = (md / sdd * math.sqrt(252)) if sdd > 0 else float("nan")

    dd = max_drawdown_pct(usd, deposit)

    print(f"  Run tag            : {tag}")
    print(f"  Trades             : {n}")
    print(f"  Win rate           : {win_pct:.2f}%")
    print(f"  Profit factor      : {pf:.3f}")
    print(f"  Net P&L            : ${net:,.2f}")
    print(f"  Expectancy / trade : ${ev_usd:,.2f}   ({mean_r:+.4f} R)")
    print(f"  Std dev per trade  : {sd_r:.4f} R")
    print(f"  Max drawdown       : {dd:.2f}%  (closed-trade basis; the real"
          f" figure is deeper)")
    print(f"  Trading days       : {len(daily)}")
    print(f"  Annualised Sharpe  : {sharpe:.3f}")
    print(f"  t-statistic        : {t_stat:.3f}   (df {df})")
    print(f"  p-value (2-sided)  : {p_val:.4f}")
    print()

    if math.isnan(p_val):
        print("  VERDICT: not computable - too few trades or zero variance.")
    elif mean_r <= 0:
        print(f"  VERDICT: REJECT. The average trade LOSES {abs(mean_r):.4f}R."
              f" Significance is irrelevant when the sign is wrong.")
    elif p_val < 0.05:
        print(f"  VERDICT: significant at p<0.05. A mean of {mean_r:+.4f}R over"
              f" {n} trades is unlikely to be chance.")
    else:
        print(f"  VERDICT: NOT significant (p={p_val:.4f}). The edge is"
              f" positive but indistinguishable from luck at this sample size.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

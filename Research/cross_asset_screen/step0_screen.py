#!/usr/bin/env python3
"""
Step 0 - cross-asset trend-persistence screen.

Same Lo-MacKinlay variance-ratio test, same code, same horizons as the FX audit,
so the numbers are directly comparable.

  VR > 1  = trend persistence   VR < 1 = mean reversion   VR = 1 = random walk

Descriptive only. No strategy, no parameters, no entries.
"""
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "step0_data")

ORDER = [
    ("SPX500",  "equity_index"), ("NDX100", "equity_index"), ("DJI30", "equity_index"),
    ("GER40",   "equity_index"), ("FTSE100","equity_index"), ("STX50", "equity_index"),
    ("JP225",   "equity_index"),
    ("XAUUSD",  "metal"),        ("XAGUSD", "metal"),        ("COPPER","metal"),
    ("USOIL",   "energy"),       ("UKOIL",  "energy"),       ("NATGAS","energy"),
    ("US10Y",   "rates"),
    ("BTCUSD",  "crypto"),
    ("EURUSD",  "fx_control"),   ("USDJPY", "fx_control"),
    ("AUDUSD",  "fx_control"),   ("GBPUSD", "fx_control"),
]

HORIZONS = (5, 10, 20, 60)


def variance_ratio(prices, q):
    """Lo-MacKinlay VR(q), heteroskedasticity-consistent z. Verbatim from the FX audit."""
    p = [math.log(x) for x in prices]
    n = len(p) - 1
    if n <= q * 2:
        return None, None
    mu = (p[-1] - p[0]) / n
    d1 = [p[k + 1] - p[k] - mu for k in range(n)]
    sig_a = sum(x * x for x in d1) / (n - 1)
    if sig_a <= 0:
        return None, None
    M = q * (n - q + 1) * (1.0 - float(q) / n)
    s = 0.0
    for k in range(q, n + 1):
        s += (p[k] - p[k - q] - q * mu) ** 2
    sig_c = s / M
    vr = sig_c / sig_a
    denom = sum(x * x for x in d1) ** 2
    theta = 0.0
    for j in range(1, q):
        num = 0.0
        for k in range(j, n):
            num += (d1[k] ** 2) * (d1[k - j] ** 2)
        theta += ((2.0 * (q - j)) / q) ** 2 * (num / denom)
    if theta <= 0:
        return vr, None
    return vr, (vr - 1.0) / math.sqrt(theta)


def norm_p2(z):
    return math.erfc(abs(z) / math.sqrt(2.0))


def load(label):
    with open(os.path.join(DATA, label + ".json")) as fh:
        d = json.load(fh)
    r = d["chart"]["result"][0]
    ts = r["timestamp"]
    cl = r["indicators"]["quote"][0]["close"]
    out_t, out_c = [], []
    for t, c in zip(ts, cl):
        if c is None or c <= 0:
            continue
        out_t.append(t)
        out_c.append(float(c))
    return out_t, out_c


def ymd(t):
    import datetime
    return datetime.datetime.utcfromtimestamp(t).strftime("%Y-%m-%d")


def main():
    k = len(ORDER) * len(HORIZONS)
    thresh = 0.05 / k

    print()
    print("=" * 86)
    print("  STEP 0 - CROSS-ASSET TREND-PERSISTENCE SCREEN")
    print("  Lo-MacKinlay variance ratio on daily closes.")
    print("  VR>1 trending | VR<1 reverting | VR=1 random walk")
    print("  %d tests (%d instruments x %d horizons) -> Bonferroni threshold %.6f"
          % (k, len(ORDER), len(HORIZONS), thresh))
    print("=" * 86)
    print()
    print("  %-9s %-13s %6s %-24s %s"
          % ("symbol", "class", "bars", "period", "VR(5d)   VR(10d)  VR(20d)  VR(60d)"))
    print("  " + "-" * 84)

    results = {}
    for label, cls in ORDER:
        ts, cl = load(label)
        row = []
        for q in HORIZONS:
            vr, z = variance_ratio(cl, q)
            p = norm_p2(z) if z is not None else float("nan")
            row.append((vr, z, p))
        results[label] = (cls, row)
        cells = "".join("%8.3f " % r[0] for r in row)
        print("  %-9s %-13s %6d %-24s %s"
              % (label, cls, len(cl), ymd(ts[0]) + ".." + ymd(ts[-1]), cells))

    print()
    print("  z-statistics and two-sided p-values")
    print("  " + "-" * 84)
    print("  %-9s %s" % ("symbol", "  q=5d            q=10d           q=20d           q=60d"))
    for label, cls in ORDER:
        _, row = results[label]
        cells = ""
        for vr, z, p in row:
            mark = "*" if p < thresh else " "
            cells += "%+6.2f/%.4f%s " % (z, p, mark)
        print("  %-9s %s" % (label, cells))
    print("        * clears the Bonferroni threshold %.6f" % thresh)

    print()
    print("=" * 86)
    print("  CROSS-SECTIONAL SUMMARY  (descriptive - correlation between")
    print("  instruments means this is NOT itself a significance test)")
    print("=" * 86)
    for gi, q in enumerate(HORIZONS):
        nonfx = [(l, results[l][1][gi][0]) for l, c in ORDER if c != "fx_control"]
        fx    = [(l, results[l][1][gi][0]) for l, c in ORDER if c == "fx_control"]
        above = [l for l, v in nonfx if v > 1.0]
        vals  = sorted(v for _, v in nonfx)
        med   = vals[len(vals) // 2]
        mean  = sum(vals) / len(vals)
        fxm   = sum(v for _, v in fx) / len(fx)
        print()
        print("  q=%dd   non-FX: mean VR %.3f  median %.3f  |  %d of %d above 1.00"
              % (q, mean, med, len(above), len(nonfx)))
        print("          FX control sleeve mean VR %.3f" % fxm)
        if above:
            print("          above 1.00: %s" % ", ".join(above))

    print()
    print("  Per-class mean VR")
    classes = []
    for _, c in ORDER:
        if c not in classes:
            classes.append(c)
    print("  %-14s %s" % ("class", "  q=5d    q=10d   q=20d   q=60d"))
    for c in classes:
        members = [l for l, cc in ORDER if cc == c]
        cells = ""
        for gi in range(len(HORIZONS)):
            m = sum(results[l][1][gi][0] for l in members) / len(members)
            cells += "%7.3f " % m
        print("  %-14s %s  (n=%d)" % (c, cells, len(members)))
    print()


if __name__ == "__main__":
    main()

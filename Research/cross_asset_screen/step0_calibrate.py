#!/usr/bin/env python3
"""
Calibration of the variance-ratio estimator against series whose answer is known.

Every instrument in the screen came back below 1.00. That is either a real
market fact or a biased ruler. This tells them apart before anything is
reported.

  A. pure random walk        -> VR must centre on 1.00
  B. walk + trend persistence-> VR must come out clearly above 1.00
  C. walk + mean reversion   -> VR must come out clearly below 1.00
  D. random walk with volatility clustering (no predictability at all)
                             -> if this reads below 1.00, the sub-1 readings in
                                the real data are a volatility artifact, not
                                evidence about direction.
"""
import math
import random

from step0_screen import variance_ratio

N = 6000
SIMS = 200
HORIZONS = (5, 20, 60)


def walk(rng, n):
    p, x = [100.0], 0.0
    for _ in range(n):
        x += rng.gauss(0, 0.01)
        p.append(100.0 * math.exp(x))
    return p


def walk_ar(rng, n, phi):
    """AR(1) in returns. phi>0 = persistence, phi<0 = reversion."""
    p, x, prev = [100.0], 0.0, 0.0
    for _ in range(n):
        r = phi * prev + rng.gauss(0, 0.01)
        x += r
        prev = r
        p.append(100.0 * math.exp(x))
    return p


def walk_garch(rng, n):
    """Volatility clustering, zero predictability in direction."""
    p, x = [100.0], 0.0
    var, omega, alpha, beta = 1e-4, 1e-6, 0.10, 0.89
    prev = 0.0
    for _ in range(n):
        var = omega + alpha * prev * prev + beta * var
        r = rng.gauss(0, math.sqrt(var))
        x += r
        prev = r
        p.append(100.0 * math.exp(x))
    return p


def summarise(name, gen):
    rng = random.Random(7)
    cols = {q: [] for q in HORIZONS}
    for _ in range(SIMS):
        s = gen(rng)
        for q in HORIZONS:
            vr, _ = variance_ratio(s, q)
            cols[q].append(vr)
    out = ""
    for q in HORIZONS:
        v = sorted(cols[q])
        med = v[len(v) // 2]
        lo, hi = v[int(0.05 * len(v))], v[int(0.95 * len(v))]
        out += "  %5.3f [%.3f-%.3f]" % (med, lo, hi)
    print("  %-42s %s" % (name, out))


def main():
    print()
    print("  Median VR across %d simulated series of %d bars, [5th-95th pct]" % (SIMS, N))
    print("  %-42s %s" % ("", "    q=5d              q=20d             q=60d"))
    print("  " + "-" * 84)
    summarise("A. pure random walk (truth: VR = 1.00)",
              lambda r: walk(r, N))
    summarise("B. persistent, AR(1) phi=+0.05 (truth: >1)",
              lambda r: walk_ar(r, N, +0.05))
    summarise("C. reverting,  AR(1) phi=-0.05 (truth: <1)",
              lambda r: walk_ar(r, N, -0.05))
    summarise("D. vol clustering only, no direction edge",
              lambda r: walk_garch(r, N))
    print()


if __name__ == "__main__":
    main()

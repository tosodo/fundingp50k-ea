# Backtest Results — FP50K-EA

**Status: ACCEPTANCE: FAIL — the entry signal has no measurable edge.**

The strategy loses money, and 20 backtest variants have now established that the
losses do not come from the exits. With all trade management switched off and
the target measured honestly, the Asian-breakout-plus-retest entry wins less
often than the break-even hit rate at every stop distance tested. It broke none
of FundingPips' rules and still lost money, so it does not justify buying a
challenge. The standard below was written down *before* the first run, not
chosen afterwards to fit what came out.

---

## The bar a run has to clear

These come from the project briefing (Task 5) and are enforced in code by
`MQL5/Include/fp50k/BacktestValidator.mqh`. They are thresholds, not settings —
they are not to be relaxed to make a run pass.

| Criterion | Requirement | Why |
|---|---|---|
| Sample size | ≥ 300 closed trades | Below this, the results are noise |
| History | ≥ 3 years (2022–2025) | Must include several different market regimes |
| Tick quality | 99% ("Every tick based on real ticks") | Anything less flatters intraday stops |
| Max drawdown | < 8% | Leaves a 4% buffer inside the firm's 12% wall |
| Daily wall | Zero days reaching the firm's $2,000 limit | One breach ends a real challenge |
| Equity floor | Never below $44,000 | Same — one breach ends it |
| Phase 1 target | +10% cleared within 30 trading sessions | Otherwise the challenge times out |
| Win rate | ≥ 45% at 2:1 reward-to-risk | Below this the maths is negative regardless |

A run can break none of the firm's rules and still fail this table. Surviving
and passing are different things, and the validator reports them separately as
**RULE COMPLIANCE** and **ACCEPTANCE**.

---

## How to run it

Two ways. The script is the normal one.

### Headless (preferred)

```bash
./run_backtest.sh smoke   # 2025, 1-minute bars — minutes
./run_backtest.sh full    # 2022-2025, real ticks — hours
```

MetaTrader must be **closed** first; it is single-instance and a running copy
silently swallows the launch. The script refuses to start rather than hang.
It launches the tester, waits, then prints the validator summary and the path
to the MT5 HTML report. Settings are overridable by environment variable —
`BT_SYMBOL`, `BT_FROM`, `BT_TO`, `BT_MODEL`, `BT_DEPOSIT`, `BT_WAIT_SECS`.

The tester is a simulation. It places no orders on any account.

### By hand, in the MetaTrader window

1. Open MetaTrader 5 and make sure you are logged into the broker account.
2. Open the **Calendar** tab once and let it populate. If the terminal has no
   economic calendar data, the tester will trade straight through every news
   release and the results will be optimistic. The validator prints a warning
   if it sees zero blackouts across the whole run — treat that warning as a
   reason to stop and fix the calendar, not as good news.
3. Open **View → Strategy Tester** and set:
   - Expert: `fp50k\FP50K_EA`
   - Symbol: `EURUSD`, Period: `H1`
   - Date range: 2022.01.01 → 2025.12.31
   - Modelling: **Every tick based on real ticks**
   - Deposit: **50 000 USD**, Leverage as per the FundingPips account
4. Start the run. When it finishes, the summary appears at the bottom of the
   **Journal** tab, and is also written to the shared `Files` folder as
   `fp50k_backtest_summary.txt`.
5. Paste that summary into the "Run log" section below, save the MT5 HTML
   report alongside it, and commit.

**Important:** running the Strategy Tester does not place any real orders. It
is a simulation. Attaching the EA to a live chart with AutoTrading enabled is a
separate, deliberate step, and is not part of this process.

---

## Run log

Newest run first. Each entry records the settings as well as the result — a
number without the settings that produced it is not evidence of anything.

<!--
Template for each run:

### YYYY-MM-DD — EURUSD H1, 2022–2025, 99% ticks

Settings: InpRiskUSD=___, InpRRRatio=___, deposit $50,000, leverage 1:___

| Metric | Result | Required | Pass? |
|---|---|---|---|
| Closed trades | | ≥ 300 | |
| Net profit | | — | |
| Win rate | | ≥ 45% | |
| Profit factor | | — | |
| Max drawdown | | < 8% | |
| Worst daily loss | | < $1,800 | |
| Daily wall breaches | | 0 | |
| Equity floor breaches | | 0 | |
| Phase 1 reached | | ≤ 30 sessions | |
| News blackouts observed | | > 0 | |

RULE COMPLIANCE: ___
ACCEPTANCE: ___

Notes:
-->

### 2026-07-30 — EURUSD H1, 2025 only, 1-minute bars (SMOKE RUN)

Not an acceptance run. Deliberately cheap and low-fidelity — one year instead
of four, 1-minute bars instead of real ticks — to answer whether the EA trades
at all and whether the validator reports, before spending hours on the real
thing. It answered both, and also produced a result worth acting on.

Settings: deposit $50,000, leverage 1:100, 4,137 H1 bars, 984,920 modelled
ticks. Run time 14 seconds.

| Metric | Result | Required | Pass? |
|---|---|---|---|
| Closed trades | 112 | ≥ 300 | NO |
| Net profit | **-$5,544.16** | — | NO |
| Win rate | 60.7% | ≥ 45% | YES |
| Profit factor | 0.75 | > 1.0 to be viable | NO |
| Max drawdown | 12.97% | < 8% | NO |
| Worst daily loss | $1,020.01 | < $1,800 | YES |
| Daily wall breaches | 0 | 0 | YES |
| Equity floor breaches | 0 (low $44,455.84) | 0 | YES |
| Phase 1 reached | never | ≤ 30 sessions | NO |
| News blackouts observed | **0** | > 0 | NO |

RULE COMPLIANCE: PASS — no wall, stop or floor breach
ACCEPTANCE: FAIL — does not justify buying a challenge

**Notes — the diagnosis is in two numbers:**

| | |
|---|---|
| Average winning trade | **+$238.27** |
| Average losing trade | **-$479.64** |

That is roughly **0.5:1** reward-to-risk, against a design target of 2:1. The
entries are not the problem — a 60.7% win rate is good, and gross profit was
$16,202. The exits are: winners are being cut to about half a risk unit while
losers run to something near the full stop (largest loss -$534.59 vs largest
win +$431.84). Winning 6 times out of 10 does not survive losing twice as much
per loss as you make per win. Prime suspects are the partial close at 1R and
the ATR trailing stop in `FP50K_EA.mq5` — the trail is plausibly tightening
onto price and closing the runner before the 2.0–2.5× range target is reached,
which would remove exactly the large winners the 2:1 maths depends on.

**Zero news blackouts.** The Strategy Tester had no economic calendar data, so
this run traded straight through every release and never paid the cost of one.
That makes these numbers *optimistic* — and they are still a loss.

**Two caveats on the failing rows.** "Closed trades 112" fails the ≥ 300 bar
only because this is one year rather than four; it is not evidence about the
strategy. The 12.97% drawdown is the real failure: it is peak-to-trough equity
and it exceeds both the 8% target and the firm's 12% wall. Equity never
actually reached the $44,000 floor, so no rule was broken — but only because
the losing run started from a peak above the $50,000 opening balance. Starting
that same losing sequence from day one would have ended the challenge.

**Validator vs MT5 report:** the validator counted 103 closed trades and
-$4,962.19, MT5 counted 112 and -$5,544.16. The gap is the partial closes
being counted differently, plus positions still open when the run ended. Not
reconciled yet; MT5's figures are the ones quoted in the table above.

**Verdict: do not run the full 4-year acceptance test yet.** It would take
hours to confirm what this run already shows. Fix the exit logic first, re-run
the smoke test, and only go to full real ticks once average win exceeds average
loss.

---

### 2026-07-30 — Isolation test: is the edge in the exits or the entry?

All runs EURUSD H1, 2025, 1-minute bars, $50,000, risk $500/trade.

**Round 1 — vary the exits, keep the entry fixed (12 variants).** Trailing-stop
multiple swept 0.5→6.0, partial close 25%/50%, target 1:1→3:1. Every variant
lost. Profit factor stayed inside **0.69–0.83** throughout, and the average loss
sat at **$468–$481 (0.96R) in all twelve** — no exit setting can move it,
because losers always travel the full stop distance. When the whole plausible
range of an input barely moves the result, that input is not the cause.

**Round 2 — remove the exits entirely and test the entry alone.** Partial close,
breakeven and trailing all off, target measured from the entry so a nominal 2:1
actually pays 2:1. Each trade is then a clean +2R or −1R bet, and **break-even
requires a 33.3% hit rate.**

| Stop distance | Trades | Win % | PF | Max DD |
|---|---|---|---|---|
| far side of range (legacy geometry) | 58 | 29.3% | 0.66 | 13.06% |
| far side of range, honest 2:1 | 57 | 24.6% | 0.64 | 13.06% |
| 1.00× range from entry | 57 | 24.6% | 0.64 | 13.19% |
| 0.50× range from entry | 46 | 26.1% | 0.72 | 12.61% |
| 0.35× range from entry | 60 | 28.3% | 0.81 | 13.48% |
| 0.25× range from entry | 88 | 30.7% | 0.90 | 14.82% |
| 0.15× range from entry | 55 | 29.1% | 0.84 | 19.10% |

Profit factor improves monotonically as the stop tightens, peaks at **0.90** at
0.25× range, then **turns back down** at 0.15×. The curve converges below 1.0
rather than crossing it — and the improvement comes from cutting the size of
losses, not from the entry being right more often.

**Cross-check at a 1:1 target** (0.35× stop, break-even needs >50%):
45.8% win rate, PF 0.85. Also short of break-even.

**Conclusion: the entry signal is roughly a coin flip.** It misses the required
hit rate at 2:1 (best 30.7% vs 33.3% needed) and at 1:1 (45.8% vs 50% needed),
at every stop distance tried. No exit rule, position-sizing scheme or target
multiple can rescue a signal that does not predict direction. Per the stopping
rule agreed before the test, **tuning of this entry stops here.**

Two genuine defects were found and fixed along the way, independent of the
verdict above:

1. Risk was measured from the far side of the Asian range plus a 2-pip buffer
   while reward was measured from the near side, so a nominal 2.0 R:R delivered
   roughly 1.79:1. `InpConsistentTP` measures both from the entry.
2. Stop placement was hardcoded, so the single most important parameter in the
   strategy could not be tested. `InpStopRangeFrac` exposes it.

`InpUsePartial` / `InpUseBreakeven` / `InpUseTrail` were added so each trade-
management stage can be disabled independently — previously `InpPartialPct=0`
still triggered the breakeven move, which made the raw entry impossible to
measure. All defaults reproduce the original behaviour; the 227 unit tests pass
unchanged.

**Data availability (corrected):** EURUSD bar history is present on
FundingPips-SIM1 from 2012 and GBPUSD from 2014, so the 2022–2025 acceptance
window *is* reachable on bars. Real tick data is stored only for July 2026, so a
99%-tick-quality run still requires a large download first.

---

## Decision

**Is a challenge purchase justified by the backtest? — NO, not on current
evidence.**

Every run on record loses money, and the isolation test above shows why: the
entry signal does not predict direction well enough to pay for its own stop. It
stays "no" until a run appears above with ACCEPTANCE: PASS. These failing runs
are committed deliberately: the record of what did not work is part of the
evidence trail, and deleting it would make the eventual passing run look luckier
than it was.

The realistic paths from here are a different entry signal, or no challenge
purchase. Continuing to tune this one would produce a profitable-looking 2025
curve fitted to 2025's noise, which is worse than useless — it would buy a
challenge on evidence that does not generalise.

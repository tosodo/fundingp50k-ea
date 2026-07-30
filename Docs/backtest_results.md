# Backtest Results — FP50K-EA

**Status: NOT YET RUN.**

No historical backtest has been executed. Nothing in this repository yet
establishes that the strategy is profitable — the unit tests prove the
arithmetic and the wiring, and stop there. This file exists so the standard the
run has to meet is written down *before* the run, not chosen afterwards to fit
whatever came out.

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

MetaTrader's Strategy Tester needs a logged-in account and a real price
history, so this is a manual step in the MetaTrader 5 window — it cannot be
done headlessly.

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

*(No runs recorded yet.)*

---

## Decision

**Is a challenge purchase justified by the backtest? — Not yet decided.**

This stays "not yet decided" until at least one run appears above with
ACCEPTANCE: PASS. A failing run is still worth committing; the record of what
did not work is part of the evidence trail.

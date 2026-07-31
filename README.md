# FP50K-EA

Proprietary algorithmic trading system for the FundingPips $50,000 2-Step Flex challenge.

**Author:** Tee (aigentforce.io)  
**Built:** July 2026  
**Platform:** MetaTrader 5 / MQL5  
**Strategy:** Asian Liquidity Sweep & Fade — London session (07:00–17:00 UTC)  
**Instruments:** EURUSD (primary), GBPUSD (secondary)

All code in this repository is original work authored and owned by the account holder. This repository serves as timestamped proof of authorship for FundingPips EA verification purposes.

## Architecture

| File | Role | Sprint |
|------|------|--------|
| `MQL5/Include/fp50k/RiskManager.mqh` | Risk governor — all FP rules enforced | 1 |
| `MQL5/Include/fp50k/Clock.mqh` | Broker-server ↔ UTC reconciliation | 6 |
| `MQL5/Include/fp50k/AsianRange.mqh` | Session range calculator | 2 |
| `MQL5/Include/fp50k/SignalEngine.mqh` | Signal wiring + H4 filter | 2 |
| `MQL5/Include/fp50k/NewsFilter.mqh` | Calendar API integration | 3 |
| `MQL5/Experts/fp50k/FP50K_EA.mq5` | Main EA — execution layer | 3 |
| `MQL5/Include/fp50k/BacktestValidator.mqh` | Strategy Tester validation overlay | 4 |
| `MQL5/Scripts/fp50k/RiskManager_tests.mq5` | Unit tests for Risk Governor | 1 |
| `MQL5/Scripts/fp50k/SignalEngine_tests.mq5` | Unit tests for Signal Engine | 2 |
| `MQL5/Scripts/fp50k/NewsFilter_tests.mq5` | Unit tests for News Filter | 3 |
| `MQL5/Scripts/fp50k/BacktestValidator_tests.mq5` | Unit tests for the validator | 4 |
| `Docs/backtest_results.md` | Backtest acceptance criteria + run log | 4 |
| `sync_to_mt5.sh` | Copies source into the Wine MT5 install | 1 |
| `run_tests.sh` | Headless compile + test runner | 2 |
| `run_backtest.sh` | Headless Strategy Tester runner | 4 |

## Risk Parameters (FundingPips $50k 2-Step Flex)

Two sets of limits are enforced: fixed dollar amounts, and percentages of the
account. **Whichever is tighter binds.** Layering them this way can only ever
restrict the EA further — it can never grant it more room than either rule alone.

| Rule | Firm limit | Fixed internal | Percentage internal | **Binds at $50k** |
|------|-----------|----------------|---------------------|-------------------|
| Equity floor | $44,000 (12%) | $44,500 | 9% → $45,500 | **$45,500** |
| Daily loss | $2,000 | $1,800 hard / $1,000 soft | 4% → $2,000 | **$1,800** |
| Risk per trade | $1,000 | $1,000 ceiling | 0.75% of equity → $375 | **$375** |
| Session window | — | 07:00–17:00 UTC only | — | — |
| Max spread on entry | — | 20 pts EURUSD / 25 pts GBPUSD | — | — |

Position size is derived from **live equity**, not a fixed dollar figure, so it
shrinks automatically as the account draws down. It is capped again by whatever
is left of the day's loss allowance, so a day already most of the way to its
stop cannot be finished off by a full-size trade.

The daily allowance resets at **00:00 platform time (17:00 New York)** against
the **higher of balance or equity** — the firm's own high-water rule. Anchoring
to equity alone would quietly forgive money already lost on a day opened with a
position floating underwater.

## Strategy Overview

### Asian Liquidity Sweep & Fade (current)

The Asian range is measured 00:00–07:00 UTC, as before. What changed is which
side of the break the EA takes.

1. **Volatility coiling** — the range must be 8–40 pips *and* under 60% of the
   14-day daily ATR. A wide Asian session usually means a trend is already
   running, and fading a trend is how an account dies.
2. **Trend alignment** — H4 EMA(50). Longs only above it, shorts only below.
3. **The sweep (M5)** — a candle pokes at least 3 pips beyond the range edge
   and then *closes back inside*. That failed poke is the signal: the move
   existed to collect resting stop orders, not to go anywhere.
4. **Direction** — a sweep of the high is **sold**; a sweep of the low is
   **bought**. This is the opposite of the old breakout entry.
5. **Stop** — 2 pips beyond the sweeping candle's extreme wick.
6. **Target** — a fixed 2.5× the stop distance, measured from the entry.

### Session windows are inputs, not constants

`InpAsianStartH` / `InpAsianEndH` set the contraction window and
`InpHuntStartH` / `InpHuntEndH` the hours sweeps are looked for, all in UTC.
An end at or before the start crosses midnight and is handled.

They are inputs because *which* hours a fade works in is an empirical question,
and this project's own clock defect raised it by accident: for months the EA was
really measuring 21:00–04:00 UTC, and that window outperformed the 00:00–07:00
one it was meant to use. Supporting the wrap properly is what turns that
accident into a hypothesis testable on purpose.

The risk governor's gate is set from the same values in `OnInit`. If the two
drifted apart the EA would find setups and then be blocked from taking every
one of them — which looks like a strategy with no signals rather than a
misconfiguration.

### Legacy Asian Range Breakout (control, `InpEntryMode = 1`)

The original entry, unchanged and still reachable. It is known to have no edge —
twenty backtest variants established that it wins 24.6–30.7% at 2:1 where 33.3%
is break-even. It is retained deliberately: a new signal that cannot beat a
known-worthless one on the same data has not been shown to work.

## Setup

### Prerequisites
- MetaTrader 5 for Mac (Wine-hosted) installed in `/Applications`
- The `mql5-wine-qa` skill, for headless compiling

### Copy source into MetaTrader

```bash
./sync_to_mt5.sh
```

### Compile and run the test suites

MetaTrader must **not** be open — it is single-instance, and a running
copy silently swallows the headless launch.

```bash
./run_tests.sh
```

Compiles `FP50K_EA.mq5`, then runs every `*_tests.mq5`, failing the run on any
compile error, any warning, or any failed assertion. Pass a name to run one
suite: `./run_tests.sh SignalEngine_tests`.

The EA is only ever **compiled** by this script — never attached to a chart and
never run. Attaching it is a deliberate manual step in the MetaTrader GUI.

Current state: **362 assertions, 0 failures.**

| Suite | Assertions |
|-------|-----------|
| `BacktestValidator_tests` | 90 |
| `NewsFilter_tests` | 45 |
| `RiskManager_tests` | 117 |
| `SignalEngine_tests` | 110 |

`RiskManager_tests` runs as a script against a live terminal, so it is also the
only place the broker's true UTC offset can be read. It prints it as
`>>> BROKER UTC OFFSET (use for InpUtcOffsetH)` — the Strategy Tester cannot
work this out for itself.

### What the tests do and do not prove

They verify wiring and arithmetic: lot sizing, stop and target placement,
blackout windows, gate refusals, and — since Sprint 4 — the equity-curve
accounting that decides whether a simulated run survived the challenge.

They do **not** establish that the strategy is profitable. The first backtest
has now been run, and it lost money: **-$5,544 over 2025, profit factor 0.75.**
It broke none of FundingPips' rules and still failed the acceptance bar. Full
figures, the diagnosis, and what has to change are in
[`Docs/backtest_results.md`](Docs/backtest_results.md).

## Backtest validation (Sprint 4)

`BacktestValidator.mqh` is an observer. It never opens, closes or modifies a
position — it watches the equity curve during a Strategy Tester run and reports
two separate verdicts at the end:

- **Rule compliance** — did the run stay inside the *firm's* hard walls
  ($2,000 daily loss, $44,000 equity floor) at all times?
- **Acceptance** — does the sample also meet the minimum standard for buying a
  challenge: ≥ 300 trades, < 8% peak-to-trough drawdown, < 4% worst *daily*
  drawdown, ≥ 38% win rate at 2.5:1, and **positive expected value per trade**?

A run can pass the first and fail the second. Surviving is not passing.

The win-rate bar moved from 45% to 38% when the target moved from 2:1 to 2.5:1.
That is a restatement, not a relaxation — 45% at 2:1 is 0.35 R per trade and 38%
at 2.5:1 is 0.33 R, the same demand expressed for the new geometry. The EV floor
is what stops the lower headline number becoming a loophole: a strategy can
clear 38% and still lose money if its average loss runs bigger than the
arithmetic assumed, and that has already happened once on this project.

### The broker clock

Every session boundary in this EA is written in UTC; the broker stamps bars in
server time. Live, the gap is auto-detected. **Inside the Strategy Tester it
cannot be** — `TimeGMT()` returns the server clock there, so auto-detection
yields zero and every "UTC" window silently becomes a server-time window.

FundingPips-SIM1 measured **+3h in July**, so the winter baseline is 2 with
European summer time added on top (`InpUtcOffsetH=2`, `InpBrokerEuDst=true` —
both pinned by `run_backtest.sh`). A single fixed number would be an hour wrong
from November to March, which on a session strategy is not a rounding error.

`Clock.mqh` deliberately implements only the **EU** rule (last Sunday in March
to last Sunday in October, at 01:00 UTC). It needs no US DST arithmetic: the
daily reset keys off the broker's own midnight, and on an EET/EEST server that
*is* 17:00 New York in both regimes, because the European and US clocks shift
the seven-hour gap together.

### Backtest realism

The Strategy Tester will hand back results no live account could reproduce.
Three costs are forced on every run rather than left to its defaults:

| Cost | How it is applied | Default |
|------|-------------------|---------|
| Spread | Fixed in the tester config, broker's own spread ignored | 15 points (1.5 pips) |
| Latency | Tester execution delay | `BT_EXEC_DELAY` ms |
| Slippage | Charged inside the EA's own geometry — the tester has no slippage setting, so this is the only place it can live | 0.5 pips |

The slippage penalty shifts the reference price *against* the trade before the
stop and target are measured, so the stop lands nearer and the target further
than the quote implies. A run that only passes with these switched off has not
passed.

`run_backtest.sh` also verifies afterwards that the **news filter actually
fired**. Zero blackouts over a year of data almost certainly means the tester
had no calendar database — in which case the EA traded straight through every
release and the run is *optimistic*, not merely incomplete. That failure mode is
invisible unless something explicitly looks for it.

The EA only activates the validator inside the Strategy Tester, so it adds no
work to a live tick. It also supplies `OnTester()`, which returns zero for any
run that breached a wall — without that, an optimisation run will happily
select the parameter set that makes the most money by breaking the rule that
ends the challenge.

## Commit History

Commit timestamps serve as ownership proof for FundingPips verification:

- Sprint 1: RiskManager Layer + unit tests
- Sprint 2: AsianRange + SignalEngine + tests
- Sprint 3: Main EA + NewsFilter + ATR trailing + partial close
- Sprint 4: BacktestValidator + backtest acceptance criteria
- Sprint 5: Breakout entry tested to destruction across 20 variants and rejected
- Sprint 6: Pivot to Asian Liquidity Sweep & Fade; percentage risk layer;
  high-water daily reset; backtest realism costs (spread, latency, slippage)

## License

Proprietary — FundingPips challenge use only.

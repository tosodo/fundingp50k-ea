# FP50K-EA

Proprietary algorithmic trading system for the FundingPips $50,000 2-Step Flex challenge.

**Author:** Tee (aigentforce.io)  
**Built:** July 2026  
**Platform:** MetaTrader 5 / MQL5  
**Strategy:** Asian Range Breakout — London session (07:00–17:00 UTC)  
**Instruments:** EURUSD (primary), GBPUSD (secondary)

All code in this repository is original work authored and owned by the account holder. This repository serves as timestamped proof of authorship for FundingPips EA verification purposes.

## Architecture

| File | Role | Sprint |
|------|------|--------|
| `MQL5/Include/fp50k/RiskManager.mqh` | Risk governor — all FP rules enforced | 1 |
| `MQL5/Include/fp50k/AsianRange.mqh` | Session range calculator | 2 |
| `MQL5/Include/fp50k/SignalEngine.mqh` | Signal wiring + H4 filter | 2 |
| `MQL5/Include/fp50k/NewsFilter.mqh` | Calendar API integration | 3 |
| `MQL5/Experts/fp50k/FP50K_EA.mq5` | Main EA — execution layer | 3 |
| `MQL5/Scripts/fp50k/RiskManager_tests.mq5` | Unit tests for Risk Governor | 1 |
| `MQL5/Scripts/fp50k/SignalEngine_tests.mq5` | Unit tests for Signal Engine | 2 |
| `sync_to_mt5.sh` | Copies source into the Wine MT5 install | 1 |
| `run_tests.sh` | Headless compile + test runner | 2 |

## Risk Parameters (FundingPips $50k 2-Step Flex)

| Rule | Firm limit | Our internal limit |
|------|-----------|-------------------|
| Equity floor | $44,000 | $44,500 (emergency kill) |
| Daily loss wall | $2,000 | $1,800 (hard-stop) / $1,000 (soft-stop) |
| Max risk per trade | $1,000 | $400–600 recommended |
| Session window | — | 07:00–17:00 UTC only |
| Max spread on entry | — | 20 pips EURUSD / 25 pips GBPUSD |

## Strategy Overview

### Asian Range Breakout (Module A)
- Measures Asian session high/low (00:00–07:00 UTC)
- Enters on breakout + retest during London session (07:00–17:00 UTC)
- H4 trend alignment required
- Targets 2.0–2.5× range height with partial close at 1R + ATR trailing

### Market Structure Trend Follow (Module B)
- Identifies higher-high/higher-low (bullish) or lower-high/lower-low (bearish) on H1
- Enters on pullback to structure level
- GBPUSD and USDJPY

### XAUUSD Momentum (Module C)
- Phase 2 only, after Modules A+B proven

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

Runs every `*_tests.mq5`, compiling each first and failing the run on any
compile error, any warning, or any failed assertion. Pass a name to run one
suite: `./run_tests.sh SignalEngine_tests`.

Current state: **95 assertions, 0 failures.**

| Suite | Assertions |
|-------|-----------|
| `RiskManager_tests` | 36 |
| `SignalEngine_tests` | 59 |

## Commit History

Commit timestamps serve as ownership proof for FundingPips verification:

- Sprint 1: RiskManager Layer + unit tests
- Sprint 2: AsianRange + SignalEngine + tests
- Sprint 3: Main EA + NewsFilter + ATR trailing + partial close
- Sprint 4: BacktestValidator + optimization results

## License

Proprietary — FundingPips challenge use only.

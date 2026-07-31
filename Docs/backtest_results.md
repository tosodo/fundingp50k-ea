# Backtest Results — FP50K-EA

**Status: ACCEPTANCE: FAIL — for both entry models tested to date.**

Two hypotheses have now been measured to destruction on this data.

**The Asian breakout + retest (rejected 2026-07-30).** Twenty variants
established the losses were not in the exits. With management off and the
target measured honestly it won less often than break-even at every stop
distance tried.

**The Asian liquidity sweep & fade (measured 2026-07-31).** Its replacement,
and a large improvement — profit factor 0.92 against the breakout's 0.54 on
identical data with identical costs, and −$21 lost per trade against −$140. It
still misses break-even at 2.5:1 (26.0% vs 28.6% needed) and at 1:1 (43.2% vs
50%), and its drawdown is 15.6% against an 8% bar.

Neither breaks a FundingPips rule. Neither justifies buying a challenge. The
standard below was written down *before* the first run, not chosen afterwards
to fit what came out.

**A measurement defect was found and fixed mid-round.** `TimeGMT()` returns
server time inside the Strategy Tester, so every "UTC" session window was
really a broker-time window — a three-hour shift in summer, two in winter,
affecting every run this project made before 2026-07-31. It is fixed
(`Clock.mqh`, `InpUtcOffsetH`), and the whole grid was re-measured. Correcting
it made both strategies look *worse*, not better; the earlier figures are kept
below and marked, because a superseded number that is still on the record is
what makes the corrected one credible.

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
| Worst daily drawdown | < 4% | Buffer inside the firm's 5% daily rule |
| Daily wall | Zero days reaching the firm's $2,000 limit | One breach ends a real challenge |
| Equity floor | Never below $44,000 | Same — one breach ends it |
| Phase 1 target | +10% cleared within 30 trading sessions | Otherwise the challenge times out |
| Win rate | ≥ 38% at 2.5:1 reward-to-risk | Break-even at 2.5:1 is 28.6% |
| Expected value | Positive dollars per trade | The one number that cannot be argued with |

A run can break none of the firm's rules and still fail this table. Surviving
and passing are different things, and the validator reports them separately as
**RULE COMPLIANCE** and **ACCEPTANCE**.

### Why the win-rate line moved from 45% to 38%

Because the target moved from 2:1 to 2.5:1, not because 45% was hard to reach.

- 45% at 2:1 → 0.45 × 2 − 0.55 = **0.35 R per trade**
- 38% at 2.5:1 → 0.38 × 2.5 − 0.62 = **0.33 R per trade**

The same demand, restated for the new geometry. The **expected value** row is
what stops the lower headline number becoming a loophole: a strategy can clear
38% and still lose money if its average loss runs bigger than the arithmetic
assumed. That is not hypothetical — the smoke run below won **60.7%** of its
trades and lost $5,544.

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
`BT_SYMBOL`, `BT_FROM`, `BT_TO`, `BT_MODEL`, `BT_DEPOSIT`, `BT_WAIT_SECS`,
`BT_SPREAD`, `BT_EXEC_DELAY`.

The tester is a simulation. It places no orders on any account.

#### The three costs that are forced on every run

The Strategy Tester's defaults produce fills no live account gets. Left alone
it uses the broker's own current spread, no latency, and no slippage at all.
So the script and the EA impose all three:

| Cost | Where it lives | Default | Why it cannot live elsewhere |
|---|---|---|---|
| Spread | `Spread=` in the tester config | 15 points (1.5 pips) | The tester cannot vary spread by hour, so the choice is between always-on and never-on. Only one of those errs safely. |
| Latency | `ExecutionMode=` in the tester config | `BT_EXEC_DELAY` ms | — |
| Slippage | `InpSlippagePips` inside the EA | 0.5 pips | The tester has **no** slippage setting. The EA shifts its reference price against the trade before measuring the stop and target, so the stop lands nearer and the target further — the same effect an adverse fill has live. |

A run that only clears the bar with these switched off has not cleared the bar.

#### Why every input is pinned on every run

`run_backtest.sh` writes **all** EA inputs into `[TesterInputs]` every time, even
the ones a variant does not care about. This is not tidiness.

An input left out of that section does **not** fall back to the value compiled
into the EA — MT5 reuses whatever that input was set to the last time the
Strategy Tester ran. On 2026-07-31 `InpRRRatio` was changed from 2.0 to 2.5 in
the source; a run that omitted it silently executed at **2.0**, and the output
was initially written up here as a 2.5:1 measurement. The tell was two variants
that differed only in a value neither of them set agreeing to the cent.

That is the worst failure mode a backtest has: it does not error, it produces a
confident number that describes settings other than the ones in the code. The
fix is that the script's `BASE_INPUTS` list is now the single source of truth
for a run, and `BT_INPUTS` overrides it key by key. **Keep `BASE_INPUTS` in step
with the EA's input block** — an input added to the EA and not added there
inherits the same bug.

#### The news-filter check

After every run the script confirms the news filter **actually fired**. Zero
blackouts across a year is not a clean sheet — it almost certainly means the
tester had no calendar database, in which case the EA traded straight through
every release and the result is *optimistic*. That failure mode is invisible
unless something explicitly looks for it, so the script now does, and says
`NOT VERIFIED` rather than staying quiet.

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

### 2026-07-31 — Asian Liquidity Sweep & Fade, first run of the new entry

The breakout entry was retired after 20 variants established it had no edge
(see the isolation test further down). This is its replacement measured on the
same data, with the same tooling, and for the first time with realistic costs
forced on: **1.5 pip spread, 0.5 pip assumed slippage.**

Settings: EURUSD H1, 2025.01.01–2025.12.31, 1-minute bars, deposit $50,000,
leverage 1:100, `InpRiskUSD=375` (0.75% of equity), `InpRRRatio=2.5`,
`InpNewsBlockMin=15`, `Spread=15 points`.

#### As configured — all trade management on

| Metric | Result | Required | Pass? |
|---|---|---|---|
| Closed trades | 203 | ≥ 300 | NO |
| Net profit | **−$1,511.78** | positive | NO |
| Win rate | 63.5% | ≥ 38% | yes |
| Profit factor | 0.94 | > 1.0 | NO |
| **EV per trade** | **−$7.45** | positive | **NO** |
| Max drawdown | 13.58% | < 8% | NO |
| Worst daily drawdown | 2.96% | < 4% | yes |
| Daily wall breaches | 0 | 0 | yes |
| Equity floor breaches | 0 | 0 | yes |
| Phase 1 reached | never | ≤ 30 sessions | NO |
| News blackouts observed | 0 | > 0 | **NOT VERIFIED** |

RULE COMPLIANCE: **PASS** — no wall, hard stop or floor breach.
ACCEPTANCE: **FAIL**.

The 63.5% win rate is not a win rate at 2.5:1. Average win was **$190.51**
against an average loss of **$352.53** — a realised ratio of about 0.54:1. The
partial close, breakeven move and trailing stop are cutting winners off long
before the 2.5:1 target, exactly as they did to the old entry. A headline win
rate quoted from this run would be meaningless.

#### The entry on its own — all management off

Every trade becomes a clean +2.5R or −1R bet, so the win rate alone answers the
question. **Break-even at 2.5:1 is 28.6%.** All inputs pinned (see the harness
note above — the first attempt at this table was measured with the wrong R:R).

| Variant | Trades | Win % | PF | EV/trade | Max DD | Daily DD |
|---|---|---|---|---|---|---|
| sweep-fade, clean 2.5:1 | 168 | **26.8%** | 0.98 | −$4.22 | 23.25% | 2.96% |
| sweep-fade, 2:1 (needs > 33.3%) | 160 | 30.6% | 0.97 | −$8.02 | 20.44% | 2.96% |
| sweep-fade, 1:1 (needs > 50%) | 134 | 45.5% | 0.94 | −$11.46 | 12.11% | 2.96% |
| sweep-fade, limit entry at the swept edge | 120 | 27.5% | 0.93 | −$14.99 | 10.92% | 2.07% |
| **CONTROL** — legacy breakout, same costs | 86 | 25.6% | 0.86 | −$36.95 | 13.80% | 2.31% |

#### What this actually says

**The sweep entry is a clear improvement on the breakout, and it still does not
clear the bar.** Both halves matter.

The improvement is not marginal. Profit factor 0.98 against the breakout's
0.83, and −$4.22 lost per trade against −$43.82. It also produces more than
twice as many setups. Fading the failed poke is measurably a better idea than
buying the break — that hypothesis is now supported.

But it misses at every ratio tested, and it misses *consistently*:

| Ratio | Needed | Measured | Verdict |
|---|---|---|---|
| 2.5:1 | 28.6% | 26.8% | below |
| 2:1 | 33.3% | 30.6% | below |
| 1:1 | 50.0% | 45.5% | below |

Three independent geometries all landing 2–5 points short is the signature of
an entry that is genuinely close to neutral rather than one that needs a better
target. Profit factor of 0.98 says the same thing: this is a coin flip paying
its own transaction costs, not an edge waiting to be unlocked.

The drawdown is the harder problem, and it is not close. 23.25% peak-to-trough
with management off and 13.58% with it on, against an 8% acceptance bar and a
9% challenge floor. Even if the EV problem were solved, this equity curve would
not survive the challenge.

**Costs are not an excuse.** They were switched on deliberately because every
earlier round ran without them and was therefore flattering. A strategy that is
only profitable at zero spread is not profitable.

The limit-entry variant is the one row worth keeping. Worse EV (−$14.99) but
**less than half the drawdown** — 10.92% against 23.25%, and the best daily
figure in the table at 2.07%. It fills less often, at better prices. That is a
drawdown lever, not an edge, and it does not make the strategy profitable.

#### Two harness defects this round exposed

Both were silent, both produced confident wrong numbers, and both are now
fixed. Recording them because each would otherwise recur.

**1. Unpinned tester inputs.** Covered above. The first version of the table in
this section reported the 2.5:1 row as 30.6% / PF 0.97; it had actually run at
2:1. The true 2.5:1 figures are 26.8% / PF 0.98.

**2. `TimeGMT()` returns server time inside the Strategy Tester.** Confirmed
from the tester log on 2026-07-31:

```
[FP50K] CLOCK | server=2025.01.01 00:00:00 gmt=2025.01.01 00:00:00 offset=0h | TESTER
```

`CAsianRange::ServerUtcOffset()` computed `TimeCurrent() - TimeGMT()`, which is
correct live and **zero in the tester**. So the "00:00–07:00 UTC" Asian window
was really 00:00–07:00 *broker server* time, and the "07:00–17:00 UTC" London
gate likewise. On a GMT+2/+3 server that is a two- to three-hour shift, and it
applied to **every backtest this project has ever run — the breakout rounds
included.**

The offset is now injectable (`InpUtcOffsetH`, `FpUtcOffsetSecs()`), all
session checks route through `FpNowUtc()`, and the EA prints a loud warning
when it auto-detects 0h inside the tester.

**This means the numbers above describe the right strategy measured over the
wrong hours.** They are superseded by the corrected run below.

### 2026-07-31 (later) — the same grid, with the clock actually correct

Broker offset measured live against FundingPips-SIM1 as **+3h in July**, i.e. a
winter baseline of 2 with European summer time on top. Now pinned by
`run_backtest.sh` as `InpUtcOffsetH=2` / `InpBrokerEuDst=true`, and confirmed in
the tester log:

```
[FP50K] CLOCK | detected=0h applied=2h (override) | asian 00:00-07:00 UTC = 2:00-9:00 server | TESTER
```

Same settings otherwise: EURUSD H1, 2025, 1-minute bars, 1.5 pip spread,
0.5 pip slippage, all inputs pinned.

| Variant | Trades | Win % | Break-even | PF | EV/trade | Max DD | Daily DD |
|---|---|---|---|---|---|---|---|
| sweep-fade, clean 2.5:1 | 131 | 26.0% | 28.6% | 0.92 | −$21.49 | 15.59% | 2.88% |
| sweep-fade, 1:1 | 88 | 43.2% | 50.0% | 0.85 | −$30.05 | 10.77% | 2.34% |
| sweep-fade, limit entry | 131 | 27.5% | 28.6% | 0.93 | −$13.27 | 9.62% | 2.20% |
| **CONTROL** — legacy breakout | 28 | 17.9% | 28.6% | 0.54 | −$140.37 | 9.97% | 2.46% |
| sweep-fade, all management on | 166 | 59.0% | — | 0.89 | −$15.40 | 15.20% | 2.33% |

#### Correcting the clock made the strategy look WORSE

Directly comparable, both at a clean 2.5:1:

| | Trades | Win % | PF | EV/trade |
|---|---|---|---|---|
| wrong clock (00:00–07:00 **server**) | 168 | 26.8% | 0.98 | −$4.22 |
| correct clock (00:00–07:00 **UTC**) | 131 | 26.0% | 0.92 | −$21.49 |

The accidental window — 21:00–04:00 UTC in summer — was catching a more
fade-able session than the one the strategy is actually written to trade, and
it was doing so on 28% more setups. That is worth knowing as a *hint about
which hours to test*, and it is emphatically not a reason to keep the bug: a
result you cannot explain and did not intend is not evidence, however
favourable it looks.

The verdict is unchanged and now more clearly supported. The sweep entry still
beats the breakout control by a wide margin (PF 0.92 vs 0.54, −$21 vs −$140 per
trade), and still misses break-even at both ratios tested. The limit-entry
variant remains the best row on every measure except trade frequency — PF 0.93,
the smallest loss per trade, and by far the lowest drawdown at 9.62%.

Note the control collapsed to 28 trades and PF 0.54 under the corrected clock.
The breakout entry was even more dependent on the accidental window than the
fade was, which retrospectively makes the 2026-07-30 rejection of it *stronger*,
not weaker.

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

### Where this stands after the sweep & fade round (2026-07-31)

The answer is still no, and it is now better supported: two structurally
opposite entries — buy the break, and fade the break — have both been measured
short of break-even on the same data.

The clock defect that made the first pass of this round unreliable has been
fixed and the grid re-measured, so the verdict rests on correctly-timed data.

Two things must **not** happen next. No challenge is bought. And the sweep
parameters are not tuned to close the remaining 2.6-point gap — with five knobs
and one year of data, a passing configuration can always be found, and it would
be fitted to 2025's noise. That stopping rule has now been invoked twice and
holds here too.

One genuinely open lead, and it is a lead about *hours*, not parameters. The
buggy window (21:00–04:00 UTC) beat the intended one (00:00–07:00 UTC) on every
measure — more setups, higher profit factor, a fifth of the loss per trade. The
disciplined way to use that is a deliberate sweep of the session window as an
input, on the corrected clock, with the same pre-agreed acceptance bar. That is
testing a hypothesis the data raised, not tuning until something passes. It is
also the only remaining idea here that is not already known to fail.

Independently of the outcome, the infrastructure is now worth more than the
strategy: a risk governor with the firm's rules layered two ways, a validator
that reports EV and daily drawdown, a harness that pins its inputs and charges
realistic costs, and 346 passing assertions. A new signal hypothesis plugs into
that in an afternoon. That is the durable asset here.

# Strategy Lab

A bench for answering one question per hypothesis: **does this entry predict
direction well enough to beat its own break-even win rate, once realistic costs
are charged?**

Everything here is simulation. No EA in this folder has ever been attached to a
chart, and attaching one is a manual step taken deliberately in the MetaTrader
GUI — never automatically.

---

## Why the lab is separate from FP50K-EA

FP50K-EA carries a full prop-firm risk governor: daily stop, kill switch,
session window, news filter, break-even moves, partial closes, trailing stops.
Every one of those changes what happens to a trade **after** the entry decision.

Run a new signal through all of that and a negative result is unattributable —
the signal might be sound and the manager might be cutting it off, or the other
way round. So the lab strips the management out. Each trade is a flat-sized
win-or-lose bet with a fixed stop and a fixed target. That is the only
arrangement in which the win rate answers the question being asked.

**Compliance is a second gate, applied only to hypotheses that survive the
first.** There is no point asking whether a strategy fits inside a 4% daily
drawdown limit before knowing whether it makes money at all.

## The three costs, always on

| Cost | How it is applied | Value |
|---|---|---|
| Spread | Forced in the tester, broker's own spread ignored | 15 points = 1.5 pips |
| Latency | Tester execution delay | configurable, `LAB_EXEC_DELAY` |
| Slippage | Charged inside the EA — the tester has no setting for it | 0.5 pips per entry |

A run that only passes with these switched off has not passed.

## Known limitations of every number on this page

- **No news filter.** The lab EA trades straight through high-impact releases.
  This makes results **optimistic** on exactly those bars.
- **Closed-trade drawdown.** Drawdown is measured trade to trade, so it does
  not see how far a position went against us before recovering. The real
  figure is deeper than the one reported.
- **One data source.** All data is the FundingPips-SIM feed via this MT5
  install. Multi-broker robustness is *reasoned about*, not measured.

---

## The bar, agreed before each run

Written down first, deliberately. With a handful of knobs and one sample of
data, a passing configuration can always be found — and it will be fitted to
noise and fail live. The point of writing the bar first is that a disappointing
result cannot quietly move it.

| # | Test | Pass condition |
|---|---|---|
| 1 | Structural edge | Mean result per trade > 0 R |
| 2 | Statistical significance | p < 0.05, two-sided t-test on the per-trade R series |
| 3 | ±25% parameter shift | Every shifted variant still has mean R > 0 |
| 4 | Multi-timeframe | Mean R > 0 on M15, M30 and H1 |
| 5 | Multi-instrument | Mean R > 0 on a second, separately-tested instrument |
| 6 | Cost realism | Still mean R > 0 at 2.5 pips spread |
| 7 | Portfolio fit | Drawdown correlation < 0.5 vs other strategies |

Test 7 **cannot currently be measured** — it needs the daily return series of
the strategies being compared against, and those do not exist in this repo. It
is reported as *not measured*, never as an estimate.

A hypothesis that fails any of tests 1–6 is rejected and the next one starts.
No tuning to close a small gap.

---

## Hypothesis H1 — Trend Pullback Continuation

**Status: REJECTED 2026-08-02 at test 1.** Mean result per trade was **−0.0937 R**.
Tests 2–7 were not run: significance is a question about a positive number.

### The idea

The two hypotheses this project tested before H1 were both range/reversion
ideas on the Asian session, and both came back short of break-even. H1 is the
structural opposite: it only ever trades *with* the prevailing direction, and
only after price has pulled back into it.

The claim being tested is the oldest one in trend following — that a market
above its long moving average keeps going up more often than a coin flip, and
that the cheapest place to join is a pullback rather than a breakout.

### The rules, in full

1. **Regime.** On the higher timeframe, an EMA(200). Price closing above it
   means long-only; below means short-only. A close exactly on it means no
   trade. There is never a counter-trend position.
2. **Pullback.** On the entry timeframe, an EMA(50) marks the zone.
3. **Trigger.** One closed bar that does two things at once: trades *into* the
   EMA(50), and closes back *out* of it on the regime's side.
4. **Stop.** 2.0 × ATR(20) from the fill.
5. **Target.** 2.0 × the stop distance. Break-even win rate: **33.33%**.
6. **One position at a time.** Structural, not a tuned limit — two overlapping
   trades in the same direction are one bet held twice, and would make the
   trade series statistically dependent, which breaks the significance test.

### Why one bar and not "wait for confirmation"

An arm-then-wait state machine needs an expiry — *armed for N bars* — and N has
no structural justification at any value. Every free parameter is somewhere a
result can be fitted to the sample. The one-bar form has none.

### Parameters

All round numbers with decades of conventional use behind them. None was
searched for on this data.

| Parameter | Value | ±25% shift range (test 3) |
|---|---|---|
| Regime EMA | 200 | 150 / 250 |
| Pullback EMA | 50 | 38 / 62 |
| ATR period | 20 | 15 / 25 |
| ATR stop multiple | 2.0 | 1.5 / 2.5 |
| Reward : risk | 2.0 | fixed — this sets the break-even bar |
| Risk per trade | 1.0% of the **starting** deposit, flat | fixed |

Risk is a flat percentage of the *starting* deposit rather than of live equity
on purpose. That keeps every trade the same dollar size, so the profit series
is a clean run of R multiples. Compounding would make late trades count for
more than early ones and quietly distort the statistics.

### Results

Nothing goes in this table that was not produced by a backtest.

| Run | Instrument | Period | Trades | Win % | PF | Mean R | p-value | Max DD % |
|---|---|---|---|---|---|---|---|---|
| h1eur | EURUSD H1 / H4 regime | 2024.01.01–2025.12.31 | 291 | 30.93 | 0.867 | −0.0937 | 0.2487 | 28.43 |

### Why it failed, and what the failure actually says

Break-even was 33.33%. It won 30.93%. Net −$13,627 on a $50,000 deposit.

The mechanics were correct — the exported trade file shows every loss landing
at −1.00 R and every win at +2.00 R, so stops and targets executed as designed.
The failure is in the entry, not the plumbing.

**The important number is the p-value: 0.2487.** The strategy did not lose
*significantly*. It lost the way a coin flip loses once you charge it a spread.
Splitting the result apart:

| Source | Contribution |
|---|---|
| Win rate 30.93% at 2:1 geometry | −0.072 R |
| Spread, entry slippage, stop fill | −0.022 R |
| **Total** | **−0.094 R** |

A 2:1 target with an ATR stop and a *random* entry lands near 33% by
construction. At 30.93%, this entry performed slightly **worse than random** —
and the costs then finished it off.

So the claim under test — *price above a long EMA continues after a pullback* —
is not merely too weak to pay for its costs on EURUSD H1. It has no measurable
directional content at this horizon at all. That is a cleaner answer than a
marginal loss would have been: there is nothing here to rescue by tuning, which
is exactly why no tuning was attempted.

**No ±25% shift runs were performed.** Shifting the parameters of a signal with
no directional content searches for a configuration that got lucky on this
sample. Some variant would have come back positive. It would have meant nothing.

---

## Hypothesis H2 — Asian Range Compression Breakout

**Status: REJECTED 2026-08-02 at test 1.** Mean result per trade was **−0.2527 R**.
But see *What actually went wrong* — the rejection is real and the money was
really lost, yet this run did **not** fairly test the volatility claim. The
design fault it exposed is what H3 is built to fix.

### The idea

H1 tested whether *direction* persists. It does not, at least not measurably on
EURUSD H1. H2 therefore stops betting on direction as such and bets on
**volatility** instead.

Volatility clustering is the single best-evidenced statistical property of
financial prices: quiet periods are followed by quiet periods, violent ones by
violent ones, far more often than chance allows. It is not a folk belief about
markets — it is the reason an entire family of forecasting models exists.

The claim under test is a consequence of it: *a market that has been unusually
still overnight is storing a move, and the side it first breaks decisively is
more informative than a coin flip.*

Note what is **not** being claimed. Not that the market goes up. Not that a
trend continues. Only that the first decisive break of a compressed range
carries some directional information — enough to clear a 33.33% bar after costs.

### The rules, in full

All hours are **GMT**, measured at runtime, not server hours. See "Why GMT"
below.

1. **Overnight range.** The highest high and lowest low between 00:00 and 07:00
   GMT. Fixed once 07:00 passes; never revised.
2. **Compression gate.** That range must be *narrower* than the average of the
   previous 20 days' ranges. Equal is not narrower. Until 20 days of history
   exist, no trade is taken at all.
3. **Breakout window.** 07:00 to 12:00 GMT — the London morning.
4. **Trigger.** The first M15 bar to *close* beyond the range. Above the high is
   long, below the low is short. Closing exactly on the level is a touch, not a
   break.
5. **Stop.** 1.5 × ATR(20).
6. **Target.** 2.0 × the stop distance. Break-even win rate: **33.33%**.
7. **One attempt per day**, taken or missed. A blocked entry is not retried —
   retrying would sample the same setup twice and inflate the trade count.
8. **Flat at 20:00 GMT.** Structural, not trade management: the claim concerns a
   move that develops across London and New York. Past that, the question has
   been answered either way.
9. **One position at a time**, for the same reason as H1.

### Why close-based and not touch-based

A wick through a level and back is the market rejecting that level; a close
beyond it is the market accepting it. There is also an honesty reason: with
1-minute OHLC modelling the tester cannot reliably say whether the high or the
low came first inside a bar. Any rule that depends on intrabar ordering is
therefore partly measuring the simulator. A close does not.

### Why GMT rather than server time

MetaTrader stamps every bar in the broker's own server time, and brokers sit on
different offsets and shift them at daylight saving. Hard-code the hours to one
broker's clock and the same strategy measures a *different session* on a
different feed — so the multi-broker robustness test would fail for a clock
reason and be read as a strategy reason. The offset is measured at runtime from
`TimeCurrent()` against `TimeGMT()` and re-checked every bar, which also picks
up the DST changeover in the middle of a backtest.

### Why the compression gate counts as part of the hypothesis

Plain "break the overnight range" is one of the oldest published intraday ideas
in FX and conditions on nothing. Compression *is* the structural claim; without
it there is no reason to expect anything. It costs exactly one round number — a
20-day average — and that number was not searched for on this data.

### Parameters

| Parameter | Value | ±25% shift range (test 3) |
|---|---|---|
| Range window | 00:00–07:00 GMT | 7h → 5h / 9h |
| Breakout window | 07:00–12:00 GMT | 5h → 4h / 6h |
| Compression benchmark | 20 days | 15 / 25 |
| ATR period | 20 | 15 / 25 |
| ATR stop multiple | 1.5 | 1.1 / 1.9 |
| Reward : risk | 2.0 | fixed — this sets the break-even bar |
| Flat hour | 20:00 GMT | 15:00 / 25:00 → capped at 23:00 |
| Risk per trade | 1.0% of the **starting** deposit, flat | fixed |

### Expected trade count

The compression gate takes roughly half of all days by construction, and a
compressed range is not always broken within the window. Over two years of
weekdays that suggests **150–250 trades** — enough for a meaningful t-test, but
thinner than H1's 291. If the run returns far fewer, the result is inconclusive
rather than negative, and that will be reported as such.

### Results

| Run | Instrument | Period | Trades | Win % | PF | Mean R | p-value | Max DD % |
|---|---|---|---|---|---|---|---|---|
| h2eur | EURUSD M15 | 2024.01.01–2025.12.31 | 257 | 24.90 | 0.663 | −0.2527 | 0.0020 | 69.90 |

### What actually went wrong

Worse than H1: −$32,476 and a 70% drawdown. The trade file is clean — every
loss −1.00 R, every win +2.00 R — so again the plumbing was correct.

The diagnosis is in the entry log. **The stops were 4.4 to 8.0 pips wide.**
1.5 × ATR(20) on M15 EURUSD is about five pips. The always-on costs are
1.5 pips of spread plus 0.5 pips of slippage — **two pips, against a five-pip
stop.**

That is not a small handicap. MetaTrader fills a long at the ask but triggers
both its stop and its target on the bid, so the entry sits two pips above the
level that decides the outcome:

| | Bid movement required |
|---|---|
| To lose (stop out) | **3.5 pips** |
| To win (hit target) | **13.0 pips** |

A pure random walk wins that bet **21.2%** of the time. The strategy needed
**33.3%** to break even in cash, because a stop-out still costs the full 1 R
whatever the market moved. It scored **24.9%**.

**So the entry did beat a coin flip — by 3.7 percentage points, when it needed
12.** There may be a faint directional signal in a compressed-range break. It
was never going to be visible through a cost that consumed 36% of the stop.

**This run therefore rejects the strategy, but does not settle the hypothesis.**
Those are different statements, and collapsing them would be the mistake. What
it settles is a design fault: *a stop sized by a short-timeframe ATR is not a
stop, it is a coin toss with a fee attached.*

### A counter bug, recorded rather than quietly fixed

The end-of-run diagnostics read `Days seen: 580 | compressed: 1036` — more
compressed days than days, which is impossible. The day counter incremented
once per day correctly; the compression counter incremented once per **bar** in
the 07:00 hour, so up to four times a day.

This is a logging defect only. It sits downstream of every trading decision and
touched no entry, stop, target or size. The trade count of 257 comes from the
exported trade file, not from these counters. Fixed in H3.

---

## Hypothesis H3 — Range-Anchored Compression Breakout

**Status: under test.**

### What changed, and why it is not tuning

Identical to H2 in every respect but one: **the stop goes on the opposite side
of the overnight range**, instead of 1.5 × ATR below the entry.

This needs stating carefully, because "the result was bad so I changed a
parameter and ran it again" is exactly the process that produces strategies
which work perfectly until they meet real money.

That is not what happened here:

- **No number was tuned.** The ATR stop was not widened from 1.5 to some larger
  value that happened to test better. The ATR stop was **deleted**. H3 has one
  *fewer* free parameter than H2, not a better-chosen one.
- **The new stop is not a parameter at all.** It is the range itself — the very
  level the strategy claims to be trading. If a break of the overnight high
  means anything, the trade is wrong when price returns to the overnight low.
  There is nothing to choose.
- **The change was decided by the diagnosis, not by the P&L.** The cost
  arithmetic above is true regardless of whether H2 made or lost money; a
  five-pip stop paying two pips of cost is broken on its face.

The stop now scales with the thing being traded. Overnight ranges here average
about 20 pips, so the two pips of cost fall from 36% of the risk to roughly
10%. The random-walk win rate rises from 21% to about 29% — still short of the
33.3% break-even bar, which is as it should be: **the strategy must still find
a real edge to pass.** The change removes a handicap that made passing
arithmetically impossible; it does not hand it a pass.

### The rules, in full

Unchanged from H2 except rule 5. All hours GMT.

1. **Overnight range.** Highest high and lowest low, 00:00–07:00 GMT.
2. **Compression gate.** Range narrower than the previous 20 days' average.
3. **Breakout window.** 07:00–12:00 GMT.
4. **Trigger.** First M15 bar to *close* beyond the range.
5. **Stop — CHANGED.** The opposite side of the range. Long: the range low.
   Short: the range high. No buffer, because a buffer would be a free parameter.
6. **Target.** 2.0 × the stop distance. Break-even win rate: **33.33%**.
7. **One attempt per day**, taken or missed.
8. **Flat at 20:00 GMT.**
9. **One position at a time.**

ATR is no longer used anywhere in H3.

### Parameters

| Parameter | Value | ±25% shift range (test 3) |
|---|---|---|
| Range window | 00:00–07:00 GMT | 7h → 5h / 9h |
| Breakout window | 07:00–12:00 GMT | 5h → 4h / 6h |
| Compression benchmark | 20 days | 15 / 25 |
| Reward : risk | 2.0 | fixed — this sets the break-even bar |
| Flat hour | 20:00 GMT | fixed |
| Risk per trade | 1.0% of the **starting** deposit, flat | fixed |

Three shiftable parameters, down from four.

### Results

| Run | Instrument | Period | Trades | Win % | PF | Mean R | p-value | Max DD % |
|---|---|---|---|---|---|---|---|---|
| h3eur | EURUSD M15 | 2024.01–2025.12 | 257 | 37.35 | 0.880 | −0.0709 | 0.3520 | 20.38 |

**REJECTED** — fails test 1 (mean R must be positive). Tests 3–6 were not run;
shifting the parameters of a signal that loses money is a search for a lucky
configuration, not a robustness check. Test 7 remains *not measured*.

### The fix worked. The strategy still failed.

Against H2 on identical data, every geometric symptom improved:

| | H2 | H3 |
|---|---|---|
| Mean R | −0.2527 | **−0.0709** |
| Profit factor | 0.663 | **0.880** |
| Max drawdown | 69.90% | **20.38%** |
| Net P&L | −$32,476 | **−$9,107** |

The cost diagnosis was correct and the range stop was the right correction. It
recovered about three-quarters of the loss. It did not produce an edge, and the
reason is now visible rather than inferred.

### Why the 37.35% win rate is not the number that matters

The headline win rate counts any trade closed for a profit. But 59 of the 257
trades never reached a stop or a target at all — they were still open at 20:00
GMT and were flattened wherever price happened to be. Splitting the outcomes:

| Exit | Trades | Share | Avg R | Total R |
|---|---|---|---|---|
| Target hit | 50 | 19.5% | +2.00 | +99.80 |
| Stop hit | 148 | 57.6% | −1.00 | −147.73 |
| Flattened at 20:00 | 59 | 23.0% | +0.50 | +29.72 |
| **All** | **257** | | **−0.0709** | **−18.21** |

The R multiples are clean: every stop paid almost exactly −1R and every target
almost exactly +2R, so the sizing and the exits are doing what they should.

**Among the 198 trades that actually resolved, the strategy won 25.25%.** It
needed 33.33%. The timed exits were the only thing keeping the result close to
break-even — they contributed +29.7R, and without them the loss roughly doubles.

### The entry is now the problem, and there is nothing left to blame

H3's stops average roughly 19 pips against 2 pips of cost, so the handicap that
made H2 unwinnable is gone. Running the same arithmetic on the new geometry: a
long fills at the ask, both exits trigger on the bid, so the bid must fall 17
pips to lose but rise 40 to win. **A random walk wins 29.8% of those.**

The strategy won 25.25%.

For the third hypothesis running, the entry signal shows no directional content —
and this time it cannot be explained away by costs. H1 landed slightly below a
coin flip, H2 was untestable, H3 landed 4.5 points below one.

The stop-width figure is indicative, not exact: it is the mean of the 22 entries
visible in the log tail, not all 257. `sl_pips` is now written into the trade
export so the next run can state this precisely instead of estimating it.

### One observation, deliberately not acted on

The 20:00 flat — a rule adopted for realism, not for profit — was the single
most profitable component in the run at +0.50R per trade. That is interesting,
and it is exactly the kind of in-sample detail that turns a losing strategy into
an overfitted one if you build the next hypothesis around it. It is recorded
here as an observation. It is not evidence, and H4 does not use it.

---

## Hypothesis H4 — Overextension Fade

**Status: measured, result below.**

### The idea

A move that carries price a long way from its own recent mean in a short time
is mostly liquidity, not information. Somebody had to fill a large order, or a
cluster of stops was reached, and the price paid to do that is not the price the
market actually agrees on. Price should therefore return toward the mean more
often than a coin flip says it should.

### Where this idea came from, stated plainly

H1 bet on continuation after a pullback and won 30.9% where it needed 33.3%.
H3 bet on continuation after a range break and won 25.3% of its resolved trades
against a random-walk baseline of about 29.8%. **Both continuation bets landed at
or below random**, and a continuation bet losing to a random walk is the same
observation as a reversion bet beating one.

So this is the direction the lab's own evidence points — not a fresh guess. It
is also worth being blunt about the cost of that: the hypothesis was suggested by
these two results, which means a PASS here carries less weight than a pass would
have carried for H1, and the out-of-sample checks matter correspondingly more.
Two runs is a thin basis for a directional claim.

### Why H1 bars and not M15

This is the H2 lesson applied before the run rather than after it. On M15 EURUSD
a 2.0 × ATR stop is roughly seven pips against two pips of cost. On H1 bars
ATR(20) is around three times larger, so the same multiple gives a stop of tens
of pips and costs fall to well under a tenth of the risk. **The timeframe is a
consequence of the cost arithmetic, not a setting that was tried until it
worked.**

### The rules, in full

- Entry timeframe H1. All decisions read bar 1, never the forming bar 0.
- Mean: 20-period simple moving average of the close.
- Volatility: ATR(20).
- **Signal:** a closed bar whose close is more than **2.0 × ATR** from the mean.
  Below it → buy. Above it → sell.
- **Target: the mean itself**, frozen at signal time.
- **Stop: 2.0 × ATR** beyond the fill.
- Give up after **24 bars** — one day of H1 bars.
- Entries only between **07:00 and 20:00 GMT**.
- One position at a time. 1.0% of the starting deposit risked per trade, flat.

### Why the target is the mean and not a ratio

The hypothesis is "price returns to its mean", so the mean is the target — it is
supplied by the setup, not chosen. That removes reward:risk as a free parameter,
which is exactly where H1 and H2 each carried a number that could have been
tuned. At the entry threshold the geometry is about 1:1, so the break-even win
rate is near 50%, but the realised ratio floats with the actual distance to the
mean and is recorded per trade.

### Why the trading-hours limit is not a filter

Every run forces one fixed spread. Outside London and New York the real spread is
materially wider, so a trade taken at 03:00 GMT would be charged a cost the live
market would not have offered. Restricting **entries** to the hours where the
assumed spread is honest makes the measurement mean what it says. Positions
opened inside the window are *not* force-closed when it ends — the 24-bar limit
is what ends a trade, and cutting it at the window edge would mix in a second
rule.

A session window chosen because it tested well would be a tuned parameter in a
structural disguise. This one is chosen for a cost-realism reason that can be
checked without looking at any result.

### Parameters

| Setting | Value | Why this value |
|---|---|---|
| Mean | SMA 20 | round; the standard short lookback |
| ATR | 20 | same window, so stretch and volatility agree |
| Entry stretch | 2.0 × ATR | round, inside the 1.5–2.5 band |
| Stop | 2.0 × ATR | round; symmetric with the entry threshold |
| Hold limit | 24 bars | one day, matching the claim's horizon |
| Entry hours | 07:00–20:00 GMT | the hours where the forced spread is realistic |
| Risk | 1.0% flat | same as H1–H3, so results are comparable |

Free parameters: the entry multiple and the stop multiple. That is two — one more
than H3, one fewer than H2. Nothing here was searched over this data.

### Results

| Run | Instrument | Period | Trades | Win % | PF | Mean R | p-value | Max DD % |
|---|---|---|---|---|---|---|---|---|
| h4eur | EURUSD H1 | 2024.01.01–2025.12.31 | 561 | 44.03 | 0.949 | −0.0273 | 0.5579 | 26.32 |

Net −$7,653.99. Std dev 1.1022R. 515 trading days. Annualised Sharpe −0.414.
t = −0.586 on 560 degrees of freedom.

**Verdict: REJECT** on test 1. The average trade loses money, so the significance
test does not need to be argued about — a p-value only tells you whether a number
is distinguishable from zero, and this one is on the wrong side of zero to begin
with.

### The one genuinely new result in four hypotheses

H4 is the first hypothesis whose entry is not beaten by a coin flip.

That claim needs care, so here is the exact arithmetic. Under a driftless random
walk with a stop at distance R and a target at distance W, the probability of
reaching the target first is R/(R+W), and the expected outcome is therefore
**exactly zero R by construction** — for any reward:risk ratio, including H4's
floating one. Zero is the honest baseline, not a win rate.

Costs are 1.5 pips of forced spread plus 0.5 pips of charged slippage, against a
stop that averaged 25.3 pips. Adding that drag back trade by trade — the `sl_pips`
column added to the export after H3 is what makes this exact rather than an
estimate from an average:

| Series | N | Mean R | t | p (2-sided) |
|---|---|---|---|---|
| Net, as traded | 561 | **−0.0273** | −0.586 | 0.5579 |
| Cost drag added back | 561 | **+0.0618** | +1.330 | 0.1841 |

Mean cost drag: 0.0891R per trade.

So the raw entry is worth about **+0.06R**, on the right side of zero, where H1
and H3 were both on the wrong side of it. That is the first time the lab has
produced a directional signal that points the way the hypothesis predicted.

**It is still a reject, for two independent reasons.**

1. **p = 0.18 even before costs.** A +0.06R mean with a 1.10R standard deviation
   over 561 trades is not distinguishable from zero. This is not "nearly
   significant" — it is what a genuinely edgeless rule looks like most of the
   time. The pre-agreed bar is p < 0.05 and it is not close.
2. **The edge is smaller than the cost of collecting it.** Even taking +0.0618R
   at face value, the 0.0891R of spread and slippage eats it and leaves a loss.
   An edge that only exists in a world without trading costs is not an edge.

### What must not be done with this result

The obvious move is to widen the stop so the cost share falls — a 50-pip stop
would halve the drag to 0.045R and turn the net mean positive. **That would be
tuning a parameter until the sign flips, on the same data that produced the
observation, and it is refused.** Two further problems with it, independent of
the tuning objection: the +0.0618R itself has a confidence interval that
comfortably contains zero, so there may be nothing there to rescue; and a wider
stop changes the reward:risk geometry, which changes the random-walk baseline
too, so it is not a free improvement.

The legitimate version of that question is whether the effect survives on data
that did not produce it. That is what H5 tests.

### A mistake the assertions caught

The first version of the code comment claimed slippage *widens* the reward on a
fade. It does the opposite: a long fade buys below the mean, so paying more moves
the fill closer to the target and the reward shrinks. The assertion that encoded
the wrong belief failed, which is how the error surfaced. It is left in the test
script as a worked case rather than deleted.

A second assertion failed on a floating-point boundary — `mean − 2 × ATR` can
compute one rounding step either side of a price that is logically identical to
it, so "exactly on the threshold" was decided by luck rather than by the rule.
The comparison now carries a tolerance of one millionth of the ATR: on a 25-pip
ATR that is 0.000025 of a pip, far below any broker's quote step and far above
double rounding error. It makes the boundary decidable and cannot change a trade.

---

## The offline screener, and what it did to H4

Four hypotheses had been judged on two years of one instrument — 300 to 600
trades. That is enough to detect a large edge and nowhere near enough to
separate a small one from noise, which is exactly where H4 ended up.

The install already held 8.5 years of H1 bars for EURUSD, GBPUSD and EURGBP,
each carrying the broker's own recorded spread on every bar. `tools/screen.py`
reads them and simulates a hypothesis in seconds instead of minutes, at roughly
twenty times the sample.

**It is a screen, not a verdict.** An H1 bar cannot say whether the stop or the
target was reached first when both sit inside its range; MT5's 1-minute
modelling often can. Every ambiguous bar is therefore scored as the **loss** —
a deliberate bias against the strategy, because a filter should err towards
sending a real edge for confirmation rather than towards passing a fake one.

### Calibration against MT5, before believing anything it says

| Metric | MT5 `h4eur` | Screener, same window |
|---|---|---|
| Bars | 12,416 | 12,417 |
| Stretch signals | 1,077 | 1,075 |
| Trades | 561 | 555 |
| Max stop width | 109.6 pips | 109.6 pips |
| Mean stop width | 25.33 pips | 25.3 pips |
| Win rate | 44.03% | 41.98% |
| Mean R | −0.0273 | −0.0630 |

The identical maximum stop width is the strongest single piece of evidence that
the ATR and the signal rule agree bar for bar. The residual gap in mean R runs
in the expected direction — the screener is the pessimistic one — and is the
size the tie-break rule predicts. **Calibrated: it tracks the tester to about
0.04 R, always on the conservative side.**

Building it exposed a real lookahead bug in the first draft, worth recording
because it inflated the trade count by a fifth: after a position exited inside a
bar, the screener let a new trade open at *that same bar's open* — a price that
had already passed by the time the slot was free. The EA cannot do this, because
it sees the open position when the bar opens and returns immediately.

### What it did to H4

The promised out-of-sample test, at **zero cost** — no spread, no slippage — so
the only question is whether the signal predicts direction at all:

| Instrument | Trades | Mean R (zero cost) | p |
|---|---|---|---|
| EURUSD | 2,385 | −0.0165 | 0.4680 |
| GBPUSD | 2,446 | −0.0214 | 0.3472 |
| EURGBP | 2,260 | +0.0253 | 0.2905 |

With real spreads charged, all three lose significantly (−0.062, −0.076,
−0.147 R).

**H4's +0.0618 R gross edge was noise.** Its own p-value of 0.18 said so at the
time; 8.5 years and three instruments confirm it. This is also the clearest
possible vindication of refusing to widen the stop to make the sign flip —
there was never anything there to rescue.

---

## Hypothesis H5 — Overextension split by tick volume

**Status: measured. REJECTED.**

### The idea, and why it is not just a filter bolted onto H4

H4 assumed every large move away from the mean is liquidity. The obvious
objection is that some are information — a release, a rate decision — and those
should keep going, not snap back. H4 mixed the two and measured the average of
them, which is roughly zero.

Tick volume is the one information source in these files the lab had never
touched, and it is not derived from price. The economic story is standard:
informed trading arrives as order flow, so a stretch on heavy flow is more
likely to be news, and a stretch on light flow is more likely to be somebody's
order being filled into a thin book.

**The prediction was written down before the run, and it was two-sided:**

- quiet signal bar → the move reverts → the fade **makes** money;
- busy signal bar → the move continues → the fade **loses** money.

Both halves had to hold, on all three instruments. A two-sided prediction is
much harder to satisfy by accident than "some subset was profitable", and that
is the whole reason for stating it that way. Adding filters to a dead strategy
until one pays is dredging; predicting the sign of *both* subsets in advance is
a test.

Volume is compared against the median of the preceding 20 bars — a round
lookback matching the mean, and the median rather than a percentile that could
be tuned. The signal bar is never included in the window it is judged against.

### Result, zero cost, 8.5 years

| Instrument | Subset | Trades | Mean R | p | Prediction |
|---|---|---|---|---|---|
| EURUSD | quiet | 281 | **+0.1608** | 0.0103 | held |
| EURUSD | busy | 2,260 | −0.0316 | 0.1780 | held, weakly |
| GBPUSD | quiet | 299 | **−0.0224** | 0.7100 | **failed** |
| GBPUSD | busy | 2,334 | −0.0211 | 0.3691 | held, weakly |
| EURGBP | quiet | 202 | +0.1271 | 0.0907 | held |
| EURGBP | busy | 2,191 | **+0.0224** | 0.3581 | **failed** |

**Verdict: REJECT.** The prediction held completely on one instrument out of
three. GBPUSD's quiet subset — the half that was supposed to be the edge — lost
money.

### Why the one significant cell is not an edge

EURUSD's quiet subset shows +0.16 R at p = 0.0103, which is the best-looking
number the lab has produced. Three reasons it is not evidence:

1. **Six tests were run.** With six comparisons the threshold for a single
   result to mean anything is 0.05 ÷ 6 = 0.0083. It does not clear that.
2. **It is a small, selected slice** — 281 trades out of 2,541, about 11%. A
   2 ATR move is nearly always a busy bar, so "quiet overextension" is a rare
   oddity. A small, unusual subset carrying all of the return is the standard
   shape of a noise finding.
3. **It does not replicate.** GBPUSD, the closest comparable instrument, gives
   the opposite sign on the same subset.

Any one of the three would be enough on its own. It is left in the table rather
than dropped, because the temptation to build H6 on top of it is exactly what
the pre-written prediction exists to resist.

---

## Where five rejections leave the search

| # | Mechanism | Gross edge (costs removed) | Verdict |
|---|---|---|---|
| H1 | Trend pullback continuation | below random | REJECT |
| H2 | Range breakout, M15 | destroyed by costs | REJECT |
| H3 | Range breakout, clean geometry | below random | REJECT |
| H4 | Overextension fade | ≈ 0.00 R over 7,091 trades | REJECT |
| H5 | Overextension fade split by volume | ≈ 0.00 R, no replication | REJECT |

The pattern is not that these strategies were badly built or badly costed. H3
and H4 both had clean cost geometry, and H4's failure was measured across three
instruments and 8.5 years. **The pattern is that hourly-bar direction on major
FX pairs is not predictable from the price series itself**, and four different
ways of asking that question have now returned approximately zero before any
cost is charged.

That is a real finding, and it is the kind that should redirect a search rather
than be answered with a sixth variation on the same theme.

---

## Running the bench

```bash
./sync_to_mt5.sh
LAB_PERIOD=M15 ./run_lab.sh 'lab\LAB_SessionBreakout' h2eur
```

Each EA declares its **own complete input list** inside `run_lab.sh`. Adding a
new strategy means adding a case there; the script refuses to run an EA it has
no input list for, rather than running it with the previous strategy's inputs.

Environment overrides: `LAB_SYMBOL`, `LAB_PERIOD`, `LAB_FROM`, `LAB_TO`,
`LAB_MODEL`, `LAB_SPREAD`, `LAB_EXEC_DELAY`, `LAB_WAIT_SECS`.

### Screening before testing

```bash
python3 tools/screen.py "$MT5/EURUSD_H1_201801020100_202607211800.csv" --spread-pips 0 --slippage-pips 0
```

Run the zero-cost version **first**. It answers "does this signal predict
direction at all", and if the answer is no then the cost arithmetic is beside
the point and no MT5 run is warranted. Only a hypothesis that shows a positive
gross edge across more than one instrument is worth a tester slot.

Parameter overrides go in the third argument, semicolon separated:

```bash
./run_lab.sh 'lab\LAB_TrendPullback' h1slow 'InpEmaTrend=250;InpAtrStopMult=2.5'
```

**Every input is written to `[TesterInputs]` on every run.** An input left out
does *not* fall back to the value compiled into the EA — MT5 silently reuses
whatever it was set to last time. That defect cost this project a day on
2026-07-31, when a run reported as 2.5:1 had actually executed at 2.0:1.

**Sync first, compile second — never the other way round.** `sync_to_mt5.sh`
used `rsync --delete`, which removes anything in the destination that is not in
the repo. Compiled `.ex5` binaries only ever exist in the destination, so a sync
run *after* a compile silently deleted the binary and H3's first launch aborted
before it started. Two changes now make the ordering un-get-wrong-able:

- the sync excludes `*.ex5`, so a compiled binary is never collateral damage;
- `run_lab.sh` refuses to run a `.ex5` that is older than its own `.mq5`.

The second guard is the important one. A missing binary announces itself; a
*stale* one does not — it runs happily and reports a result for code that no
longer exists. That is the same class of failure as the `[TesterInputs]` defect
above: not a crash, but a confident wrong answer. Both are now hard stops.

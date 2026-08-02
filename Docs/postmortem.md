# Post-mortem: why this experiment did not succeed

**Date closed:** 2026-08-02
**Status:** research programme terminated. Infrastructure retained.

---

## The one-paragraph version

Over roughly eight months this project tried to find a systematic trading edge
strong enough to pass a FundingPips $50,000 two-step challenge. It did not find
one. Five structurally different entry mechanisms were measured at approximately
**zero** expectancy with trading costs removed entirely, across 8.5 years and
three currency pairs. A follow-up screen across 19 instruments and six asset
classes found no trend persistence anywhere at horizons up to three months. No
challenge was ever purchased and no expert advisor was ever attached to a live
chart, so the total realised loss is time.

**Two distinct things went wrong, and this document separates them deliberately:**

1. **The market did not contain what we were looking for.** That part of the
   work is sound, and the negative result is real and reusable.
2. **The research process had a structural defect that made termination
   inevitable regardless of the market.** That part is our fault, it was not
   noticed until the end, and it is the more valuable finding of the two.

---

## 1. What was actually under test

Stated once, plainly:

> Can a mechanical rule, reading only the price series of liquid instruments,
> predict short-term direction well enough to beat its own break-even win rate
> after realistic costs — and do so with a drawdown shallow enough to survive a
> prop firm's 8% total / 5% daily limits?

Everything below is evidence against that claim.

---

## 2. The evidence

Three independent layers, each stricter than the last. The layering matters:
each was designed to rule out the excuse that would otherwise be available for
the previous layer's failure.

### Layer 1 — full-strategy backtests (July 2026)

Two structurally *opposite* hypotheses on the same market structure, so that
"you picked the wrong direction" could not survive as an explanation.

| Hypothesis | Result |
|---|---|
| Asian range breakout + retest | 20 variants tested. Win rate 24.6–30.7% at 2:1, where **33.3% is break-even.** Profit factor 0.86. |
| Asian liquidity sweep & fade (buy the *failed* break) | Better, still negative. Profit factor 0.92–0.98. |

All three available levers were then measured separately:

- **Exits** — no material effect.
- **Entry direction** — fade beats breakout; both negative.
- **Session window** — the largest of the three, **$29.84 per trade** between
  the best and worst of six windows tested. Still no pass.

The best configuration found (23:00–06:00 UTC contraction) produced the
project's first positive expectancy at **+$2.98/trade, PF 1.01** — and failed
anyway on a **28.34% drawdown against an 8% limit**, with a win rate still below
break-even.

Out-of-sample follow-up on that configuration:

| Test | Profit factor | Expectancy | Max drawdown | Verdict |
|---|---|---|---|---|
| EURUSD 2024 (out-of-sample) | 1.03 | +$7.14 | 11.40% | Fails on drawdown |
| GBPUSD 2025 (out-of-sample) | 1.17 | +$45.61 | 14.61% | Fails on drawdown |

**Drawdown failed in every configuration ever tested** — both entry models,
every session window, every instrument.

*Source: [`Docs/backtest_results.md`](backtest_results.md), commits `c60c857`,
`f2144dc`, `b6c98af`, `3342086`, `06c492a`.*

### Layer 2 — isolation bench, all costs removed (August 2026)

Layer 1 left one escape route open: perhaps the signals were fine and the risk
management was strangling them, or perhaps costs were eating a small real edge.
The bench closed both. Every trade became a flat ±R bet — no break-even moves,
no partials, no trailing, no news filter — and every hypothesis was **also run
with spread and slippage set to zero.**

| # | Mechanism | Trades | Mean R | p-value | Verdict |
|---|---|---|---|---|---|
| H1 | Session breakout (London open, H1/H4) | 291 | −0.0937 | 0.2487 | REJECT |
| H2 | Trend pullback to moving average (M15) | 257 | −0.2527 | 0.0020 | REJECT |
| H3 | Volatility breakout from compression (M15) | 257 | −0.0709 | 0.3520 | REJECT |
| H4 | Mean reversion from stretch (H1) | 561 | −0.0273 | 0.5579 | REJECT |
| H5 | H4 split by tick volume | ~2,500 × 3 pairs | ≈ 0 | — | REJECT |

**The finding that generalises.** H4's most out-of-sample form — 8.5 years,
three pairs, **zero cost charged**:

| Instrument | Trades | Mean R (zero cost) | p |
|---|---|---|---|
| EURUSD | 2,385 | −0.0165 | 0.4680 |
| GBPUSD | 2,446 | −0.0214 | 0.3472 |
| EURGBP | 2,260 | +0.0253 | 0.2905 |

With costs removed entirely the results move to **approximately zero, not into
profit.** This is the single most important number in the project. It means the
failure was never "a small edge eaten by costs" — there was no directional
information in the signal to begin with, and every hour that could have been
spent optimising spread, execution or broker choice would have been wasted.

*Source: [`Docs/strategy_lab.md`](strategy_lab.md), commit `3437909`.*

### Layer 3 — cross-asset trend-persistence screen (August 2026)

Layer 2 left one escape route: perhaps hourly FX specifically is hostile, and
the answer is a different asset class held for longer — the direction the
published momentum literature points. This was tested as a cheap gate **before**
any code was written.

Method: Lo–MacKinlay variance ratio on daily closes. **Above 1.00 = the market
trends; 1.00 = coin flip; below 1.00 = it snaps back.** 19 instruments, six
asset classes, 12–36 years of history, horizons of 5/10/20/60 trading days.
76 tests, so the corrected significance threshold is 0.05 ÷ 76 = **0.000658**.

Mean variance ratio by asset class:

| Class | 5 days | 10 days | 20 days | 60 days |
|---|---|---|---|---|
| Equity indices (7) | 0.900 | 0.846 | 0.831 | **0.776** |
| Metals (3) | 0.944 | 0.908 | 0.895 | 0.891 |
| Energy (3) | 0.924 | 0.893 | 0.896 | 0.977 |
| Rates (1) | 0.936 | 0.896 | 0.922 | 0.879 |
| Crypto (1) | 0.988 | 1.025 | 1.092 | 1.265 |
| FX (control, 4) | 0.857 | 0.822 | 0.808 | 0.840 |

**Not one of the 76 tests clears the corrected threshold, in either direction.**
At the 60-day horizon only 3 of 15 non-FX instruments sit above 1.00 (copper,
Brent, bitcoin) and none significantly.

**The pass/fail rule was written down before the test was run.** It required a
clear majority of non-FX instruments above 1.00 at 20 and/or 60 days, plus at
least three significant instruments spanning two asset classes. Actual result:
**3 of 15, and zero significant.** Not a near miss.

#### The measuring instrument was itself checked first

Every one of 19 instruments came back below 1.00. That is exactly the pattern a
*broken tool* would produce, so the tool was run against four synthetic markets
whose correct answer was known in advance:

| Test series (known truth) | 5 days | 20 days | 60 days |
|---|---|---|---|
| A. Pure random walk (truth: 1.00) | 1.002 | 0.992 | 0.990 |
| B. Genuinely persistent (truth: >1) | 1.085 | 1.092 | 1.094 |
| C. Genuinely mean-reverting (truth: <1) | 0.925 | 0.902 | 0.898 |
| **D. Volatile but unpredictable (truth: 1.00)** | **0.996** | **0.989** | **0.974** |

Test D was the strongest available counter-explanation — that violent markets
might fake a low reading without any real predictability. **They do not.** And
note that real equity indices read 0.776 at 60 days, a *larger* deviation than
the deliberately mean-reverting synthetic series produced at 0.898. The
readings are real structure, not an artefact.

*Source: [`Research/cross_asset_screen/`](../Research/cross_asset_screen/) —
scripts, captured output, and reproduction instructions.*

---

## 3. Why it failed: the reasons in the market

**3.1 There is no directional information in the price series alone.** At
hourly horizons in major FX, and at daily-to-quarterly horizons across 19
instruments in six asset classes. Five mechanism families and 76 statistical
tests agree. This is the most heavily searched dataset in finance and the prior
against a fresh retail discovery in it was always severe; the project has now
measured that prior rather than assuming it.

**3.2 Costs were never the binding constraint.** Removing them entirely moves
the result to zero, not to profit. Any plan of the form "tighter spreads, better
broker, faster execution" was dead before it was proposed.

**3.3 Drawdown failed independently of edge.** Every configuration ever tested
breached the 8% total limit, including the two out-of-sample runs that were
mildly *profitable*. A prop challenge is not a bet on expectancy alone; a real
but small edge with an 11% drawdown still fails, and would still have failed
even if 3.1 had gone the other way.

**3.4 The one direction the data does point is the opposite one.** Multi-week
mean reversion in equity indices (0.776 at 60 days, strengthening with horizon)
is the largest consistent deviation from randomness found anywhere in this
project. **That is an observation, not a strategy.** An unconditional variance
ratio below 1.00 says nothing about whether the effect survives spread,
overnight financing, entry timing, or a drawdown cap. It is recorded here as a
lead for someone else, not as a recommendation.

---

## 4. Why it failed: the reasons in the method

This section is the point of the document. The market findings above would be
worth little if the process that produced them was itself unsound — and in three
specific ways, it was.

**4.1 The wrong decision standard was imported, and the swap was never
declared.** The project applied Bonferroni-corrected significance across 76
tests — a threshold of p < 0.000658. That is the standard for *publishing a
discovery*: convincing a hostile stranger that an effect exists in nature. It is
**not** the standard for *placing a bet*, which requires only positive expected
value and survivable downside. An academic decision rule was applied to a
commercial problem without anyone saying so out loud. Under the correct
framework, several results (H4's +0.0618 R gross, EURUSD's quiet subset at
p = 0.0103) would still have been rejected — but for stated reasons, not by
importing a bar borrowed from a different discipline.

**4.2 The bar rose with every test, by construction.** Each rejection was
written into the domain priors, making the next idea more likely to be rejected
before testing. The multiple-comparison budget only ever grows. **A process
whose answer converges on "no" as a function of how long it runs has stopped
measuring the market and started measuring itself.** By month eight, no
hypothesis could realistically have passed. That is a defect in the design of
the programme, not a fact about markets.

**4.3 There was a stopping rule for each test, but never for the programme.**
Every individual hypothesis had a pass condition written down in advance — this
was done well and consistently, and it is why the results above can be trusted.
But the programme as a whole had no defined point at which the *search itself*
was abandoned. Each rejection generated the next hypothesis, and the final
output of the last review was another review. **Analysis is free, which is
exactly why it never stops.** Time was spent deliberating in order to avoid
spending money deciding, and this was mistaken for rigour.

**4.4 One recommendation issued during this project was simply wrong, and is
corrected here.** A research audit concluded that the fix was to *change the
instrument set* — that FX was the weak link and indices, metals and commodities
would show the trend persistence FX lacked. Layer 3 measured this and it is
false. FX sits squarely inside the non-FX range (control sleeve 0.808–0.857
against a non-FX mean of 0.879–0.922). There was nothing special about
currencies. **Any advice of the form "switch instruments and hold longer" is
unsupported by this project's own data.**

---

## 5. Errors found and fixed along the way

Recorded because a post-mortem that lists only other people's mistakes is not
credible.

- **A lookahead bug** in the first bench build re-entered at a bar open that had
  already passed, inflating results by roughly **0.10 R** — a larger effect than
  any edge the project ever found. Caught by comparing trade counts against the
  Strategy Tester (664 vs 561).
- **A labelling error** ran what was reported as a single-instrument test as a
  **two-symbol portfolio**: both `InpTradeEURUSD` and `InpTradeGBPUSD` were
  enabled while the chart was EURUSD. The headline "PF 1.01 on 2025 EURUSD" was
  never an EURUSD result — EURUSD alone is PF 0.86.
- **A tempting significant cell** (EURUSD quiet hours, +0.1608 R, p = 0.0103)
  was rejected for three independent reasons: it fails the k=6 correction
  threshold of 0.0083, it rests on 11% of the sample (281 of 2,541 trades), and
  it does not replicate on GBPUSD, which gives the opposite sign. It is left
  visible in [`strategy_lab.md`](strategy_lab.md) rather than deleted, as the
  canonical local example of a fluke.
- **A stopping rule was agreed before each test and invoked three times**,
  including on the one tempting positive row. Not tuning to close a small gap is
  the reason these negative results mean anything.

---

## 6. What survives

The durable asset is the infrastructure, not any strategy:

- A prop-firm **risk governor** with the firm's rules encoded as both dollars
  and percentages, tighter always binding.
- A **validator** reporting expectancy and daily drawdown.
- A **headless Wine/MT5 harness** that pins its inputs and charges realistic
  spread and slippage.
- An **isolation bench** that answers "does this entry predict direction" in an
  afternoon, with the trade-management confound removed.
- **362 passing offline assertions.**
- A **measured negative result** that rules out a very large fraction of retail
  systematic trading, obtained without paying a challenge fee.

A new signal hypothesis plugs into this in an afternoon. That was the point of
building it, and it still holds.

---

## 7. Claims left on the record

Stated so they can be proven wrong by anyone who cares to:

1. Hourly-to-daily direction of major FX pairs, derived from price alone,
   carries no extractable information. Zero-cost expectancy across three pairs
   and 8.5 years: −0.0165 R, −0.0214 R, +0.0253 R, none significant.
2. No unconditional trend persistence exists in any of 19 tested instruments
   across six asset classes at horizons up to 60 trading days.
3. Equity indices are the *most* mean-reverting class tested, and become more so
   as the horizon lengthens (0.900 → 0.846 → 0.831 → 0.776).

**The honest limit on claim 2:** the horizon grid stops at 60 days (about three
months), while the published time-series-momentum literature centres on a
**12-month** lookback. This screen does not reach that horizon and therefore does
not refute that literature. What it does show is the trajectory moving *away*
from 1.00 as the horizon lengthens in every class except energy and crypto — the
opposite of what one would expect if persistence were waiting at 12 months.
Extending the grid *after* seeing a null result would also be textbook lookback
shopping, which is why it was not done.

---

## 8. Reproducing the evidence

Layers 1 and 2 are in [`Docs/backtest_results.md`](backtest_results.md) and
[`Docs/strategy_lab.md`](strategy_lab.md), with the MQL5 sources in `MQL5/` and
the harness scripts in the repository root.

Layer 3:

```bash
cd Research/cross_asset_screen
python3 step0_fetch.py       # downloads daily history into step0_data/
python3 step0_screen.py      # prints the 76-test grid
python3 step0_calibrate.py   # validates the estimator on known synthetic series
```

Python 3 standard library only — no third-party packages. Captured output from
the run described above is committed as `results_screen.txt` and
`results_calibration.txt`, so the numbers in this document can be checked
without re-downloading anything.

**Data provenance caveat.** Layer 3 history comes from a public source (the
Yahoo Finance chart API) and consists of cash indices and continuous
front-month futures. These are **proxies** for the broker's CFDs, not the
instruments themselves. That is adequate for the question asked — *does trend
persistence exist in this asset class at all* — and **not** adequate to backtest
a strategy against. The raw JSON (14 MB) is deliberately not committed; the
fetch script reproduces it.

---

## 9. Status

The research programme is closed. No sixth hypothesis is queued, because a sixth
variation of a mechanism family already measured at zero five times is
arithmetic, not discovery.

**No challenge has been purchased, and no expert advisor in this repository has
ever been attached to a chart.** Attaching one is a deliberate manual step in
the MetaTrader GUI. Nothing in this document or this repository authorises it.

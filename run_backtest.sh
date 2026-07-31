#!/bin/bash
#===============================================================================
# run_backtest.sh — headless MT5 Strategy Tester run for FP50K-EA
#
# Purpose : Runs the Strategy Tester without the GUI, so a backtest can be
#           launched, waited on, and its results collected automatically.
#           The tester is a SIMULATION — it places no orders on the live
#           account. Attaching the EA to a chart is a separate manual step and
#           is never performed by this script.
#
# Author  : Tee (aigentforce.io)
# Project : FP50K-EA — FundingPips $50,000 2-Step Flex
#
# Usage   : ./run_backtest.sh [smoke|full]
#             smoke  1-minute OHLC, 12 months  — fast wiring check (~minutes)
#             full   real ticks, 2022-2025     — the acceptance run (~hours)
#
#           Overridable by environment variable:
#             BT_SYMBOL BT_PERIOD BT_FROM BT_TO BT_MODEL BT_DEPOSIT
#             BT_LEVERAGE BT_WAIT_SECS BT_SPREAD BT_EXEC_DELAY
#
# Realism  : The Strategy Tester will happily hand back results no live account
#           could reproduce. Three costs are forced on every run here rather
#           than left to the tester's defaults:
#             1. Spread  - fixed at BT_SPREAD points (default 15 = 1.5 pips),
#                          not the broker's optimistic current spread.
#             2. Latency - BT_EXEC_DELAY ms between decision and fill.
#             3. Slippage- charged inside the EA itself (InpSlippagePips), so
#                          the stop lands nearer and the target further than
#                          the quote implies. The tester has no slippage
#                          setting, so this is the only place it can live.
#           A run that only passes with these switched off has not passed.
#
# Notes   : MetaTrader is single-instance. A running terminal64.exe silently
#           absorbs the /config: launch below, so the script refuses to start
#           while one is open rather than hanging with no explanation.
#===============================================================================
set -uo pipefail

WINE_PREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
WINE_BIN="/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64"
[ -x "$WINE_BIN" ] || WINE_BIN="/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine"
MT5_DIR="$WINE_PREFIX/drive_c/Program Files/MetaTrader 5"

PROFILE="${1:-smoke}"

#--- Profiles -----------------------------------------------------------------
# Model: 1 = 1 minute OHLC, 4 = every tick based on real ticks
if [ "$PROFILE" = "full" ]; then
    DEF_MODEL=4;  DEF_FROM="2022.01.01"; DEF_TO="2025.12.31"; DEF_WAIT=21600
else
    DEF_MODEL=1;  DEF_FROM="2025.01.01"; DEF_TO="2025.12.31"; DEF_WAIT=1800
fi

SYMBOL="${BT_SYMBOL:-EURUSD}"
PERIOD="${BT_PERIOD:-H1}"
FROM="${BT_FROM:-$DEF_FROM}"
TO="${BT_TO:-$DEF_TO}"
MODEL="${BT_MODEL:-$DEF_MODEL}"
DEPOSIT="${BT_DEPOSIT:-50000}"
LEVERAGE="${BT_LEVERAGE:-100}"
WAIT_SECS="${BT_WAIT_SECS:-$DEF_WAIT}"

# Spread in POINTS, not pips: 15 points = 1.5 pips on a 5-digit pair. This is
# the top of the 1.2-1.5 pip band the London open actually costs, applied to the
# whole run. The tester cannot vary spread by hour, so the choice is between a
# penalty that is always on and one that is never on - and only one of those two
# errs in the safe direction.
SPREAD="${BT_SPREAD:-15}"

# Milliseconds between the EA deciding and the order filling. 0 is the tester's
# default and is a fiction - nothing fills instantly.
EXEC_DELAY="${BT_EXEC_DELAY:-0}"

STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_NAME="fp50k_report_${PROFILE}_${STAMP}"
SUMMARY_FILE="$WINE_PREFIX/drive_c/users/$(whoami)/AppData/Roaming/MetaQuotes/Terminal/Common/Files/fp50k_backtest_summary.txt"
[ -d "$(dirname "$SUMMARY_FILE")" ] || \
    SUMMARY_FILE="$WINE_PREFIX/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files/fp50k_backtest_summary.txt"

#--- Preconditions ------------------------------------------------------------
if [ ! -d "$MT5_DIR" ]; then
    echo "ERROR: MetaTrader 5 not found at: $MT5_DIR" >&2
    exit 1
fi

# A live GUI session must not be killed. Refuse rather than interfere.
if pgrep -f "terminal64.exe" >/dev/null 2>&1; then
    echo "ERROR: MetaTrader 5 is running. It is single-instance, so it would" >&2
    echo "       swallow this headless launch and the run would never start." >&2
    echo "       Quit MetaTrader 5 (and MetaEditor) and try again." >&2
    exit 2
fi

if [ ! -f "$MT5_DIR/MQL5/Experts/fp50k/FP50K_EA.ex5" ]; then
    echo "ERROR: FP50K_EA.ex5 not found. Run ./sync_to_mt5.sh && ./run_tests.sh first." >&2
    exit 1
fi

# Wine mishandles spaces in argv; C:\mt5 is a space-free route to the same place.
ln -sfn "$MT5_DIR" "$WINE_PREFIX/drive_c/mt5" 2>/dev/null

# Without this, wine uses its own default prefix, finds no terminal64.exe, and
# exits silently with status 0 — a no-op that reads exactly like a finished run.
export WINEPREFIX="$WINE_PREFIX"

#--- Tester config ------------------------------------------------------------
# Kept at the drive root, not in config/, for the same space-free-path reason.
INI_PATH="$MT5_DIR/fp50k_tester.ini"
INI_WIN="C:\\mt5\\fp50k_tester.ini"

cat > "$INI_PATH" <<EOF
[Common]
Login=
Password=
Enabled=1

[Tester]
Expert=fp50k\\FP50K_EA
Symbol=$SYMBOL
Period=$PERIOD
Model=$MODEL
FromDate=$FROM
ToDate=$TO
ForwardMode=0
Deposit=$DEPOSIT
Currency=USD
Leverage=1:$LEVERAGE
Spread=$SPREAD
ExecutionMode=$EXEC_DELAY
Optimization=0
Visual=0
Report=$REPORT_NAME
ReplaceReport=1
ShutdownTerminal=1
EOF

#--- EA inputs ----------------------------------------------------------------
# EVERY input is written out explicitly, every run. This is not tidiness.
#
# An input left out of [TesterInputs] does NOT fall back to the value compiled
# into the EA - MT5 reuses whatever that input was set to the last time the
# Strategy Tester ran. That cost real time on 2026-07-31: InpRRRatio was changed
# from 2.0 to 2.5 in the source, a run that omitted it silently executed at 2.0,
# and the result was written up as a 2.5:1 measurement. Two runs that differ
# only in a value you did not set will agree with each other and disagree with
# the code, which is the worst possible failure mode for a backtest - it looks
# like evidence.
#
# So: this list is the single source of truth for a run's settings. Keep it in
# step with the EA's input block. BT_INPUTS overrides any line here.
#
# InpUtcOffsetH is pinned because the tester CANNOT work it out: TimeGMT()
# mirrors the server clock there, auto-detection returns 0, and every UTC
# session window silently becomes a server-time one. Measured live against
# FundingPips-SIM1 on 2026-07-31 as +3h in July, i.e. a winter baseline of 2
# with European summer time on top.
BASE_INPUTS="\
InpUtcOffsetH=2;\
InpBrokerEuDst=true;\
InpRiskUSD=375.0;\
InpRRRatio=2.5;\
InpMaxSpreadEUR=20;\
InpMaxSpreadGBP=25;\
InpTradeEURUSD=true;\
InpTradeGBPUSD=true;\
InpEntryMode=0;\
InpSweepMinPips=3.0;\
InpSweepSLBuffer=2.0;\
InpRangeMinPips=8.0;\
InpRangeMaxPips=40.0;\
InpRangeAtrFrac=0.60;\
InpMaxTradesDay=2;\
InpSlippagePips=0.5;\
InpUseLimitEntry=false;\
InpLimitExpiryMin=60;\
InpStopRangeFrac=0.0;\
InpConsistentTP=false;\
InpUsePartial=true;\
InpUseBreakeven=true;\
InpUseTrail=true;\
InpPartialPct=50.0;\
InpAtrTrailMult=0.5;\
InpNewsBlockMin=15;\
InpNewsCloseMin=15;\
InpEntryOffsetMs=100;\
InpMagicNumber=50001"

# Merge: BASE_INPUTS first, then BT_INPUTS overriding by key. Last value for a
# key wins, and each key is emitted exactly once.
{
    echo ""
    echo "[TesterInputs]"
    printf '%s\n%s\n' "$BASE_INPUTS" "${BT_INPUTS:-}" \
        | tr ';' '\n' \
        | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' \
        | awk -F= '{ order[$1] = (order[$1] ? order[$1] : ++n); val[$1] = substr($0, index($0, "=") + 1) }
                   END { for (k in val) printf "%d\t%s=%s\n", order[k], k, val[k] }' \
        | sort -n | cut -f2-
} >> "$INI_PATH"

MODEL_NAME="1 minute OHLC"
[ "$MODEL" = "4" ] && MODEL_NAME="every tick based on real ticks"
[ "$MODEL" = "0" ] && MODEL_NAME="every tick (generated)"

echo "=============================================================="
echo "  FP50K-EA Strategy Tester — $PROFILE run"
echo "=============================================================="
echo "  Symbol   : $SYMBOL $PERIOD"
echo "  Period   : $FROM -> $TO"
echo "  Modelling: $MODEL_NAME"
echo "  Deposit  : \$$DEPOSIT   Leverage 1:$LEVERAGE"
echo "  Spread   : $SPREAD points forced (broker's own spread ignored)"
echo "  Exec lag : ${EXEC_DELAY}ms"
echo "  Timeout  : ${WAIT_SECS}s"
[ -n "${BT_INPUTS:-}" ] && echo "  Inputs   : $BT_INPUTS"
echo "--------------------------------------------------------------"
echo "  Simulation only. No orders are placed on the live account."
echo "=============================================================="

rm -f "$SUMMARY_FILE" 2>/dev/null

# Byte offset of today's log before launch, so the collection step can show
# only what this run appended. The offset lands on an even byte because the
# file is complete, so the UTF-16LE decode stays aligned.
TODAY_LOG="$MT5_DIR/logs/$(date +%Y%m%d).log"
LOG_OFFSET=0
[ -f "$TODAY_LOG" ] && LOG_OFFSET=$(wc -c < "$TODAY_LOG" | tr -d ' ')

START_EPOCH=$(date +%s)
"$WINE_BIN" "C:\\mt5\\terminal64.exe" "/config:$INI_WIN" >/dev/null 2>&1 &
disown 2>/dev/null || true

#--- Confirm it actually started ----------------------------------------------
# "Process is gone" is the completion signal below, but a launch that no-ops
# also leaves no process — indistinguishable, and it reads as a finished run
# that produced nothing. So require the process to appear first.
STARTED=0
for _ in $(seq 1 120); do
    if pgrep -f "terminal64.exe" >/dev/null 2>&1; then STARTED=1; break; fi
    sleep 1
done
if [ "$STARTED" -ne 1 ]; then
    echo "ERROR: terminal64.exe never started — the launch silently no-opped." >&2
    echo "       Check WINEPREFIX, the C:\\mt5 symlink, and $INI_PATH." >&2
    exit 4
fi
echo "Terminal up. Tester running."

#--- Wait ---------------------------------------------------------------------
# ShutdownTerminal=1 means the terminal exits by itself when the run finishes,
# so the process disappearing is the completion signal.
echo "Polling every 30s..."
ELAPSED=0
while [ "$ELAPSED" -lt "$WAIT_SECS" ]; do
    sleep 30
    ELAPSED=$(( $(date +%s) - START_EPOCH ))
    if ! pgrep -f "terminal64.exe" >/dev/null 2>&1; then
        echo "Terminal exited after ${ELAPSED}s."
        break
    fi
    if [ $(( ELAPSED % 300 )) -lt 30 ]; then
        echo "  ...still running (${ELAPSED}s)"
    fi
done

if pgrep -f "terminal64.exe" >/dev/null 2>&1; then
    echo "TIMEOUT: still running after ${WAIT_SECS}s. Leaving it alone — re-check later," >&2
    echo "         or raise the ceiling with BT_WAIT_SECS." >&2
    exit 3
fi

#--- Collect ------------------------------------------------------------------
echo "=============================================================="
echo "  VALIDATOR SUMMARY"
echo "=============================================================="
NEWS_OK=0
if [ -f "$SUMMARY_FILE" ]; then
    cat "$SUMMARY_FILE"
    NEWS_COUNT=$(grep -E "News blackouts observed" "$SUMMARY_FILE" \
                 | grep -oE '[0-9]+$' | head -1)
    [ -n "${NEWS_COUNT:-}" ] && [ "$NEWS_COUNT" -gt 0 ] && NEWS_OK=1
else
    echo "(no summary file written — see the tester log below)"
fi

#--- News filter verification -------------------------------------------------
# The news filter is the one safety control a backtest can silently fail to
# exercise. If the tester has no calendar database, IsBlackedOut() returns false
# every time, the EA trades straight through every release, and the run comes
# back looking BETTER than reality rather than worse. That failure mode is
# invisible unless something explicitly looks for it — so this does.
echo "=============================================================="
echo "  NEWS FILTER VERIFICATION"
echo "=============================================================="
if [ "$NEWS_OK" -eq 1 ]; then
    echo "PASS: the news filter fired ${NEWS_COUNT} time(s) during this run."
    echo "      Entries were blocked around high-impact releases as designed."
else
    echo "NOT VERIFIED: zero news blackouts were observed."
    echo ""
    echo "  Over a year of data there are hundreds of high-impact releases, so"
    echo "  zero almost certainly means the Strategy Tester had no economic"
    echo "  calendar data — not that no event ever landed in a trading window."
    echo ""
    echo "  This makes the run OPTIMISTIC: it never paid the cost of trading"
    echo "  into a release. Treat the numbers as a ceiling, not a result."
    echo ""
    echo "  Fix: open MetaTrader 5, show the Calendar tab and let it populate,"
    echo "       quit the terminal, then re-run."
fi

echo "=============================================================="
echo "  TESTER LOG (last lines)"
echo "=============================================================="
# Only this run's lines. The day log is never cleared, so tailing it whole
# shows yesterday's chatter and passes it off as today's result.
TESTER_LOG=$(find "$MT5_DIR/Tester" -name '*.log' -newermt "@$START_EPOCH" 2>/dev/null | head -1)
if [ -n "$TESTER_LOG" ]; then
    iconv -f UTF-16LE -t UTF-8 "$TESTER_LOG" 2>/dev/null | tail -n 60
else
    echo "(no tester log written this run — showing terminal log since launch)"
    LOG="$MT5_DIR/logs/$(date +%Y%m%d).log"
    [ -f "$LOG" ] && tail -c "+$((LOG_OFFSET + 1))" "$LOG" 2>/dev/null \
        | iconv -f UTF-16LE -t UTF-8 2>/dev/null | tail -n 60
fi

REPORT_HTML=$(ls -t "$MT5_DIR/${REPORT_NAME}".htm* 2>/dev/null | head -1)
echo "=============================================================="
[ -n "$REPORT_HTML" ] && echo "Report: $REPORT_HTML" || echo "No HTML report produced."
echo "Config: $INI_PATH"

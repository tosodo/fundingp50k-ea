#!/bin/bash
#===============================================================================
# run_lab.sh — headless Strategy Tester bench for hypothesis testing
#
# Purpose : Run one lab EA over one symbol and one period, then compute the
#           statistical significance of the resulting trade series. This is the
#           edge-discovery bench: it answers "does the entry predict direction"
#           and nothing else. Prop-firm compliance is a separate, later gate.
#
#           The tester is a SIMULATION — it places no orders on the live
#           account. Attaching an EA to a chart is a separate manual step and
#           is never performed by this script.
#
# Author  : Tee (aigentforce.io)
# Project : Strategy Lab (built on the FP50K-EA framework)
#
# Usage   : ./run_lab.sh <ExpertPath> <RunTag> [inputs]
#             ExpertPath  e.g. lab\\LAB_TrendPullback   (no .ex5)
#             RunTag      short label; must match InpRunTag so the exported
#                         trade file can be found afterwards
#             inputs      optional semicolon-separated Key=Value overrides
#
#           Example:
#             ./run_lab.sh 'lab\LAB_TrendPullback' base
#             LAB_SYMBOL=GBPUSD ./run_lab.sh 'lab\LAB_TrendPullback' gbp
#
#           Overridable by environment variable:
#             LAB_SYMBOL LAB_PERIOD LAB_FROM LAB_TO LAB_MODEL LAB_DEPOSIT
#             LAB_LEVERAGE LAB_WAIT_SECS LAB_SPREAD LAB_EXEC_DELAY
#
# Realism  : Same three costs as the main harness. A run that only passes with
#            these switched off has not passed.
#              1. Spread  - fixed at LAB_SPREAD points (default 15 = 1.5 pips)
#              2. Latency - LAB_EXEC_DELAY ms between decision and fill
#              3. Slippage- charged inside the EA (InpSlippagePips); the tester
#                           has no slippage setting, so this is its only home
#
# Honest limitation: the lab EA carries NO news filter. Entries around
#            high-impact releases are taken at simulated cost, so results are
#            optimistic on exactly those bars. That is deliberate — a filter is
#            trade management, and this bench measures the raw signal — but it
#            means a marginal pass here is not a pass.
#===============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_PREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
WINE_BIN="/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64"
[ -x "$WINE_BIN" ] || WINE_BIN="/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine"
MT5_DIR="$WINE_PREFIX/drive_c/Program Files/MetaTrader 5"

EXPERT="${1:-}"
RUN_TAG="${2:-run}"
EXTRA_INPUTS="${3:-}"

if [ -z "$EXPERT" ]; then
    echo "Usage: ./run_lab.sh <ExpertPath> <RunTag> [Key=Value;Key=Value]" >&2
    echo "   eg: ./run_lab.sh 'lab\\LAB_TrendPullback' base" >&2
    exit 1
fi

SYMBOL="${LAB_SYMBOL:-EURUSD}"
PERIOD="${LAB_PERIOD:-H1}"
FROM="${LAB_FROM:-2024.01.01}"
TO="${LAB_TO:-2025.12.31}"
MODEL="${LAB_MODEL:-1}"          # 1 = 1-minute OHLC, 4 = real ticks
DEPOSIT="${LAB_DEPOSIT:-50000}"
LEVERAGE="${LAB_LEVERAGE:-100}"
WAIT_SECS="${LAB_WAIT_SECS:-3600}"
SPREAD="${LAB_SPREAD:-15}"
EXEC_DELAY="${LAB_EXEC_DELAY:-0}"

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

EXPERT_EX5="$MT5_DIR/MQL5/Experts/$(echo "$EXPERT" | tr '\\' '/').ex5"
EXPERT_SRC="$MT5_DIR/MQL5/Experts/$(echo "$EXPERT" | tr '\\' '/').mq5"
if [ ! -f "$EXPERT_EX5" ]; then
    echo "ERROR: compiled EA not found: $EXPERT_EX5" >&2
    echo "       Run ./sync_to_mt5.sh and compile it first." >&2
    exit 1
fi
# A binary older than its source measures code that no longer exists. That is a
# wrong answer that looks exactly like a right one, so it is a hard stop rather
# than a warning. Includes are not checked - the compile is cheap, just rerun it.
if [ -f "$EXPERT_SRC" ] && [ "$EXPERT_SRC" -nt "$EXPERT_EX5" ]; then
    echo "ERROR: $EXPERT.ex5 is OLDER than its source. This run would measure" >&2
    echo "       stale code and report it as a result. Recompile first." >&2
    exit 1
fi

# Wine mishandles spaces in argv; C:\mt5 is a space-free route to the same place.
ln -sfn "$MT5_DIR" "$WINE_PREFIX/drive_c/mt5" 2>/dev/null

# Without this, wine uses its own default prefix, finds no terminal64.exe, and
# exits silently with status 0 — a no-op that reads exactly like a finished run.
export WINEPREFIX="$WINE_PREFIX"

STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_NAME="lab_${RUN_TAG}_${STAMP}"
INI_PATH="$MT5_DIR/lab_tester.ini"
INI_WIN="C:\\mt5\\lab_tester.ini"

COMMON_FILES="$WINE_PREFIX/drive_c/users/$(whoami)/AppData/Roaming/MetaQuotes/Terminal/Common/Files"
[ -d "$COMMON_FILES" ] || COMMON_FILES="$WINE_PREFIX/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files"
TRADE_CSV="$COMMON_FILES/lab_trades_${RUN_TAG}.csv"

cat > "$INI_PATH" <<EOF
[Common]
Login=
Password=
Enabled=1

[Tester]
Expert=$EXPERT
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
# EVERY input is written out explicitly, every run.
#
# An input left out of [TesterInputs] does NOT fall back to the value compiled
# into the EA — MT5 reuses whatever that input was set to the last time the
# Strategy Tester ran. That cost real time on 2026-07-31, when a run that
# omitted InpRRRatio silently executed at the previous run's value and the
# result was written up as a measurement of the new one. Two runs differing
# only in a value you did not set will agree with each other and disagree with
# the code — the worst possible failure mode, because it looks like evidence.
#
# Each strategy declares its own complete input set here. Deliberately not
# merged into one shared list: an input belonging to a different EA is not
# ignored by the tester, it is written into [TesterInputs] and applied to
# whatever input of that name exists. One list per EA keeps that impossible.
case "$EXPERT" in
  *TrendPullback*)
    BASE_INPUTS="\
InpEntryTF=16385;\
InpTrendTF=16388;\
InpEmaTrend=200;\
InpEmaPullback=50;\
InpAtrPeriod=20;\
InpAtrStopMult=2.0;\
InpRRRatio=2.0;\
InpRiskPct=1.0;\
InpSlippagePips=0.5;\
InpMaxSpreadPips=3.0;\
InpMagic=60001;\
InpRunTag=$RUN_TAG"
    ;;
  *SessionBreakout*)
    BASE_INPUTS="\
InpEntryTF=15;\
InpAsiaStart=0;\
InpAsiaEnd=7;\
InpBreakStart=7;\
InpBreakEnd=12;\
InpFlatHour=20;\
InpAvgDays=20;\
InpStopMode=1;\
InpAtrPeriod=20;\
InpAtrStopMult=1.5;\
InpRRRatio=2.0;\
InpRiskPct=1.0;\
InpSlippagePips=0.5;\
InpMaxSpreadPips=3.0;\
InpMagic=60002;\
InpRunTag=$RUN_TAG"
    ;;
  *MeanReversion*)
    BASE_INPUTS="\
InpEntryTF=16385;\
InpMaPeriod=20;\
InpAtrPeriod=20;\
InpEntryAtr=2.0;\
InpStopAtr=2.0;\
InpHoldBars=24;\
InpHourStart=7;\
InpHourEnd=20;\
InpRiskPct=1.0;\
InpSlippagePips=0.5;\
InpMaxSpreadPips=3.0;\
InpMagic=60003;\
InpRunTag=$RUN_TAG"
    ;;
  *)
    echo "ERROR: no input set defined for '$EXPERT'." >&2
    echo "       Add one to the case block in run_lab.sh. Running without a" >&2
    echo "       complete [TesterInputs] would silently reuse the previous" >&2
    echo "       run's values - see the note above." >&2
    exit 5
    ;;
esac

# Merge: BASE_INPUTS first, then the caller's overrides. Last value for a key
# wins, and each key is emitted exactly once.
{
    echo ""
    echo "[TesterInputs]"
    printf '%s\n%s\n' "$BASE_INPUTS" "$EXTRA_INPUTS" \
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
echo "  STRATEGY LAB — $EXPERT"
echo "=============================================================="
echo "  Run tag  : $RUN_TAG"
echo "  Symbol   : $SYMBOL $PERIOD"
echo "  Period   : $FROM -> $TO"
echo "  Modelling: $MODEL_NAME"
echo "  Deposit  : \$$DEPOSIT   Leverage 1:$LEVERAGE"
echo "  Spread   : $SPREAD points forced (broker's own spread ignored)"
echo "  Exec lag : ${EXEC_DELAY}ms"
[ -n "$EXTRA_INPUTS" ] && echo "  Overrides: $EXTRA_INPUTS"
echo "--------------------------------------------------------------"
echo "  Simulation only. No orders are placed on the live account."
echo "=============================================================="

rm -f "$TRADE_CSV" 2>/dev/null

TODAY_LOG="$MT5_DIR/logs/$(date +%Y%m%d).log"
LOG_OFFSET=0
[ -f "$TODAY_LOG" ] && LOG_OFFSET=$(wc -c < "$TODAY_LOG" | tr -d ' ')

# A reference file to compare log timestamps against later. macOS ships BSD
# find, whose -newermt does NOT understand GNU's "@<epoch>" form — it silently
# matches nothing, which reads exactly like "the run produced no log". That is
# what swallowed the H1 diagnostics. -newer <file> is portable.
TIME_REF="$MT5_DIR/.lab_run_start"
: > "$TIME_REF"

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
    exit 4
fi
echo "Terminal up. Tester running."

ELAPSED=0
while [ "$ELAPSED" -lt "$WAIT_SECS" ]; do
    sleep 15
    ELAPSED=$(( $(date +%s) - START_EPOCH ))
    if ! pgrep -f "terminal64.exe" >/dev/null 2>&1; then
        echo "Terminal exited after ${ELAPSED}s."
        break
    fi
done

if pgrep -f "terminal64.exe" >/dev/null 2>&1; then
    echo "TIMEOUT: still running after ${WAIT_SECS}s. Raise LAB_WAIT_SECS." >&2
    exit 3
fi

#--- Collect ------------------------------------------------------------------
echo "=============================================================="
echo "  TESTER LOG (lab lines)"
echo "=============================================================="
# The EA's own Print() output lands in the AGENT log, not the coordinator log
# under Tester/logs. Search the agent folders first, and fall back to any
# tester log so a layout change degrades rather than goes silent.
TESTER_LOG=$(find "$MT5_DIR/Tester" -path '*Agent*' -name '*.log' -newer "$TIME_REF" 2>/dev/null | head -1)
[ -n "$TESTER_LOG" ] || TESTER_LOG=$(find "$MT5_DIR/Tester" -name '*.log' -newer "$TIME_REF" 2>/dev/null | head -1)
if [ -n "$TESTER_LOG" ]; then
    iconv -f UTF-16LE -t UTF-8 "$TESTER_LOG" 2>/dev/null \
        | grep -E "\[LAB\]|final balance|OnTester|no trading|not enough" | tail -n 25
else
    echo "(no tester log written this run)"
    [ -f "$TODAY_LOG" ] && tail -c "+$((LOG_OFFSET + 1))" "$TODAY_LOG" 2>/dev/null \
        | iconv -f UTF-16LE -t UTF-8 2>/dev/null | tail -n 30
fi

echo "=============================================================="
echo "  EDGE STATISTICS"
echo "=============================================================="
if [ -f "$TRADE_CSV" ]; then
    python3 "$REPO_DIR/tools/edge_stats.py" "$TRADE_CSV" "$RUN_TAG"
else
    echo "NO TRADE FILE at $TRADE_CSV"
    echo "Either the EA took no trades, or the export failed. Check the log above."
fi

REPORT_HTML=$(ls -t "$MT5_DIR/${REPORT_NAME}".htm* 2>/dev/null | head -1)
echo "=============================================================="
[ -n "$REPORT_HTML" ] && echo "Report: $REPORT_HTML" || echo "No HTML report produced."
echo "Trades: $TRADE_CSV"
echo "Config: $INI_PATH"

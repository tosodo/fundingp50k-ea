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
#             BT_LEVERAGE BT_WAIT_SECS
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
ExecutionMode=0
Optimization=0
Visual=0
Report=$REPORT_NAME
ReplaceReport=1
ShutdownTerminal=1
EOF

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
echo "  Timeout  : ${WAIT_SECS}s"
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
if [ -f "$SUMMARY_FILE" ]; then
    cat "$SUMMARY_FILE"
else
    echo "(no summary file written — see the tester log below)"
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

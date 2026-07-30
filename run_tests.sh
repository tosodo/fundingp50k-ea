#!/bin/bash
# run_tests.sh — compile and run an fp50k test script headlessly.
#
#   ./run_tests.sh RiskManager_tests
#   ./run_tests.sh SignalEngine_tests
#   ./run_tests.sh                     # runs every *_tests.mq5 in order
#
# Two things this handles that a plain wine invocation does not:
#
#  1. A previous run's terminal64.exe often survives — killing the wine
#     launcher does not kill the terminal underneath. MetaTrader is
#     single-instance, so a survivor silently swallows the next /config:
#     launch and the script never attaches. Every run starts by clearing it.
#
#  2. RiskManager.Init() warms the economic-calendar cache, and MT5's first
#     calendar download can take ~90s on a cold terminal. The wait here is
#     generous enough to cover that.

set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
WINEPREFIX_PATH="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
MT5_REAL="$WINEPREFIX_PATH/drive_c/Program Files/MetaTrader 5"
MT5_LINK="$WINEPREFIX_PATH/drive_c/mt5"
WINE_BIN="/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine"
COMPILE="$HOME/.claude/skills/mql5-wine-qa/scripts/compile_mql5.sh"

SYMBOL="${SYMBOL:-EURUSD}"
PERIOD="${PERIOD:-H1}"
WAIT_SECS="${WAIT_SECS:-240}"

if [ ! -d "$MT5_REAL" ]; then
  echo "ERROR: MT5 not found at: $MT5_REAL" >&2
  exit 2
fi

ln -sfn "$MT5_REAL" "$MT5_LINK"
export WINEPREFIX="$WINEPREFIX_PATH"

# Which tests to run
if [ $# -gt 0 ]; then
  TESTS=("$@")
else
  TESTS=()
  for f in "$REPO"/MQL5/Scripts/fp50k/*_tests.mq5; do
    [ -e "$f" ] || continue
    TESTS+=("$(basename "$f" .mq5)")
  done
fi

"$REPO/sync_to_mt5.sh" >/dev/null || exit 1

OVERALL=0

for TEST in "${TESTS[@]}"; do
  echo "=============================================================="
  echo "  $TEST"
  echo "=============================================================="

  # A survivor from an earlier run would absorb the launch below. Do this
  # before compiling too: MetaEditor is subject to the same single-instance
  # handoff, and wineserver needs a moment to settle after a kill or the
  # compile silently no-ops and reports no log at all.
  pkill -9 -f "terminal64.exe" 2>/dev/null
  sleep 3

  OUT=$("$COMPILE" "$WINEPREFIX_PATH" "MQL5/Scripts/fp50k/$TEST.mq5" 2>&1)
  if ! echo "$OUT" | grep -q "0 errors, 0 warnings"; then
    # Retry once — an empty log here is a Wine timing artefact, not a
    # real compile error, and is indistinguishable from one at this point.
    sleep 5
    OUT=$("$COMPILE" "$WINEPREFIX_PATH" "MQL5/Scripts/fp50k/$TEST.mq5" 2>&1)
  fi

  if ! echo "$OUT" | grep -q "0 errors, 0 warnings"; then
    echo "COMPILE FAILED:"
    echo "$OUT" | grep -E "error|warning" || echo "$OUT" | tail -3
    OVERALL=1
    continue
  fi
  echo "COMPILE: 0 errors, 0 warnings"

  INI="$MT5_LINK/_qa_$$.ini"
  printf '[StartUp]\nScript=fp50k\\%s\nSymbol=%s\nPeriod=%s\nShutdownTerminal=0\n' \
    "$TEST" "$SYMBOL" "$PERIOD" > "$INI"

  LOG="$MT5_REAL/MQL5/Logs/$(date +%Y%m%d).log"
  rm -f "$LOG"

  "$WINE_BIN" "C:\\mt5\\terminal64.exe" "/config:C:\\mt5\\$(basename "$INI")" >/dev/null 2>&1 &

  FOUND=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    if [ -s "$LOG" ] && iconv -f UTF-16LE -t UTF-8 "$LOG" 2>/dev/null | grep -q "RESULT:"; then
      FOUND=1
      break
    fi
    sleep 1
  done

  pkill -9 -f "terminal64.exe" 2>/dev/null
  rm -f "$INI"

  if [ "$FOUND" -ne 1 ]; then
    echo "NO RESULT after ${WAIT_SECS}s — script did not finish. Last output:"
    [ -s "$LOG" ] && iconv -f UTF-16LE -t UTF-8 "$LOG" 2>/dev/null | tail -5
    OVERALL=1
    continue
  fi

  DECODED=$(iconv -f UTF-16LE -t UTF-8 "$LOG" 2>/dev/null | sed 's/.*(.*)\t//')
  echo "$DECODED" | grep -E "^\[QA\] (INFO|FAIL)" || true
  RESULT=$(echo "$DECODED" | grep "RESULT:" | tail -1)
  echo "$RESULT"

  if ! echo "$RESULT" | grep -q "0 failed"; then
    OVERALL=1
  fi
done

echo "=============================================================="
[ "$OVERALL" -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit "$OVERALL"

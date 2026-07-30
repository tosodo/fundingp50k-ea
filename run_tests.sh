#!/bin/bash
# run_tests.sh — compile and run the fp50k test suites headlessly.
#
#   ./run_tests.sh RiskManager_tests
#   ./run_tests.sh SignalEngine_tests
#   ./run_tests.sh                     # runs every *_tests.mq5 in order
#
# The Wine/MetaTrader quirks this has to survive (single-instance launch
# absorption, the ~90s first calendar download, killing the launcher wrapper
# instead of terminal64.exe itself) are all handled in the mql5-wine-qa skill
# scripts. This file deliberately does not reimplement any of that — it syncs
# the source, compiles, and hands each suite to the skill's runner.

set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
WINEPREFIX_PATH="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
MT5_REAL="$WINEPREFIX_PATH/drive_c/Program Files/MetaTrader 5"
SKILL="$HOME/.claude/skills/mql5-wine-qa/scripts"
COMPILE="$SKILL/compile_mql5.sh"
RUNNER="$SKILL/run_headless_script.sh"

SYMBOL="${SYMBOL:-EURUSD}"
PERIOD="${PERIOD:-H1}"

# Both suites call RiskManager.Init(), which warms the economic-calendar cache.
export QA_WAIT_SECS="${QA_WAIT_SECS:-240}"
# Surface the [QA] INFO lines - measured lot sizes and the real Asian range are
# worth seeing on every run even though nothing asserts on them.
export QA_VERBOSE=1

for f in "$MT5_REAL" "$COMPILE" "$RUNNER"; do
  if [ ! -e "$f" ]; then
    echo "ERROR: not found: $f" >&2
    exit 2
  fi
done

# Fail fast and clearly rather than letting the first suite time out. The
# runner refuses to launch against a live terminal on purpose - closing the
# user's MetaTrader is their decision, not this script's.
if pgrep -f "terminal64.exe" >/dev/null 2>&1 || pgrep -f "MetaEditor64.exe" >/dev/null 2>&1; then
  echo "ERROR: MetaTrader 5 or MetaEditor is open. Both are single-instance, so"
  echo "       a running copy silently swallows the headless compile and launch."
  echo "       Quit MetaTrader 5 and MetaEditor, then re-run."
  exit 2
fi

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

  OUT=$("$COMPILE" "$WINEPREFIX_PATH" "MQL5/Scripts/fp50k/$TEST.mq5" 2>&1)
  if ! echo "$OUT" | grep -q "0 errors, 0 warnings"; then
    # Retry once. An empty log here is a Wine timing artefact rather than a
    # real compile error, and the two are indistinguishable at this point.
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

  "$RUNNER" "$WINEPREFIX_PATH" "fp50k\\$TEST" "$SYMBOL" "$PERIOD" || OVERALL=1
done

echo "=============================================================="
[ "$OVERALL" -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit "$OVERALL"

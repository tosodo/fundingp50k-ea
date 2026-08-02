#!/bin/bash
# Syncs MQL5 source from repo into Wine MT5 data folder
# Run after every edit: ./sync_to_mt5.sh

MT5_MQL5="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5"

if [ ! -d "$MT5_MQL5" ]; then
  echo "ERROR: MT5 data folder not found at: $MT5_MQL5"
  echo "If you moved or reinstalled MT5, update MT5_MQL5 at the top of this script."
  exit 1
fi

cd "$(dirname "$0")" || exit 1

for proj in fp50k lab; do
  for sub in Include Experts Scripts; do
    [ -d "MQL5/$sub/$proj" ] || continue
    echo "Syncing $sub/$proj..."
    mkdir -p "$MT5_MQL5/$sub/$proj"
    # --delete removes anything in the destination that is not in the repo.
    # Compiled binaries only ever exist in the destination, so without this
    # exclude a sync run AFTER a compile silently wipes the .ex5 and the next
    # backtest dies with "compiled EA not found". Keeping them is safe because
    # run_lab.sh refuses to run a .ex5 older than its own source.
    rsync -a --delete --exclude '*.ex5' "MQL5/$sub/$proj/" "$MT5_MQL5/$sub/$proj/"
  done
done

echo "Sync complete. In MetaEditor: close the project tabs, reopen them, then press F7."

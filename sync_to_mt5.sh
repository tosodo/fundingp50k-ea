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

for sub in Include Experts Scripts; do
  echo "Syncing $sub/fp50k..."
  mkdir -p "$MT5_MQL5/$sub/fp50k"
  rsync -a --delete "MQL5/$sub/fp50k/" "$MT5_MQL5/$sub/fp50k/"
done

echo "Sync complete. In MetaEditor: close the fp50k tabs, reopen them, then press F7."

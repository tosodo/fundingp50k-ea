#!/bin/bash
# Syncs MQL5 source from repo into Wine MT5 data folder
# Run after every edit: ./sync_to_mt5.sh
# Replace REPLACE_WITH_ACTUAL_PATH below with your actual MT5 MQL5 path

MT5_MQL5="REPLACE_WITH_ACTUAL_PATH/MQL5"

if [ ! -d "$MT5_MQL5" ]; then
  echo "ERROR: MT5_MQL5 path does not exist: $MT5_MQL5"
  echo "Edit this script and replace REPLACE_WITH_ACTUAL_PATH with your actual path"
  exit 1
fi

echo "→ Syncing Include/fp50k..."
rsync -av --delete MQL5/Include/fp50k/ "$MT5_MQL5/Include/fp50k/"

echo "→ Syncing Experts/fp50k..."
rsync -av --delete MQL5/Experts/fp50k/ "$MT5_MQL5/Experts/fp50k/"

echo "→ Syncing Scripts/fp50k..."
rsync -av --delete MQL5/Scripts/fp50k/ "$MT5_MQL5/Scripts/fp50k/"

echo "✓ Sync complete. Open MetaEditor and press F7 to compile."

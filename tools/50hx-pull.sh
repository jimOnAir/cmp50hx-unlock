#!/usr/bin/env bash
# 50hx-pull.sh — sync bench experiment data to the work machine (canonical
# private store next to the Obsidian note). Run from the work machine any
# time; idempotent rsync. Never committed to the git repo.
set -euo pipefail
BENCH="${BENCH:-dmitry@192.168.3.58}"
DEST="${DEST:-$HOME/Yandex.Disk/Obsidian/Default/attachments/50hx}"
mkdir -p "$DEST"
rsync -a --chmod=F644 "$BENCH:debug/50hx/ledger.csv" "$DEST/ledger.csv"
rsync -a "$BENCH:debug/50hx/bootlogs/" "$DEST/bootlogs/"
echo "pulled -> $DEST"

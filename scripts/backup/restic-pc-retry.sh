#!/bin/bash
# Morning retry: if last night 02:30 run missed the PC backup (PC off/asleep),
# re-run the full backup in the morning when the PC is on. Restic dedupes,
# so the VPS re-push is incremental and cheap.
LOG=/var/log/restic-backup.log
TODAY=$(date +%Y%m%d)
if grep -q "\[${TODAY}-.*\] PC backup OK" "$LOG"; then
  echo "[$(date +%Y%m%d-%H%M%S)] PC retry: already OK today, skipping" >> "$LOG"
  exit 0
fi
echo "[$(date +%Y%m%d-%H%M%S)] PC retry: no successful PC backup today - re-running full backup" >> "$LOG"
/root/backup-scripts/restic-backup.sh

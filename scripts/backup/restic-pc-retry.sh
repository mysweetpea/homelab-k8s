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
# If the retry ALSO failed to land a PC backup today, push an alert (this means
# the PC was unreachable both overnight and in the morning - IP drift, powered
# off, or asleep). Fires once per day thanks to the alert log marker.
if ! grep -q "\[${TODAY}-.*\] PC backup OK" "$LOG"; then
  if ! grep -q "\[${TODAY}-.*\] ALERT pushed: PC unreachable all day" "$LOG"; then
    TOKEN=$(cat /root/.gotify-backup-token 2>/dev/null)
    if [ -n "$TOKEN" ]; then
      curl -s --max-time 10 -X POST "http://10.43.11.212/message?token=$TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"BACKUP FAILED: PC unreachable\",\"message\":\"PC backup missed at both 02:30 and 08:00 retry - PC asleep, IP drift, or powered off. Backups to VPS continue; PC copy is stale.\",\"priority\":8}" >/dev/null
      echo "[$(date +%Y%m%d-%H%M%S)] ALERT pushed: PC unreachable all day" >> "$LOG"
    fi
  fi
fi

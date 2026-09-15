#!/bin/bash
# NOTE: repo copy is sanitized — real repo URLs (VPS/PC SFTP) live on k3s-master
# at /root/backup-scripts/. Apply template by setting VPS_REPO/PC_REPO env vars or
# re-editing on the master. See apps/infra/longhorn/BACKUP-TARGET.md for the design.
# Monthly integrity check of both restic repos (VPS + PC).
# Uses --read-data-subset=5% to keep runtime bounded while still
# verifying actual pack data, not just index/catalog.
# Exits non-zero if the passphrase is missing, a repo var is unset, or any
# check fails — a silent "everything is fine" here is worse than no check.
set -uo pipefail

LOG=/var/log/restic-check.log
PASSFILE=/root/.restic-passphrase

if [ ! -r "$PASSFILE" ]; then
  echo "[$(date +%Y%m%d-%H%M%S)] CHECK ABORTED: $PASSFILE missing or unreadable" >> "$LOG"
  exit 1
fi
RESTIC_PASSWORD="$(cat "$PASSFILE")"
if [ -z "$RESTIC_PASSWORD" ]; then
  echo "[$(date +%Y%m%d-%H%M%S)] CHECK ABORTED: $PASSFILE is empty" >> "$LOG"
  exit 1
fi
export RESTIC_PASSWORD

# Refuse to run against an unconfigured target (e.g. bare "sftp:" matching nothing)
if [ -z "${VPS_REPO:-}" ] || [ -z "${PC_REPO:-}" ]; then
  echo "[$(date +%Y%m%d-%H%M%S)] CHECK ABORTED: VPS_REPO/PC_REPO not set (VPS_REPO='${VPS_REPO:-}' PC_REPO='${PC_REPO:-}')" >> "$LOG"
  exit 1
fi

# The monthly job runs at 05:00; guard against overlapping with the nightly
# backup window so `restic check`'s exclusive lock does not collide.
exec 9>/var/lock/restic-check.lock
if ! flock -n 9; then
  echo "[$(date +%Y%m%d-%H%M%S)] CHECK SKIPPED: another restic-check holds the lock" >> "$LOG"
  exit 1
fi

echo "[$(date +%Y%m%d-%H%M%S)] === RESTIC CHECK START ===" >> "$LOG"

FAILED=0
for REPO in "sftp:${VPS_REPO}" "sftp:${PC_REPO}"; do
  export RESTIC_REPOSITORY="$REPO"
  if restic check --read-data-subset=5% >> "$LOG" 2>&1; then
    echo "[$(date +%Y%m%d-%H%M%S)] CHECK OK: $REPO" >> "$LOG"
  else
    echo "[$(date +%Y%m%d-%H%M%S)] CHECK FAILED: $REPO (rc=$?)" >> "$LOG"
    FAILED=$((FAILED + 1))
  fi
done
echo "[$(date +%Y%m%d-%H%M%S)] === RESTIC CHECK DONE ($FAILED failure(s)) ===" >> "$LOG"

# Non-zero exit so cron mail / the freshness watchdog can see real failures
exit $([ "$FAILED" -gt 0 ] && echo 1 || echo 0)

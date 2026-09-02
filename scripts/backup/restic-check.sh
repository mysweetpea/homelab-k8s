#!/bin/bash
# NOTE: repo copy is sanitized — real repo URLs (VPS/PC SFTP) live on k3s-master
# at /root/backup-scripts/. Apply template by setting VPS_REPO/PC_REPO env vars or
# re-editing on the master. See apps/infra/longhorn/BACKUP-TARGET.md for the design.
# Monthly integrity check of both restic repos (VPS + PC).
# Uses --read-data-subset=5% to keep runtime bounded while still
# verifying actual pack data, not just index/catalog.
LOG=/var/log/restic-check.log
export RESTIC_PASSWORD="$(cat /root/.restic-passphrase)"
echo "[$(date +%Y%m%d-%H%M%S)] === RESTIC CHECK START ===" >> "$LOG"

for REPO in "sftp:${VPS_REPO}" "sftp:${PC_REPO}"; do
  export RESTIC_REPOSITORY="$REPO"
  if restic check --read-data-subset=5% >> "$LOG" 2>&1; then
    echo "[$(date +%Y%m%d-%H%M%S)] CHECK OK: $REPO" >> "$LOG"
  else
    echo "[$(date +%Y%m%d-%H%M%S)] CHECK FAILED: $REPO" >> "$LOG"
  fi
done
echo "[$(date +%Y%m%d-%H%M%S)] === RESTIC CHECK DONE ===" >> "$LOG"

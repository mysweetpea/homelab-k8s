#!/bin/bash
# Backup freshness watchdog — pushes a Gotify alert if the nightly chain silently
# stops running (cron dead, master rebooted at wrong time, etc). Failure alerts in
# restic-backup.sh only fire when the script RUNS and FAILS; this covers "never ran".
# Runs daily at 06:30 (after 02:30 restic + retries at 08:00 handled by retry script).
# Alert dedupe: one push per failure-day via /root/.backup-watchdog-alerted marker.

LOG=/var/log/restic-backup.log
TOKEN_FILE=/root/.gotify-backup-token
GOTIFY="http://gotify.private.svc.cluster.local"
MARKER=/root/.backup-watchdog-alerted
TODAY=$(date +%Y%m%d)

fail() {
  # dedupe: only once per day
  [ -f "$MARKER" ] && grep -q "^$TODAY$" "$MARKER" && return 0
  curl -s -m 10 -X POST "$GOTIFY/message?token=$(cat "$TOKEN_FILE")" \
    -H "Title: BACKUP WATCHDOG: $1" \
    -H "Priority: 8" \
    --data-binary "$2" > /dev/null
  echo "[$(date +%Y%m%d-%H%M%S)] WATCHDOG ALERT pushed: $1" >> "$LOG"
  echo "$TODAY" > "$MARKER"
}

# 1. Today 02:30 restic run must show both legs OK
TODAYS_RUN=$(awk -v d="[$TODAY-02" "index(\$0,d)==1" "$LOG" 2>/dev/null | wc -l)
if [ "$TODAYS_RUN" -eq 0 ]; then
  fail "nightly restic missing" "No restic-backup.sh log entries found for today ($TODAY). Cron dead? Master was rebooted/suspended at 02:30? Check /var/log/restic-backup.log"
  exit 0
fi
VPS_OK=$(grep -c "^\[$TODAY-.*VPS backup OK" "$LOG")
PC_OK=$(grep -c "^\[$TODAY-.*PC backup OK" "$LOG")
# retry script marks its own OK as "PC backup OK" too (same format) - count is fine
[ "$VPS_OK" -eq 0 ] && fail "VPS leg failed" "No VPS backup OK for $TODAY. restic-backup.sh ran but VPS push failed (or alert dedupe swallowed it)."
[ "$PC_OK" -eq 0 ] && fail "PC leg failed" "No PC backup OK for $TODAY (02:30 + 08:00 retry both failed?)."

# 2. PG dump freshness (02:00 daily)
PG_DIR=/root/pg-dumps
NEWEST_PG=$(find "$PG_DIR" -name "*.sql.gz" -mmin -1560 2>/dev/null | wc -l)
[ "$NEWEST_PG" -eq 0 ] && fail "pg dumps stale" "No pg-backup dump updated in the last 26h (dir: $PG_DIR). pg-backup.sh (02:00 cron) stopped?"

# 3. Longhorn offsite backup freshness (04:00 daily, keep-7)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
LH_NEW=$(kubectl -n longhorn-system get backups.longhorn.io -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
import datetime
cutoff=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=26)
n=0
for b in d[\"items\"]:
    ts=b[\"status\"].get(\"lastCompletionTime\") or b.get(\"metadata\",{}).get(\"creationTimestamp\")
    if ts and datetime.datetime.fromisoformat(ts.replace(\"Z\",\"+00:00\"))>cutoff: n+=1
print(n)")
[ "${LH_NEW:-0}" -eq 0 ] && fail "longhorn offsite stale" "No Longhorn backup completed in last 26h. daily-backup recurring job (04:00) failing? Check longhorn-ui Backups."

echo "[$(date +%Y%m%d-%H%M%S)] WATCHDOG ok (vps=$VPS_OK pc=$PC_OK pg=$NEWEST_PG lh=$LH_NEW)" >> "$LOG"

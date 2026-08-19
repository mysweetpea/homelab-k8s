#!/bin/bash
# jellyfin-presync.sh — keep Gelato streams pre-synced so the media bar and
# detail pages never wait on AIOStreams.
#
# ⚠️ CRITICAL: Gelato's catalog import AND stream syncs both write to the same
# SQLite DB (jellyfin.db). Running them concurrently causes "database table is
# locked" errors and 5-10x slowdowns (verified Aug 19 2026). This script:
#   - SKIPS if Import Catalogs is currently running
#   - is scheduled 30 min AFTER the import (import at :45, sweep at :15)
#   - uses gentle pacing (2 workers, 3s spacing)
#
# Coverage: items created in the last 7 days (new arrivals from the 6h import
# + anything recent). The 24h AIOStreams stream cache keeps old items warm;
# a full-library sweep every 6h is unnecessary and causes contention.
set -u

JF="http://10.43.244.254:8096"
KEY="49486906100e4354904ca425681507e7"
JUSER="3d75456ef9c5438480195d731242133d"
IMPORT_TASK="345218a7c524815276c66422a3923758"
LOG="/var/log/jellyfin-presync.log"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Guard: skip if Import Catalogs is running (SQLite write contention)
STATE=$(curl -s --max-time 10 -H "X-Emby-Token: $KEY" \
  "$JF/ScheduledTasks/$IMPORT_TASK" | jq -r '.State' 2>/dev/null || echo "unknown")
if [ "$STATE" = "Running" ]; then
  log "SKIP: Import Catalogs is Running (avoiding SQLite contention)"
  exit 0
fi

# Items created in the last 7 days
FILTER="IncludeItemTypes=Movie,Series&MinDateCreated=$(date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%S')"
log "Sweep start (7d window, import state=$STATE)"

# Get all IDs (paginated)
IDS=""
SKIP=0
while :; do
  BATCH=$(curl -s --max-time 30 -H "X-Emby-Token: $KEY" \
    "$JF/Items?$FILTER&Recursive=true&fields=Id&Limit=200&StartIndex=$SKIP")
  COUNT=$(echo "$BATCH" | jq -r '.Items | length' 2>/dev/null || echo 0)
  [ "$COUNT" = "0" ] && break
  IDS="$IDS $(echo "$BATCH" | jq -r '.Items[].Id')"
  SKIP=$((SKIP + COUNT))
  [ "$COUNT" -lt 200 ] && break
done

TOTAL=$(echo $IDS | wc -w)
log "Found $TOTAL items to pre-sync"
[ "$TOTAL" = "0" ] && log "Nothing to do" && exit 0

# Pre-sync with gentle pacing: 2 parallel, 3s apart
DONE=0
for ID in $IDS; do
  (
    curl -s --max-time 90 -o /dev/null -H "X-Emby-Token: $KEY" \
      "$JF/Users/$JUSER/Items/$ID?fields=Id,Name"
  ) &
  # Keep max 2 in flight
  while [ "$(jobs -r | wc -l)" -ge 2 ]; do
    wait -n 2>/dev/null || sleep 1
  done
  sleep 3
  DONE=$((DONE + 1))
  if [ $((DONE % 25)) -eq 0 ]; then
    log "  $DONE/$TOTAL done"
  fi
done
wait
log "Sweep complete: $DONE items"

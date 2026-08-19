#!/bin/bash
# jellyfin-presync.sh — keep Gelato streams pre-synced so the media bar and
# detail pages never wait on AIOStreams.
#
# Strategy:
#   - "new" mode (every 30 min): pre-sync items created in the last 24h
#     (new arrivals from the 6h Import Catalogs task)
#   - "full" mode (every 12h): pre-sync ALL movies to keep the 24h AIOStreams
#     stream cache warm (Gelato's own cache is in-memory and dies on restart)
#
# Pacing: 2 workers, 2s spacing (~1 req/s) — stays under AIOStreams rate limit.
set -u

JF="http://10.43.244.254:8096"
KEY="49486906100e4354904ca425681507e7"
JUSER="3d75456ef9c5438480195d731242133d"
LOG="/var/log/jellyfin-presync.log"

MODE="${1:-new}"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Fetch item IDs (movies only for full; movies+series for new)
if [ "$MODE" = "full" ]; then
  FILTER="IncludeItemTypes=Movie"
  log "FULL sweep start"
else
  FILTER="IncludeItemTypes=Movie,Series&MinDateCreated=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S')"
  log "NEW sweep start (24h window)"
fi

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

# Pre-sync with pacing: 2 parallel, 2s apart
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
  sleep 2
  DONE=$((DONE + 1))
  if [ $((DONE % 25)) -eq 0 ]; then
    log "  $DONE/$TOTAL done"
  fi
done
wait
log "Sweep complete: $DONE items"

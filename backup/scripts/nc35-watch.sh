#!/usr/bin/env bash
# nc35-watch.sh — weekly check: is the Nextcloud 34 -> 35 upgrade safe yet?
# Runs the readiness checker; pushes a Gotify alert to the phone ONLY when it
# flips to READY (or on the first run after being blocked for a long time).
# Silent when still blocked, so it never becomes notification noise.
#
# cron: 0 7 * * 1  (Mondays 07:00, ahead of the plugin-update window)
# state file: /root/.nc35-watch-state  ("ready" once reported, to avoid repeats)

set -uo pipefail

STATE=/root/.nc35-watch-state
TOKEN_FILE=/root/.gotify-backup-token
GOTIFY_URL="http://gotify.private.svc.cluster.local/message"

READY_OUT=$(bash /root/nc35-readiness.sh 2>&1)
RC=$?
echo "[$(date -u '+%Y-%m-%d %H:%M UTC')] nc35-watch rc=$RC"
echo "$READY_OUT" | tail -5

push() {
  local title="$1" body="$2"
  [ -f "$TOKEN_FILE" ] || { echo "  (no gotify token; skipping push)"; return 0; }
  local tok; tok=$(cat "$TOKEN_FILE")
  curl -s --max-time 20 -X POST "$GOTIFY_URL?token=$tok" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"title":sys.argv[1],"message":sys.argv[2],"priority":8}))' "$title" "$body")" \
    -o /dev/null -w '  push http=%{http_code}\n'
}

if [ "$RC" = "0" ]; then
  if [ "$(cat "$STATE" 2>/dev/null)" != "ready" ]; then
    echo ready > "$STATE"
    push "Nextcloud 35 upgrade is READY" \
"35.0.x patch release exists and every previously-blocking app now has an NC35 build.

Unblock procedure:
  1. apps/infra/argocd-image-updater/values.yaml - nextcloud allowTags -> regexp:^\\\\d+\\\\.\\\\d+\\\\.\\\\d+$
     (or set image.tag directly in apps/private/nextcloud/values.yaml)
  2. commit + push; ArgoCD syncs; the entrypoint runs 'occ upgrade' automatically
  3. then: occ app:update --all && occ app:enable <still-disabled apps>
  4. verify: occ status / occ app:list

Ask Hermes to run the upgrade."
  else
    echo "  (already reported ready; still ready)"
  fi
  exit 0
fi

if [ "$RC" = "2" ]; then
  echo "  (could not determine - not alerting)"
  exit 2
fi

# still blocked: only alert if we previously reported ready (i.e. regressed)
if [ "$(cat "$STATE" 2>/dev/null)" = "ready" ]; then
  rm -f "$STATE"
  push "Nextcloud 35 readiness REGRESSED" \
    "The readiness check no longer passes (a new app may have been enabled, or a release was pulled).
Re-run /root/nc35-readiness.sh on the master for details."
fi

echo "  (still blocked - silent)"
exit 1

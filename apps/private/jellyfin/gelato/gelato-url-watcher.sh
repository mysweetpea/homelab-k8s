#!/bin/bash
# gelato-url-watcher.sh — self-healing Gelato manifest URL watcher
# Runs every 5 min via cron on k3s-master.
#
# Behavior:
#  1. Fetches the manifest URL currently configured in Gelato.xml
#  2. If it returns a valid manifest (200 + JSON with "catalogs") → all good, exit
#  3. If broken:
#     a. If /root/gelato-url.txt exists and contains a working URL → update
#        Gelato.xml, restart Jellyfin, alert Gotify
#     b. If no file / URL also broken → alert Gotify asking for the new URL
#
# To use: after a re-import that created a NEW config, paste the new install URL:
#   echo "http://192.168.20.222:3000/stremio/<uuid>/<token>/manifest.json" > /root/gelato-url.txt
# The watcher picks it up within 5 minutes.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=private
POD=$(kubectl get pods -n $NS -l app.kubernetes.io/name=jellyfin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
GOTIFY_URL="http://gotify.private.svc.cluster.local:80"
GOTIFY_TOKEN="gtfya.DKBcq1FCn-8ScZ-Gt_vwYoolVezrirfVN0d9wWbV_hY"
URL_FILE=/root/gelato-url.txt
LOG=/root/gelato-url-watcher.log

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

alert() {
  curl -s -o /dev/null -X POST "$GOTIFY_URL/message" \
    -H "X-Gotify-Key: $GOTIFY_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Gelato URL watcher\",\"message\":\"$1\",\"priority\":8}" 2>/dev/null
}

# Get current URL from Gelato.xml
CURRENT_URL=$(kubectl exec -n $NS "$POD" -- sh -c 'grep -o "Url>[^<]*" /config/plugins/configurations/Gelato.xml | head -1 | cut -c5-' 2>/dev/null)
if [ -z "$CURRENT_URL" ]; then
  log "ERROR: could not read current Gelato URL"
  exit 1
fi

# Test current URL
HTTP_CODE=$(curl -s -o /tmp/gelato-manifest-test.json -w "%{http_code}" --max-time 15 "$CURRENT_URL" 2>/dev/null)
VALID=0
if [ "$HTTP_CODE" = "200" ] && grep -q '"catalogs"' /tmp/gelato-manifest-test.json 2>/dev/null; then
  VALID=1
fi

if [ "$VALID" = "1" ]; then
  # All good — but if a URL file exists and differs, the user wants to switch
  if [ -f "$URL_FILE" ]; then
    NEW_URL=$(head -1 "$URL_FILE" | tr -d ' \n')
    if [ -n "$NEW_URL" ] && [ "$NEW_URL" != "$CURRENT_URL" ]; then
      log "URL file present with different URL — testing it"
      CODE2=$(curl -s -o /tmp/gelato-manifest-test2.json -w "%{http_code}" --max-time 15 "$NEW_URL" 2>/dev/null)
      if [ "$CODE2" = "200" ] && grep -q '"catalogs"' /tmp/gelato-manifest-test2.json 2>/dev/null; then
        log "Switching Gelato URL: $NEW_URL"
        kubectl exec -n $NS "$POD" -- sh -c "sed -i 's|<Url>[^<]*</Url>|<Url>$NEW_URL</Url>|' /config/plugins/configurations/Gelato.xml" 2>/dev/null
        kubectl rollout restart deploy/jellyfin -n $NS 2>/dev/null
        rm -f "$URL_FILE"
        alert "Gelato URL updated to new config and Jellyfin restarted."
        log "DONE: URL switched + Jellyfin restarted"
      else
        log "URL file contains a broken URL — ignoring, keeping current"
        alert "gelato-url.txt contains a URL that does not return a valid manifest. Check it."
      fi
    fi
  fi
  exit 0
fi

# Current URL is broken
log "WARN: current Gelato URL is broken (HTTP $HTTP_CODE)"

if [ -f "$URL_FILE" ]; then
  NEW_URL=$(head -1 "$URL_FILE" | tr -d ' \n')
  CODE2=$(curl -s -o /tmp/gelato-manifest-test2.json -w "%{http_code}" --max-time 15 "$NEW_URL" 2>/dev/null)
  if [ "$CODE2" = "200" ] && grep -q '"catalogs"' /tmp/gelato-manifest-test2.json 2>/dev/null; then
    log "Healing: switching to URL from file: $NEW_URL"
    kubectl exec -n $NS "$POD" -- sh -c "sed -i 's|<Url>[^<]*</Url>|<Url>$NEW_URL</Url>|' /config/plugins/configurations/Gelato.xml" 2>/dev/null
    kubectl rollout restart deploy/jellyfin -n $NS 2>/dev/null
    rm -f "$URL_FILE"
    alert "Gelato manifest was broken — auto-healed with URL from gelato-url.txt. Jellyfin restarted."
    log "DONE: healed"
  else
    log "URL file present but also broken — alerting"
    alert "Gelato manifest URL is broken AND gelato-url.txt does not contain a working URL. Paste the new install URL into /root/gelato-url.txt on k3s-master."
  fi
else
  log "No URL file — alerting"
  alert "Gelato manifest URL is broken (HTTP $HTTP_CODE). If you re-imported AIOStreams with a new config, paste the new install URL: echo '<url>' > /root/gelato-url.txt"
fi

#!/usr/bin/env bash
# nc35-readiness.sh — Is it safe to upgrade Nextcloud 34.x -> 35.x yet?
#
# Run this any time on k3s-master (or the PC). It answers ONE question:
#   "do a 35.0.x patch release AND NC35 builds of all enabled apps exist yet?"
#
# WHY THIS EXISTS: on 2026-09-17 we held the upgrade at 34.x because 35.0.0 was
# 2 days old (.0 release) and 15 enabled apps still declared max-version 34.
# Two of them (drawio, previewgenerator) had NO NC35 release at all.
# The image-updater CR pins allowTags to ^34\. as the enforcement fence.
#
# USAGE:  bash nc35-readiness.sh
# EXIT:   0 = READY to upgrade, 1 = not yet safe, 2 = could not determine
#
# Unblock procedure when this says READY:
#   1. revert allowTags in apps/infra/argocd-image-updater/values.yaml to broad regexp
#      (or set image.tag directly in apps/private/nextcloud/values.yaml)
#   2. commit + push; ArgoCD syncs; entrypoint runs `occ upgrade` automatically
#   3. after it lands: re-enable + update the previously-disabled apps:
#        occ app:update --all
#        occ app:enable <app>   # for anything still disabled
#   4. verify: occ status, occ app:list, then re-run the notify_push self-test

set -uo pipefail

APPSTORE="https://apps.nextcloud.com/api/v1/platform/35.0.0/apps.json"
# minimum acceptable Nextcloud release: a .1+ patch (not the .0)
MIN_NC_PATCH=1
# apps that MUST have a 35-compatible release before we move
REQUIRED_APPS="assistant data_request deck drawio files_accesscontrol files_automatedtagging files_retention forms groupfolders integration_openai memories previewgenerator spreed user_usage_report workflow_script"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Nextcloud 35 upgrade readiness check ==="
echo "date: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo

# ---- 1. is there a 35.x patch release yet? ---------------------------------
echo "--- 1. Nextcloud 35.x releases upstream ---"
TOKEN=$(curl -s --max-time 30 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/nextcloud:pull" \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])" 2>/dev/null)

if [ -z "${TOKEN:-}" ]; then
  echo "  !! could not get docker hub token (network?)"; exit 2
fi

found_patch=0
for p in 0 1 2 3 4 5 6; do
  code=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://registry-1.docker.io/v2/library/nextcloud/manifests/35.0.$p")
  if [ "$code" = "200" ]; then
    echo "  nextcloud:35.0.$p -> EXISTS"
    [ "$p" -ge "$MIN_NC_PATCH" ] && found_patch=1
  else
    echo "  nextcloud:35.0.$p -> absent ($code)"
  fi
done

if [ "$found_patch" = "1" ]; then
  echo "  => 35.0.x PATCH release present (>= 35.0.$MIN_NC_PATCH)"
else
  echo "  => still only the .0 release — NOT ready"
fi
echo

# ---- 2. do all required apps have a 35-compatible release? -----------------
echo "--- 2. app compatibility (NC 35.0.0 app store) ---"
# The app store aggressively rate-limits repeated calls from one IP (the cluster
# egress gets 403/'') so try: (1) direct, (2) VPS egress, (3) local cache.
VPS_HOST="ubuntu@129.213.11.104"
VPS_KEY="/root/.ssh/vps-oracle"   # adjust if the master uses a different key
CACHED="$TMP/apps-cache.json"

fetch_direct() { curl -s --max-time 45 -A 'Mozilla/5.0' "$APPSTORE" -o "$1" 2>/dev/null && [ -s "$1" ] && head -c1 "$1" | grep -q '\['; }
fetch_vps()    { [ -f "$VPS_KEY" ] && ssh -i "$VPS_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$VPS_HOST" \
                   "curl -s --max-time 60 -A 'Mozilla/5.0' '$APPSTORE'" > "$1" 2>/dev/null && [ -s "$1" ] && head -c1 "$1" | grep -q '\['; }
fetch_cache()  { [ -s /root/pg-dumps/nc35-apps-cache.json ] && cp /root/pg-dumps/nc35-apps-cache.json "$1" && head -c1 "$1" | grep -q '\['; }

if   fetch_direct "$TMP/apps.json"; then echo "  (fetched direct)"
elif fetch_vps    "$TMP/apps.json"; then echo "  (fetched via VPS egress)"
elif fetch_cache  "$TMP/apps.json"; then echo "  (used cached copy - may be stale)"
else
  echo "  !! could not fetch app store from direct, VPS, or cache"
  echo "     seed the cache:  scp apps.json root@192.168.20.40:/root/pg-dumps/nc35-apps-cache.json"
  exit 2
fi
cp "$TMP/apps.json" /root/pg-dumps/nc35-apps-cache.json 2>/dev/null || true

python3 - "$TMP/apps.json" $REQUIRED_APPS <<'PY'
import json, sys, re
apps = json.load(open(sys.argv[1]))
required = sys.argv[2:]
by_id = {a["id"]: a for a in apps}

def ok(spec, major):
    if not spec: return False
    for op, val in re.findall(r'([<>]=?)\s*(\d+)', spec):
        v = int(val)
        if op == '>=' and not major >= v: return False
        if op == '<=' and not major <= v: return False
        if op == '>'  and not major >  v: return False
        if op == '<'  and not major <  v: return False
    return True

missing = []
for appid in required:
    a = by_id.get(appid)
    if not a:
        missing.append(appid); print(f"  ✗ {appid:<24} no NC35 release"); continue
    stable = [r for r in a.get("releases",[]) if not r.get("isNightly") and "-" not in str(r.get("version",""))]
    if not stable:
        missing.append(appid); print(f"  ✗ {appid:<24} only pre-releases"); continue
    r = stable[0]
    print(f"  ✓ {appid:<24} {r.get('version')}")

print()
if missing:
    print(f"NOT READY — {len(missing)} app(s) without an NC35 stable release: {', '.join(missing)}")
    sys.exit(1)
print("ALL REQUIRED APPS have an NC35 stable release.")
PY
apps_rc=$?
echo

# ---- verdict ---------------------------------------------------------------
echo "=== VERDICT ==="
if [ "$found_patch" = "1" ] && [ "$apps_rc" = "0" ]; then
  echo "READY: 35.0.x patch exists AND every enabled app has a 35 release."
  echo "Follow the unblock procedure in this script's header."
  exit 0
else
  [ "$found_patch" != "1" ] && echo "blocked: no 35.0.$MIN_NC_PATCH+ patch release yet"
  [ "$apps_rc" != "0" ]    && echo "blocked: at least one app lacks an NC35 release"
  echo "Hold at 34.x. Re-run in a few days."
  exit 1
fi

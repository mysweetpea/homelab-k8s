#!/bin/bash
# homelab — manage script left on the user's machine (P5).
#   ./homelab status     show apps in the plan + ArgoCD sync state
#   ./homelab urls       print service URLs (subdomain + domain from plan)
#   ./homelab open <app> print the URL for one app
set -u
PLAN_FILE="${MSP_PLAN_FILE:-./homelab-plan.env}"
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$PLAN_FILE" ] || PLAN_FILE="$DIR/homelab-plan.env"
[ -f "$PLAN_FILE" ] || { echo "no plan file found (looked in . and $DIR)"; exit 1; }
# shellcheck disable=SC1090
. "$PLAN_FILE"

cmd="${1:-status}"
DOMAIN="${MSP_DOMAIN:-}"
case "$cmd" in
  status)
    echo "Apps in your homelab ($MSP_METHOD mode):"
    for a in $MSP_APPS; do
      sync=$(kubectl -n argocd get application "$a" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "?")
      health=$(kubectl -n argocd get application "$a" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "?")
      printf '  %-24s sync=%-10s health=%s\n' "$a" "$sync" "$health"
    done
    ;;
  urls)
    get_sub() {
      catalog_app "$1" 2>/dev/null | cut -d"|" -f6
    }
    if ! declare -F catalog_load >/dev/null 2>&1; then
      . "$DIR/lib/catalog.sh"
      catalog_load "$DIR/services.yaml"
    fi
    for a in $MSP_APPS; do
      sub=$(get_sub "$a")
      if [ -n "$sub" ] && [ -n "$DOMAIN" ]; then
        printf '  https://%s.%s
' "$sub" "$DOMAIN"
      else
        printf '  %-24s (no domain configured)
' "$a"
      fi
    done
    ;;
  open)
    app="${2:-}"
    [ -n "$app" ] || { echo "usage: homelab open <app>"; exit 1; }
    . "$DIR/lib/catalog.sh"
    catalog_load "$DIR/services.yaml"
    sub=$(catalog_app "$app" 2>/dev/null | cut -d"|" -f6)
    if [ -n "$sub" ] && [ -n "$DOMAIN" ]; then
      printf 'https://%s.%s
' "$sub" "$DOMAIN"
    else
      echo "no URL for $app"; exit 1
    fi
    ;;
  *) echo "usage: homelab [status|urls|open <app>]"; exit 1 ;;
esac

#!/bin/bash
# Config backup script
# Backs up all Kubernetes configs (deployments, secrets-list, configmaps, PVCs,
# services, networkpolicies) to /root/config-backup/<date>/.
# The restic chain (restic-backup.sh §config-backup) ships this directory to the
# VPS + PC repos — there is no direct rsync here.
# Exits non-zero if ANY dump failed, so cron/alerting can see real failures.

set -e
DATE=$(date +%Y%m%d)
BACKUP_DIR="/root/config-backup/$DATE"
mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting config backup..."

FAILED=0

# Backup all namespaces
for ns in private dmz monitoring argocd kube-system longhorn-system; do
  echo "  - Backing up namespace: $ns"
  mkdir -p "$BACKUP_DIR/$ns"

  # Each dump: write to a temp file, verify it's non-empty, then move into place.
  # A failed kubectl (API down, RBAC, auth expiry) must NOT look like success.
  dump() {
    local what="$1" out="$2"; shift 2
    if kubectl "$@" -n "$ns" > "$out.tmp" 2>"$out.err"; then
      if [ -s "$out.tmp" ]; then
        mv "$out.tmp" "$out"; rm -f "$out.err"; return 0
      fi
      echo "    !! $what: empty output" >&2
    else
      echo "    !! $what FAILED: $(tr '\n' ' ' < "$out.err" | cut -c1-200)" >&2
    fi
    rm -f "$out.tmp" "$out.err"
    FAILED=$((FAILED + 1))
    return 0
  }

  dump "deployments"     "$BACKUP_DIR/$ns/deployments.yaml"     get deployments -o yaml
  dump "statefulsets"    "$BACKUP_DIR/$ns/statefulsets.yaml"    get statefulsets -o yaml
  dump "configmaps"      "$BACKUP_DIR/$ns/configmaps.yaml"      get configmaps -o yaml
  dump "secrets-list"    "$BACKUP_DIR/$ns/secrets-list.txt"     get secrets -o name
  dump "pvcs"            "$BACKUP_DIR/$ns/pvcs.yaml"            get pvc -o yaml
  dump "services"        "$BACKUP_DIR/$ns/services.yaml"        get services -o yaml
  dump "networkpolicies" "$BACKUP_DIR/$ns/networkpolicies.yaml" get networkpolicies -o yaml
done

# ArgoCD applications
if kubectl get applications -n argocd -o yaml > "$BACKUP_DIR/argocd-applications.yaml.tmp" 2>"$BACKUP_DIR/argocd.err"; then
  if [ -s "$BACKUP_DIR/argocd-applications.yaml.tmp" ]; then
    mv "$BACKUP_DIR/argocd-applications.yaml.tmp" "$BACKUP_DIR/argocd-applications.yaml"
    rm -f "$BACKUP_DIR/argocd.err"
  else
    echo "  !! argocd-applications: empty output" >&2; FAILED=$((FAILED + 1))
    rm -f "$BACKUP_DIR/argocd-applications.yaml.tmp" "$BACKUP_DIR/argocd.err"
  fi
else
  echo "  !! argocd-applications FAILED: $(tr '\n' ' ' < "$BACKUP_DIR/argocd.err" | cut -c1-200)" >&2
  FAILED=$((FAILED + 1))
  rm -f "$BACKUP_DIR/argocd-applications.yaml.tmp" "$BACKUP_DIR/argocd.err"
fi

# Keep only last 7 days (never delete silently)
find /root/config-backup -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

if [ "$FAILED" -gt 0 ]; then
  echo "[$(date)] Config backup completed WITH $FAILED FAILURE(S) — see !! lines above."
  exit 1
fi
echo "[$(date)] Config backup complete."

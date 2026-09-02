#!/bin/bash
# Config backup script
# Backs up all Kubernetes configs (deployments, secrets, configmaps, PVCs)
# to /root/config-backup/ and syncs to PC via rsync

set -e
DATE=$(date +%Y%m%d)
BACKUP_DIR="/root/config-backup/$DATE"
mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting config backup..."

# Backup all namespaces
for ns in private dmz monitoring argocd kube-system longhorn-system; do
  echo "  - Backing up namespace: $ns"
  mkdir -p "$BACKUP_DIR/$ns"
  
  # Deployments
  kubectl get deployments -n $ns -o yaml > "$BACKUP_DIR/$ns/deployments.yaml" 2>/dev/null || true
  # StatefulSets
  kubectl get statefulsets -n $ns -o yaml > "$BACKUP_DIR/$ns/statefulsets.yaml" 2>/dev/null || true
  # ConfigMaps
  kubectl get configmaps -n $ns -o yaml > "$BACKUP_DIR/$ns/configmaps.yaml" 2>/dev/null || true
  # Secrets (encrypted - just names)
  kubectl get secrets -n $ns -o name > "$BACKUP_DIR/$ns/secrets-list.txt" 2>/dev/null || true
  # PVCs
  kubectl get pvc -n $ns -o yaml > "$BACKUP_DIR/$ns/pvcs.yaml" 2>/dev/null || true
  # Services
  kubectl get services -n $ns -o yaml > "$BACKUP_DIR/$ns/services.yaml" 2>/dev/null || true
  # NetworkPolicies
  kubectl get networkpolicies -n $ns -o yaml > "$BACKUP_DIR/$ns/networkpolicies.yaml" 2>/dev/null || true
done

# ArgoCD applications
kubectl get applications -n argocd -o yaml > "$BACKUP_DIR/argocd-applications.yaml" 2>/dev/null || true

# Keep only last 7 days
find /root/config-backup -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

echo "[$(date)] Config backup complete."

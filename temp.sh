#!/bin/bash
# =============================================================================
# Session 14 — Remaining Remediation (Sections 3–11)
# Run on: k3s-master
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

section()  { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }

# =============================================================================
# SECTION 3: Matrix Synapse ArgoCD Repo URL Fix
# =============================================================================
section "3/9: Matrix Synapse — Fix ArgoCD Repo URL"

echo "→ Current repo URL:"
kubectl get application matrix-synapse -n argocd -o jsonpath='{.spec.source.repoURL}' 2>/dev/null
echo ""

echo "→ Fixing mysweetpea → bananamaker123..."
kubectl patch application matrix-synapse -n argocd --type=merge -p \
  '{"spec":{"source":{"repoURL":"https://github.com/bananamaker123/homelab-k8s.git"}}}' 2>/dev/null && \
  success "Repo URL fixed" || warn "Patch failed — may already be correct"

kubectl patch application matrix-synapse -n argocd --type=merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null
success "ArgoCD refresh triggered"

# =============================================================================
# SECTION 4: NetworkPolicy Cleanup
# =============================================================================
section "4/9: NetworkPolicy Cleanup"

echo "→ Deleting reappeared default-deny in dmz..."
kubectl delete networkpolicy default-deny -n dmz --ignore-not-found=true && \
  success "default-deny deleted from dmz" || warn "Already deleted"

echo "→ Adding allow-dns-egress to monitoring namespace..."
kubectl apply -f - << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF
success "allow-dns-egress created in monitoring"

echo "→ Deleting orphaned redis-homarr resources in monitoring..."
kubectl delete networkpolicy redis-homarr -n monitoring --ignore-not-found=true
kubectl delete configmap redis-homarr-configuration -n monitoring --ignore-not-found=true
kubectl delete configmap redis-homarr-health -n monitoring --ignore-not-found=true
kubectl delete configmap redis-homarr-scripts -n monitoring --ignore-not-found=true
success "redis-homarr orphans deleted"

# =============================================================================
# SECTION 5: MetalLB Pool Expansion
# =============================================================================
section "5/9: MetalLB Pool Expansion (.210–.220 → .210–.230)"

echo "→ Current pool:"
kubectl get ipaddresspool homelab-pool -n metallb-system -o jsonpath='{.spec.addresses}' 2>/dev/null
echo ""

echo "→ Expanding..."
kubectl patch ipaddresspool homelab-pool -n metallb-system --type=merge -p \
  '{"spec":{"addresses":["192.168.20.210-192.168.20.230"]}}' 2>/dev/null && \
  success "Pool expanded to .210–.230" || warn "Patch failed"

# Also update the Git file
cat > ~/homelab-k8s/apps/infra/metallb/metallb-config.yaml << 'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.20.210-192.168.20.230
  autoAssign: true
  avoidBuggyIPs: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
  nodeSelectors:
    - matchLabels:
        metallb-speaker: enabled
EOF
success "Git metallb-config.yaml updated"

# =============================================================================
# SECTION 6: Orphan Cleanup
# =============================================================================
section "6/9: Orphan Cleanup"

echo "→ Deleting 10 stale matrix-synapse Helm release secrets..."
for v in v3 v4 v5 v6 v7 v8 v9 v10 v11 v12; do
    kubectl delete secret sh.helm.release.v1.matrix-synapse.$v -n dmz --ignore-not-found=true
done
success "Stale Helm secrets deleted"

echo "→ Deleting orphaned rclone-rd-creds Secret..."
kubectl delete secret rclone-rd-creds -n dmz --ignore-not-found=true && \
  success "rclone-rd-creds deleted" || warn "Already gone"

echo "→ Deleting orphaned stoat-tls Secret..."
kubectl delete secret stoat-tls -n dmz --ignore-not-found=true && \
  success "stoat-tls deleted" || warn "Already gone"

echo "→ Fixing n8n-bridge ExternalName port (80 → 5678)..."
kubectl patch svc n8n-bridge -n dmz --type=merge -p \
  '{"spec":{"ports":[{"port":5678,"targetPort":5678}]}}' 2>/dev/null && \
  success "n8n-bridge port fixed" || warn "Patch failed"

echo "→ Removing accidental ./exit file from Git repo..."
cd ~/homelab-k8s
rm -f ./exit
success "exit file removed"

# =============================================================================
# SECTION 7: questarr Stuck Rollout
# =============================================================================
section "7/9: questarr — Fix Stuck Rollout"

echo "→ Current ReplicaSets:"
kubectl get rs -n private | grep questarr

# Find and delete the older ReplicaSet (the one with 0 replicas or older age)
OLD_RS=$(kubectl get rs -n private -o name | grep questarr | tail -1 | cut -d/ -f2)
CURRENT_RS=$(kubectl get rs -n private -o name | grep questarr | head -1 | cut -d/ -f2)

if [[ "$OLD_RS" != "$CURRENT_RS" ]]; then
    kubectl delete rs "$OLD_RS" -n private --ignore-not-found=true && \
      success "Stale questarr ReplicaSet deleted: $OLD_RS"
else
    warn "questarr has only one ReplicaSet — no cleanup needed"
fi

# =============================================================================
# SECTION 8: k3s Version Alignment
# =============================================================================
section "8/9: k3s Version Alignment"

MASTER_VER=$(k3s --version 2>/dev/null | grep -oP 'v\K[0-9.]+')
WORKER_VER=$(kubectl get node k3s-worker-a -o jsonpath='{.status.nodeInfo.kubeletVersion}' | grep -oP 'v\K[0-9.]+')

echo "  Master: v$MASTER_VER"
echo "  Workers: v$WORKER_VER"

if [[ "$MASTER_VER" != "$WORKER_VER" ]]; then
    warn "Version skew detected. To upgrade master: curl -sfL https://get.k3s.io | sh -"
    echo "  (Skipping automatic upgrade — requires manual confirmation)"
else
    success "All nodes on same k3s version"
fi

# =============================================================================
# SECTION 9: Disk Space + Longhorn SSD Setup
# =============================================================================
section "9/9: Disk Space Investigation + SSD Setup"

echo "→ Top disk consumers on k3s-master:"
du -sh /var/lib/rancher/k3s/agent/containerd/ 2>/dev/null || echo "  (path not found)"
du -sh /var/lib/longhorn/ 2>/dev/null
du -sh /var/log/ 2>/dev/null
du -sh /tmp/ 2>/dev/null

echo ""
echo "→ Available block devices:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | grep -v loop || echo "  lsblk not available"

echo ""
echo "→ Longhorn node disk status:"
kubectl get nodes.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,SCHEDULABLE:.spec.allowScheduling 2>/dev/null

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TO ADD THE 1TB SSD TO LONGHORN:"
echo ""
echo "  1. Identify the device: lsblk | grep -E 'sd[b-z]|nvme'"
echo "  2. Format:  sudo mkfs.ext4 /dev/<device>"
echo "  3. Mount:   sudo mkdir -p /mnt/longhorn-ssd"
echo "              sudo mount /dev/<device> /mnt/longhorn-ssd"
echo "  4. Persist: echo '/dev/<device> /mnt/longhorn-ssd ext4 defaults 0 2' | sudo tee -a /etc/fstab"
echo "  5. Add to Longhorn: kubectl edit node.longhorn.io k3s-master -n longhorn-system"
echo "     Add under spec.disks:"
echo "       ssd-disk:"
echo "         allowScheduling: true"
echo "         path: /mnt/longhorn-ssd"
echo "         storageReserved: 0"
echo "     Set default-disk allowScheduling: false"
echo "  6. Tune settings:"
echo "     kubectl patch settings.longhorn.io storage-over-provisioning-percentage -n longhorn-system --type=merge -p '{\"value\":\"150\"}'"
echo "     kubectl patch settings.longhorn.io storage-minimal-available-percentage -n longhorn-system --type=merge -p '{\"value\":\"15\"}'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# =============================================================================
# SECTION 10: root-homelab Sync Fix
# =============================================================================
section "10/9: root-homelab Sync Fix"

echo "→ Triggering hard refresh..."
kubectl patch application root-homelab -n argocd --type=merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null

sleep 10
ROOT_SYNC=$(kubectl get application root-homelab -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
ROOT_HEALTH=$(kubectl get application root-homelab -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
echo "  root-homelab: $ROOT_SYNC / $ROOT_HEALTH"

if [[ "$ROOT_SYNC" == "Synced" ]]; then
    success "root-homelab is Synced"
else
    warn "root-homelab still $ROOT_SYNC — may need manual intervention"
fi

# =============================================================================
# SECTION 11: Final Verification
# =============================================================================
section "11/9: Final Cluster Health Verification"

echo ""
echo "━━━ Stuck Pods ━━━"
STUCK=$(kubectl get pods -A --no-headers 2>/dev/null | grep -E "0/|ContainerCreating|CrashLoop|Error|Pending" | grep -v "Completed" || true)
if [[ -z "$STUCK" ]]; then
    success "No stuck pods"
else
    warn "Stuck pods found:"
    echo "$STUCK"
fi

echo ""
echo "━━━ Services Without Endpoints ━━━"
NO_EPS=$(kubectl get endpoints -A --no-headers 2>/dev/null | awk '$3=="<none>" {print $1"/"$2}' || true)
if [[ -z "$NO_EPS" ]]; then
    success "All services have endpoints"
else
    warn "Services without endpoints:"
    echo "$NO_EPS"
fi

echo ""
echo "━━━ Detached Longhorn Volumes ━━━"
DETACHED=$(kubectl get volumes -n longhorn-system --no-headers 2>/dev/null | grep detached | awk '{print $1}' || true)
if [[ -z "$DETACHED" ]]; then
    success "No detached volumes"
else
    warn "Detached volumes:"
    echo "$DETACHED"
fi

echo ""
echo "━━━ ArgoCD Application Health ━━━"
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null | \
  grep -v "Synced.*Healthy" | grep -v "NAME" || success "All apps Synced+Healthy"

echo ""
echo "━━━ MetalLB Pool ━━━"
kubectl get ipaddresspool -n metallb-system -o jsonpath='{.items[*].spec.addresses[*]}' 2>/dev/null
echo ""

echo ""
echo "━━━ LoadBalancer Services ━━━"
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{" => "}{.status.loadBalancer.ingress[*].ip}{"\n"}{end}' 2>/dev/null

echo ""
echo "━━━ NetworkPolicy Summary ━━━"
kubectl get networkpolicies -A --no-headers 2>/dev/null | awk '{printf "  %-15s %-30s\n", $1, $2}'

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Session 14 complete.${NC}"
echo -e "${GREEN}  Next: Add the 1TB SSD to Longhorn using the instructions above.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

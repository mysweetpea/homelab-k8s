#!/bin/bash
# provision-k3s.sh — turn a fresh Linux box into a k3s node ready for the
# installer (Phase 4). Runs ON the target machine (or over ssh).
#
#   curl -fsSL .../installer/provision-k3s.sh | bash
#   or: ./installer/provision-k3s.sh [--with-longhorn] [--with-metallb-range RANGE]
#
# What it does:
#   1. sanity: Linux + root/sudo + systemd + min 4GB RAM
#   2. install k3s (official get.k3s.io) with a kubeconfig the user can read
#   3. wait for the node Ready
#   4. optional: MetalLB (manifest) so services get real LAN IPs
#   5. print next step: run the installer wizard
#
# Idempotent: safe to re-run; skips already-done steps.

set -u

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

WITH_LONGHORN=0
METALLB_RANGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-longhorn) WITH_LONGHORN=1 ;;
    --with-metallb-range) METALLB_RANGE="${2:-}"; shift ;;
    *) warn "unknown arg: $1" ;;
  esac
  shift
done

# ---------------------------------------------------------------- 1. sanity
[ "$(uname -s)" = "Linux" ] || die "this script targets Linux (got: $(uname -s))"
if [ "$(id -u)" != "0" ]; then
  command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
  SUDO=sudo
else
  SUDO=""
fi
command -v systemctl >/dev/null 2>&1 || die "systemd required (no systemctl)"
RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $1}')
[ -n "${RAM_KB:-}" ] && [ "$RAM_KB" -lt 3700000 ] && \
  die "needs at least 4GB RAM (found $((RAM_KB/1024))MB)"

# ---------------------------------------------------------------- 2. k3s
if command -v k3s >/dev/null 2>&1; then
  log "k3s already installed: $(k3s --version | head -1)"
else
  log "installing k3s (official installer)..."
  curl -fsSL https://get.k3s.io | $SUDO sh -s - server \
    --write-kubeconfig-mode 644 || die "k3s install failed"
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
$SUDO chmod 644 /etc/rancher/k3s/k3s.yaml 2>/dev/null

# ---------------------------------------------------------------- 3. ready
log "waiting for node Ready (up to 3m)..."
for _ in $(seq 1 36); do
  if kubectl get node 2>/dev/null | grep -q ' Ready'; then
    log "node Ready: $(kubectl get node -o jsonpath='{.items[0].metadata.name}')"
    break
  fi
  sleep 5
  [ "$_" = 36 ] && die "node never became Ready (journalctl -u k3s for logs)"
done

# ---------------------------------------------------------------- 4. MetalLB
if [ -n "$METALLB_RANGE" ]; then
  if kubectl get ns metallb-system >/dev/null 2>&1; then
    log "MetalLB already present"
  else
    log "installing MetalLB (pool $METALLB_RANGE)..."
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml || die "metallb apply failed"
    for _ in $(seq 1 24); do
      kubectl -n metallb-system wait --for=condition=Available deploy/controller --timeout=5s >/dev/null 2>&1 && break
      sleep 5
    done
    kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses: [$METALLB_RANGE]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan
  namespace: metallb-system
EOF
    log "MetalLB pool created"
  fi
fi

# ---------------------------------------------------------------- 5. longhorn hint
if [ "$WITH_LONGHORN" = 1 ]; then
  log "longhorn: install via the installer wizard (core bundle) — needs open-iscsi:"
  $SUDO apt-get install -y open-iscsi 2>/dev/null \
    || $SUDO dnf install -y iscsi-initiator-utils 2>/dev/null \
    || warn "install open-iscsi manually for Longhorn"
fi

# ---------------------------------------------------------------- done
NODEIP=$(hostname -I 2>/dev/null | awk '{print $1}')
log "cluster ready."
printf '\nNext steps:\n'
printf '  1. copy the kubeconfig to the machine that runs the installer:\n'
printf '     scp this box:%s  ~/.kube/config\n' "/etc/rancher/k3s/k3s.yaml"
printf '  2. run the installer wizard there:\n'
printf '     ./installer/wizard.sh\n'
printf '\nAPI: https://%s:6443\n' "${NODEIP:-<node-ip>}"

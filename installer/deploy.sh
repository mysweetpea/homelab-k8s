#!/bin/bash
# deploy.sh — execute a wizard plan (Phase 5).
#
#   ./installer/deploy.sh --plan ./homelab-plan.env [--dry-run]
#
# METHOD=github   -> ensures fork, hands FORK to install.sh (existing engine)
# METHOD=appliance-> renders Applications via lib/appliance.sh, applies them,
#                    seals + applies secrets, skips git entirely
# Writes: ./homelab-credentials.txt (guided mode), ./homelab (manage script)

set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)

PLAN=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN="${2:-}"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
  shift
done
[ -n "$PLAN" ] && [ -f "$PLAN" ] || { echo "need --plan <file>"; exit 1; }
# shellcheck disable=SC1090
. "$PLAN"

APPS="${MSP_APPS:-}"
[ -n "$APPS" ] || { echo "plan has no MSP_APPS"; exit 1; }
METHOD="${MSP_METHOD:-appliance}"
DOMAIN="${MSP_DOMAIN:-}"
SSO="${MSP_SSO:-no}"
EXPOSURE="${MSP_EXPOSURE:-lan}"
MODE="${MSP_MODE:-guided}"

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

. installer/lib/catalog.sh
catalog_load installer/services.yaml
. installer/lib/appliance.sh

# ---------------------------------------------------------------- github mode
if [ "$METHOD" = "github" ]; then
  . installer/lib/github.sh
  gh_have || die "GitHub CLI (gh) required for METHOD=github (or re-run wizard and choose 'On this machine')"
  FORK=$(gh_ensure_fork) || die "could not ensure fork"
  log "fork ready: $FORK"
  log "handing off to install.sh (existing engine)..."
  exec env SERVICES="$APPS" FORK="$FORK" DOMAIN="${DOMAIN:-mysweetpea.cc}" YES=1 \
    ./installer/install.sh $([ "$DRY_RUN" = 1 ] && echo --dry-run)
fi

# ---------------------------------------------------------------- appliance mode
log "appliance mode: rendering $APPS"
OUTDIR="$REPO_ROOT/.msp-plan"
mkdir -p "$OUTDIR"

# core infra first if any infra app is in the plan (rendered Apps need their CRDs;
# argocd itself must exist before any Application applies)
have kubectl || die "kubectl required"
kubectl get --raw /readyz >/dev/null 2>&1 || die "kubectl cannot reach the cluster"
if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  warn "ArgoCD CRDs missing — install the core bundle first:"
  warn "  ./installer/install.sh BUNDLES=core"
  die "prerequisite missing"
fi

RENDERED=()
for app in $APPS; do
  idx=$(catalog_index "$app" 2>/dev/null) || { warn "unknown app: $app"; continue; }
  d=$(find apps -mindepth 2 -maxdepth 2 -type d -name "$app" | head -1)
  [ -n "$d" ] || { warn "no app dir for $app"; continue; }
  out="$OUTDIR/$app.yaml"
  MSP_DOMAIN_OVERRIDE="${DOMAIN:-}" appliance_render "$d" "$out" || continue
  RENDERED+=("$out")
done
[ ${#RENDERED[@]} -gt 0 ] || die "nothing rendered"

if [ "$DRY_RUN" = 1 ]; then
  log "dry-run: would apply:"
  printf '  %s\n' "${RENDERED[@]}"
  exit 0
fi

for f in "${RENDERED[@]}"; do
  if kubectl apply -f "$f" >/dev/null 2>&1; then
    log "applied $(basename "$f")"
  else
    warn "apply failed: $(basename "$f")"
  fi
done

# secrets (guided): generate + apply for catalog entries of selected apps.
# Sealed when kubeseal is available (fetching the controller cert), else the
# secret is created plain with a loud warning (single-box local cluster only).
if [ "${MSP_SECRETS:-guided}" = "guided" ]; then
  SS_CERT=""
  if have kubeseal; then
    SS_CERT="$OUTDIR/sealed-secrets-cert.pem"
    appliance_backup_ss_cert "$SS_CERT" || SS_CERT=""
  fi
  for app in $APPS; do
    [ -f "$OUTDIR/$app.yaml" ] || continue
    ns=$(kubectl get -f "$OUTDIR/$app.yaml" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null)
    [ -n "$ns" ] || continue
    while IFS= read -r sec; do
      sname="${sec%%:*}"; keys="${sec#*:}"
      [ "$sname" = "$sec" ] && continue
      args=""
      IFS=',' read -ra KL <<< "$keys"
      for k in "${KL[@]}"; do
        v=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
        args="$args --from-literal=$k=$v"
      done
      # shellcheck disable=SC2086
      if [ -n "$SS_CERT" ]; then
        if kubectl -n "$ns" create secret generic "$sname" $args --dry-run=client -o yaml 2>/dev/null \
          | kubeseal --cert "$SS_CERT" -o yaml 2>/dev/null \
          | kubectl apply -f - >/dev/null 2>&1; then
          log "sealed secret $ns/$sname created"
        else
          warn "sealed secret $ns/$sname failed"
        fi
      else
        # shellcheck disable=SC2086
        if kubectl -n "$ns" create secret generic "$sname" $args >/dev/null 2>&1; then
          warn "secret $ns/$sname created UNSEALED (install kubeseal for sealed secrets)"
        else
          warn "secret $ns/$sname failed"
        fi
      fi
    done < <(catalog_secrets "$app")
  done
fi

log "appliance deployment applied."
printf '\nWhat next:\n'
printf '  - ArgoCD will reconcile your apps automatically\n'
printf '  - dashboard: kubectl -n argocd port-forward svc/argocd-server 8080:443\n'
exit 0

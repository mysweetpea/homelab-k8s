#!/usr/bin/env bash
# MySweetPea homelab — self-hosting installer (fork-first GitOps).
#
# Deploys any subset of the services from this repo to YOUR cluster:
#   - rewires every ArgoCD Application to read values from YOUR fork
#     (upstream repoURLs would silently override your local edits)
#   - creates the namespaces the Applications expect to already exist
#   - derives each app's required secrets from its values.yaml (inline
#     secretKeyRef pairs, any indentation) plus installer/services.yaml
#     (chart-level/envFrom secrets the parser cannot see)
#   - generates placeholder secrets with random values, seals them with
#     kubeseal against YOUR cluster, applies them
#   - optionally rewires mysweetpea.cc -> your domain and strips hardcoded
#     MetalLB IPs
#   - applies only the selected ArgoCD applications
#
# Requirements: bash, git, kubectl (connected), kubeseal,
#               sealed-secrets controller in the cluster.
#
# Usage:
#   ./installer/install.sh                 # interactive
#   ./installer/install.sh --dry-run       # show what would happen, change nothing
#   DOMAIN=example.com BUNDLES=core,media ./installer/install.sh --yes
#
# Env overrides (skip the corresponding prompt):
#   DOMAIN          your domain (default: keep mysweetpea.cc)
#   BUNDLES         comma-separated bundle names or numbers
#   SERVICES        space-separated individual service names
#   FORK            your fork URL (default: derived from `git remote get-url origin`)
#   STRIP_LB        y to strip hardcoded 192.168.20.x loadBalancerIPs
#   YES=1           assume yes; never prompt (requires enough env to decide)

set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
say()  { printf "%s\n" "${BOLD}$*${RESET}"; }
ok()   { printf "  %s✓%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "  %s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
err()  { printf "  %s✗%s %s\n" "$RED" "$RESET" "$*"; }
die()  { err "$*"; exit 1; }

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  YES=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done
[ "${DRY_RUN}" = "1" ] && warn "DRY RUN — nothing will be modified or applied"

# ask <var> <prompt> <default>   (reads from env if set, respects YES/dry-run)
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __ans=""
  if [ -n "${!__var:-}" ]; then return 0; fi
  if [ "${YES:-0}" = "1" ] || [ ! -t 0 ]; then
    printf -v "$__var" '%s' "$__default"
    return 0
  fi
  read -r -p "$__prompt" __ans || true
  [ -n "$__ans" ] || __ans="$__default"
  printf -v "$__var" '%s' "$__ans"
}

# ---------- preflight ----------
say "── Preflight"
command -v kubectl  >/dev/null || die "kubectl not found in PATH"
command -v kubeseal >/dev/null || die "kubeseal not found (github.com/bitnami-labs/sealed-secrets)"
command -v openssl  >/dev/null || die "openssl not found"
command -v git      >/dev/null || die "git not found"
[ -d apps ] || die "run this from the repo root (apps/ not found)"
kubectl get --raw /readyz >/dev/null 2>&1 || die "kubectl cannot reach the cluster"
ok "kubectl reaches the cluster"

# sealed-secrets controller: find the deployment, then its SERVICE (exact match).
SS_NS=$(kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | awk '/sealed-secrets-controller|[[:space:]]sealed-secrets$/{print $1; exit}')
if [ -z "$SS_NS" ]; then
  die "sealed-secrets controller not found — install it first:
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
    helm install -n kube-system sealed-secrets sealed-secrets/sealed-secrets"
fi
# Prefer the service the controller actually serves on; fall back to any svc whose
# name starts with sealed-secrets-controller. NEVER take an arbitrary first service:
# the wrong name makes kubeseal fail with 'cannot fetch certificate'.
SVC_NAME=$(kubectl -n "$SS_NS" get svc -o name 2>/dev/null \
           | sed 's|^service/||' \
           | grep -E '^sealed-secrets-controller$|^sealed-secrets$' \
           | head -1 || true)
if [ -z "$SVC_NAME" ]; then
  SVC_NAME=$(kubectl -n "$SS_NS" get svc -o name 2>/dev/null \
             | sed 's|^service/||' | grep -E 'sealed-secrets' | grep -v -- '-metrics$' | head -1 || true)
fi
[ -n "$SVC_NAME" ] || die "sealed-secrets controller service not found in ns/$SS_NS"
if [ "${DRY_RUN}" = "0" ]; then
  # verify the name actually works before we rely on it for every secret
  if ! printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: msp-preflight\n  namespace: default\nstringData:\n  a: b\n' \
       | kubeseal --controller-namespace "$SS_NS" --controller-name "$SVC_NAME" --format yaml >/dev/null 2>&1; then
    die "kubeseal cannot talk to controller '$SVC_NAME' in ns/$SS_NS — check the name/service"
  fi
fi
ok "sealed-secrets: ns/$SS_NS, controller service '$SVC_NAME'"
KUBESEAL_ARGS=(--controller-namespace "$SS_NS" --controller-name "$SVC_NAME")

# ---------- helpers ----------
# Accepts "name" or "zone/name". Bare names that exist in more than one zone are
# ambiguous — we bail loudly rather than silently deploying the wrong app.
app_dir() {
  local want="$1"
  case "$want" in
    */*) [ -d "apps/$want" ] && { echo "apps/$want"; return; } ;;
  esac
  local hits
  hits=$(find apps -mindepth 2 -maxdepth 2 -type d -name "$want" | sort)
  local n; n=$(printf '%s\n' "$hits" | grep -c . || true)
  if [ "$n" -gt 1 ]; then
    die "ambiguous service '$want' — matches: $(printf '%s ' $hits). Use zone/name."
  fi
  printf '%s\n' "$hits" | head -1
}

app_ns() {  # namespace from application.yaml destination
  local f="$1/application.yaml"
  [ -f "$f" ] || { echo ""; return; }
  awk '/destination:/{d=1} d&&/namespace:/{print $2; exit}' "$f"
}

# inline secretKeyRef pairs, any indentation, name-before-key order
inline_refs() {
  awk '
    /secretKeyRef:/ {inref=1; name=""; key=""; next}
    inref && /name:/ {line=$0; sub(/.*name: */,"",line); gsub(/["'"'"']/,"",line); name=line}
    inref && /key:/  {line=$0; sub(/.*key: */,"",line);  gsub(/["'"'"']/,"",line); key=line;
                      if (name!="" && key!="") {print name "\t" key; name=""; key=""}}
    inref && (!/name:|key:/) && /[^ ]/ {inref=0}
  ' "$1" 2>/dev/null
}

# catalog secrets (services.yaml -> secrets.<service>: {name: [keys]})
catalog_refs() {
  [ -f installer/services.yaml ] || return 0
  awk -v svc="$1" '
    /^secrets:/ {insec=1; next}
    insec && /^  [A-Za-z0-9_.\/-]+:/ {
      cur=$0; sub(/^  /,"",cur); sub(/:.*/,"",cur)
      want=(cur==svc); next
    }
    insec && want && /^    [A-Za-z0-9_.-]+:/ {
      if ($0 !~ /\[/) next
      n=$0; sub(/^ +/,"",n); sub(/:.*/,"",n)
      k=$0; sub(/^[^:]*: *\[/,"",k); sub(/\].*/,"",k); gsub(/ /,"",k)
      cnt=split(k, arr, ",")
      for (i=1; i<=cnt; i++) if (arr[i]!="") print n "\t" arr[i]
    }
  ' installer/services.yaml
}

gen_placeholder_secret() { # $1=ns $2=name  stdin: keys (one per line)
  local ns="$1" name="$2"
  {
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "metadata:"
    echo "  name: $name"
    echo "  namespace: $ns"
    echo "type: Opaque"
    echo "stringData:"
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      echo "  $k: CHANGE_ME_$(openssl rand -hex 4)$(openssl rand -hex 4)"
    done
  }
}

# Components installed with `helm` rather than as ArgoCD Applications.
# Format: name|release|namespace|chart|repo-name|repo-url|version|values-file
# Keep versions in step with what the live cluster runs.
HELM_COMPONENTS="
argocd|argocd|argocd|argo-cd|argo|https://argoproj.github.io/argo-helm|10.4.1|apps/infra/argocd/values.yaml
argocd-image-updater|argocd-image-updater|argocd|argocd-image-updater|argo|https://argoproj.github.io/argo-helm|1.2.2|
cert-manager|cert-manager|cert-manager|cert-manager|jetstack|https://charts.jetstack.io|v1.20.2|
longhorn|longhorn|longhorn-system|longhorn|longhorn|https://charts.longhorn.io|1.12.1|
"

# Echo the helm spec line for a component name, or nothing.
helm_spec_for() {
  printf '%s\n' "$HELM_COMPONENTS" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    [ "${line%%|*}" = "$1" ] && { printf '%s\n' "$line"; return; }
  done
}

# Install one helm component. $1 = spec line. Returns 0 on success/skip.
helm_install_component() {
  local spec="$1"
  IFS='|' read -r name release ns chart repo rurl ver vfile <<< "$spec"
  if ! command -v helm >/dev/null 2>&1; then
    warn "$name: helm not installed — cannot bootstrap (install helm, then re-run)"
    warn "         helm repo add $repo $rurl && helm install $release $repo/$chart -n $ns --create-namespace"
    return 1
  fi
  if helm status "$release" -n "$ns" >/dev/null 2>&1; then
    ok "$name: helm release '$release' already installed in ns/$ns — keeping"
    return 0
  fi
  if [ "${DRY_RUN}" = "1" ]; then
    ok "$name: would helm install $repo/$chart $ver -n $ns (release $release)"
    return 0
  fi
  helm repo add "$repo" "$rurl" >/dev/null 2>&1 || true
  helm repo update "$repo" >/dev/null 2>&1 || true
  kubectl create namespace "$ns" >/dev/null 2>&1 || true
  # k3d/kind are containers — they cannot run Longhorn's host-level requirements
  if [ "$name" = "longhorn" ]; then
    if kubectl get nodes -o name 2>/dev/null | grep -q 'k3d\|kind-'; then
      warn "$name: k3d/kind clusters cannot run Longhorn (needs host kernel modules + open-iscsi)"
      warn "         skipping — use a real VM cluster, or install a different StorageClass"
      return 0
    fi
  fi
  local args=(upgrade --install "$release" "$repo/$chart" -n "$ns" --version "$ver" --wait --timeout 15m)
  [ -n "$vfile" ] && [ -f "$vfile" ] && args+=(-f "$vfile")
  local helm_out
  if helm_out=$(helm "${args[@]}" 2>&1); then
    ok "$name: helm release '$release' installed (chart $ver)"
    return 0
  fi
  # --wait can time out while the chart is still converging (slow cluster, or a
  # controller that restarts once mid-install like cert-manager's cainjector).
  # Give the pods a grace period and check reality before declaring failure.
  local notready="" i=0
  while [ "$i" -lt 12 ]; do
    notready=$(kubectl -n "$ns" get pods -l "app.kubernetes.io/instance=$release"                -o jsonpath='{range .items[*]}{.status.phase}{"
"}{end}' 2>/dev/null                | grep -cvE '^(Running|Succeeded)$' || true)
    [ "${notready:-1}" = "0" ] && break
    sleep 10
    i=$((i + 1))
  done
  if [ "${notready:-1}" = "0" ]; then
    warn "$name: helm reported failure but all pods for '$release' are Running — continuing"
    warn "         (chart is installed; re-run 'helm status $release -n $ns' to confirm)"
    return 0
  fi
  warn "$name: helm install failed ($notready pod(s) not Running):"
  printf '%s
' "$helm_out" | tail -5 | sed 's/^/         /'
  warn "         retry manually: helm upgrade --install $release $repo/$chart -n $ns --version $ver${vfile:+ -f $vfile}"
  return 1
}

# ---------- fork detection (fork-first GitOps) ----------
say ""
say "── Your fork"
# ArgoCD reads values from a git repo. If the Applications keep pointing at the
# upstream repo, every local edit below is silently ignored. So we point them at
# YOUR fork first.
ORIGIN=$(git remote get-url origin 2>/dev/null || echo "")
DEFAULT_FORK="$ORIGIN"
FORK="${FORK:-}"
ask FORK "Fork URL for the Applications to read from [$DEFAULT_FORK]: " "$DEFAULT_FORK"

if [ -z "$FORK" ]; then
  die "no git remote found and no fork given — ArgoCD needs a repo URL.
  Push this repo to your own GitHub account, then re-run (or set FORK=...)."
fi

# Normalise to the two forms the manifests use.
case "$FORK" in
  git@*:*/*.git)  FORK_SSH="$FORK";  FORK_HTTPS="https://${FORK#git@}"; FORK_HTTPS="${FORK_HTTPS/:/\/}" ;;
  https://*.git)  FORK_HTTPS="$FORK"; FORK_SSH="git@$(echo "$FORK" | sed -E 's|https://([^/]+)/|\1:|')" ;;
  https://*)      FORK_HTTPS="$FORK.git"; FORK_SSH="git@$(echo "$FORK" | sed -E 's|https://([^/]+)/|\1:|').git" ;;
  *)              die "unrecognised fork URL: $FORK" ;;
esac

if [ "$FORK_HTTPS" = "https://github.com/mysweetpea/homelab-k8s.git" ]; then
  warn "fork still points at the upstream repo — your edits will NOT reach the cluster"
  warn "push to your own account and re-run with FORK=https://github.com/YOU/homelab-k8s.git"
fi
ok "applications will read values from: $FORK_HTTPS"

# Is the fork actually reachable and up to date? (ArgoCD reads the REMOTE, so
# local-only commits are invisible to it.)
if [ "${DRY_RUN}" = "0" ]; then
  if git ls-remote "$FORK_HTTPS" >/dev/null 2>&1; then
    LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    REMOTE_HEAD=$(git ls-remote "$FORK_HTTPS" HEAD 2>/dev/null | awk '{print $1}')
    if [ -n "$LOCAL_HEAD" ] && [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
      warn "your local HEAD ($(echo "$LOCAL_HEAD" | cut -c1-8)) != fork HEAD ($(echo "$REMOTE_HEAD" | cut -c1-8))"
      warn "ArgoCD reads the REMOTE — commit and push after this installer makes its edits"
    else
      ok "fork is reachable and in sync"
    fi
  else
    warn "cannot reach $FORK_HTTPS (private repo? credentials?) — ArgoCD will need access too"
  fi
fi

# ---------- rewrite repo URLs (incl. image-updater write-back) ----------
SRC_REPO="https://github.com/mysweetpea/homelab-k8s.git"
SRC_REPO_SSH="git@github.com:mysweetpea/homelab-k8s.git"
if [ "$FORK_HTTPS" != "$SRC_REPO" ]; then
  n_https=$(grep -rl "$SRC_REPO" apps 2>/dev/null | wc -l | tr -d ' ' || true)
  n_ssh=$(grep -rlF "$SRC_REPO_SSH" apps 2>/dev/null | wc -l | tr -d ' ' || true)
  if [ "${DRY_RUN}" = "0" ]; then
    [ "$n_https" = "0" ] || ( grep -rl "$SRC_REPO" apps | xargs -r sed -i "s|$SRC_REPO|$FORK_HTTPS|g" || true )
    [ "$n_ssh"   = "0" ] || ( grep -rlF "$SRC_REPO_SSH" apps | xargs -r sed -i "s|$SRC_REPO_SSH|$FORK_SSH|g" || true )
  fi
  ok "repo URL rewritten → $FORK_HTTPS ($n_https files) and image-updater → $FORK_SSH ($n_ssh files)"
fi

# ---------- domain + LB options ----------
say ""
say "── Domain and IPs"
say "This repo hardcodes the original domain (${DIM}mysweetpea.cc${RESET}) and MetalLB IPs (192.168.20.x)."
DOMAIN="${DOMAIN:-}"
ask DOMAIN "Your domain (enter = keep mysweetpea.cc): " "mysweetpea.cc"

if [ "$DOMAIN" != "mysweetpea.cc" ]; then
  # Validate before rewriting anything: a stray keystroke used to become the
  # domain and rewrite every file with no way back.
  case "$DOMAIN" in
    *[!a-zA-Z0-9.-]*|.*|*..*|.*) die "'$DOMAIN' is not a valid domain" ;;
    *.*) : ;;
    *) die "'$DOMAIN' is not a valid domain (needs at least one dot)" ;;
  esac
  n_dom=$(grep -rl 'mysweetpea\.cc' apps 2>/dev/null | wc -l | tr -d ' ' || true)
  if [ "${DRY_RUN}" = "0" ]; then
    BK=".msp-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$BK" apps 2>/dev/null || true
    ok "backup written: $BK (restore: tar -xzf $BK)"
    ( grep -rl 'mysweetpea\.cc' apps | xargs -r sed -i "s/mysweetpea\.cc/$DOMAIN/g" || true )
  fi
  ok "domain rewritten → $DOMAIN ($n_dom files)"
else
  ok "keeping mysweetpea.cc"
fi

if grep -rq 'loadBalancerIP: 192\.168\.20\.' apps 2>/dev/null; then
  STRIP_LB="${STRIP_LB:-}"
  ask STRIP_LB "Strip hardcoded loadBalancerIPs so MetalLB auto-assigns? [y/N] " "n"
  case "${STRIP_LB:-n}" in
    y|Y) if [ "${DRY_RUN}" = "0" ]; then
           ( grep -rl 'loadBalancerIP: 192\.168\.20\.' apps | xargs -r sed -i '/loadBalancerIP: 192\.168\.20\./d' || true )
         fi
         ok "loadBalancerIP lines stripped — MetalLB will auto-assign" ;;
    *)   warn "keeping 192.168.20.x IPs — edit values to match your LAN" ;;
  esac
fi

# ---------- selection ----------
say ""
say "${BOLD}What do you want to deploy?${RESET}"
say "  1) core         — ArgoCD, Image Updater, Longhorn, MetalLB, Traefik, netpols, routes"
say "  2) monitoring   — Homepage, Uptime Kuma, Grafana+Loki+Promtail, Netdata"
say "  3) media        — Jellyfin, Decypharr, Radarr/Sonarr/Bazarr/Prowlarr, qBittorrent, AIOStreams, Zilean"
say "  4) productivity — Vaultwarden, Nextcloud, Immich(+PG), AFFiNE(+Redis), Postgres"
say "  5) comms        — Matrix (Synapse, MAS, Element, RTC)"
say "  6) identity     — Authentik + outposts, Cloudflare Tunnel"
say "  7) ai           — Ollama, Open WebUI, Hindsight, Docling, Firecrawl"
say "  8) everything"
say "  9) individual services"
say "  ${DIM}bundle names also work: core,monitoring,media,productivity,comms,identity,ai${RESET}"

# Bundle expansion. Reads installer/services.yaml. The item lines are indented
# 4 spaces under a 2-space bundle key, so the item match must be /^    - /.
expand() {
  awk -v b="  $1:" '
    /^bundles:/ {inb=1; next}
    inb && /^[A-Za-z]/ && !/^bundles:/ {inb=0}
    inb && $0==b {f=1; next}
    inb && f && /^  [A-Za-z0-9_-]+:/ {f=0; next}
    inb && f && /^    - / {line=$0; sub(/^    - /,"",line); sub(/[[:space:]]*#.*/,"",line); if(line!="") print line}
  ' installer/services.yaml
}

bundle_name_for() {
  case "$1" in
    1) echo core ;; 2) echo monitoring ;; 3) echo media ;; 4) echo productivity ;;
    5) echo comms ;; 6) echo identity ;; 7) echo ai ;; *) echo "" ;;
  esac
}

CHOICES="${BUNDLES:-}"
ask CHOICES "Choice(s), comma-separated (deploy core first on a fresh cluster): " "core"

SELECTED=()
for c in ${CHOICES//,/ }; do
  name="$(bundle_name_for "$c")"; [ -n "$name" ] || name="$c"
  if expand "$name" | grep -q .; then
    while IFS= read -r item; do [ -n "$item" ] && SELECTED+=("$item"); done < <(expand "$name")
    ok "bundle '$name' → $(expand "$name" | grep -c . || true) app(s)"
  elif [ "$c" = "8" ]; then
    while IFS= read -r item; do [ -n "$item" ] && SELECTED+=("$item"); done \
      < <(find apps -mindepth 2 -maxdepth 2 -type d -printf '%P\n' | sort -u)
    ok "everything → $(find apps -mindepth 2 -maxdepth 2 -type d | wc -l | tr -d ' ') app(s)"
  elif [ "$c" = "9" ]; then
    if [ -z "${SERVICES:-}" ]; then
      read -r -p "Service names (space-separated; zone/name for ingress-routes): " SERVICES || true
    fi
    read -ra _sel <<< "${SERVICES:-}"
    [ ${#_sel[@]} -gt 0 ] || die "no services given for option 9"
    SELECTED+=( "${_sel[@]}" )
  else
    warn "unknown choice: $c (skipped)"
  fi
done
[ ${#SELECTED[@]} -gt 0 ] || die "nothing selected"
mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | awk '!seen[$0]++')

say ""
say "Deploying ${#SELECTED[@]} app(s): ${SELECTED[*]}"

# ---------- resolve dirs (bail early on anything unresolvable) ----------
declare -a PLAN=()
for svc in "${SELECTED[@]}"; do
  dir=$(app_dir "$svc") || exit 1
  if [ -z "$dir" ]; then warn "$svc: no app directory found — skipped"; continue; fi
  ns=$(app_ns "$dir")
  # helm-managed components have no application.yaml — take their ns from the spec
  if [ -z "$ns" ]; then
    HS="$(helm_spec_for "$svc" || true)"
    if [ -n "$HS" ]; then IFS='|' read -r _ _ hns _ _ _ _ _ <<< "$HS"; ns="$hns"; fi
  fi
  PLAN+=("$svc|$dir|$ns")
done
[ ${#PLAN[@]} -gt 0 ] || die "nothing deployable after resolving names"

# ---------- deploy order ----------
# Applications cannot be applied until ArgoCD serves the Application CRD, and
# that CRD appears when the 'argocd' helm release installs — which happens
# INSIDE this loop. Walking the bundle in listed order therefore applied
# Applications before ArgoCD existed: 'core' lists metallb first but argocd
# fifth, so metallb was skipped and a fresh install came up with no
# LoadBalancer IPs (MetalLB is what gives traefik its EXTERNAL-IP).
# Order: argocd -> other helm/k3s components -> ArgoCD Applications.
declare -a PLAN_INFRA=() PLAN_APPS=()
for _e in "${PLAN[@]}"; do
  _svc="${_e%%|*}"
  if [ "$_svc" = "traefik-k3s" ] || [ -n "$(helm_spec_for "$_svc" || true)" ]; then
    PLAN_INFRA+=("$_e")
  else
    PLAN_APPS+=("$_e")
  fi
done
declare -a PLAN_ORDERED=()
for _e in "${PLAN_INFRA[@]}"; do
  [ "${_e%%|*}" = "argocd" ] && PLAN_ORDERED+=("$_e")
done
for _e in "${PLAN_INFRA[@]}"; do
  [ "${_e%%|*}" != "argocd" ] && PLAN_ORDERED+=("$_e")
done
for _e in "${PLAN_APPS[@]}"; do PLAN_ORDERED+=("$_e"); done
PLAN=("${PLAN_ORDERED[@]}")

# ---------- namespaces (Applications use CreateNamespace=false) ----------
say ""
say "── Namespaces"
mapfile -t NS_LIST < <(printf '%s\n' "${PLAN[@]}" | awk -F'|' '{print $3}' | grep -v '^$' | sort -u)
# 'argocd' must exist before any Application lands in it.
NS_LIST+=(argocd)
mapfile -t NS_LIST < <(printf '%s\n' "${NS_LIST[@]}" | awk '!seen[$0]++')
for ns in "${NS_LIST[@]}"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    ok "namespace $ns exists"
  else
    if [ "${DRY_RUN}" = "0" ]; then
      kubectl create namespace "$ns" >/dev/null && ok "namespace $ns created"
    else
      ok "namespace $ns would be created"
    fi
  fi
done

# ---------- ArgoCD presence ----------
# Everything except the helm/k3s core components arrives as an ArgoCD
# Application. Warn once if this selection needs ArgoCD but neither has it nor
# installs it — warning during a 'core' run (which DOES install argocd) was
# simply wrong. The CRD wait now happens right after that install, in the loop.
NEEDS_ARGOCD=0
for entry in "${PLAN[@]}"; do
  IFS='|' read -r _ d _ <<< "$entry"
  if [ -f "$d/application.yaml" ]; then NEEDS_ARGOCD=1; break; fi
done
INSTALLS_ARGOCD=0
for _e in "${SELECTED[@]}"; do
  if [ "$_e" = "argocd" ]; then INSTALLS_ARGOCD=1; break; fi
done
if [ "$NEEDS_ARGOCD" = "1" ] && [ "$INSTALLS_ARGOCD" = "0" ] \
   && ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  say ""
  warn "ArgoCD is not installed on this cluster."
  warn "Most of this selection is delivered as ArgoCD Applications, so those will"
  warn "be skipped. Deploy the 'core' bundle first (it installs ArgoCD), then re-run."
fi

# ---------- per-app deploy ----------
say ""
say "── Deploying"
TODO_SECRETS=()
SKIPPED=()
APPLIED=()
for entry in "${PLAN[@]}"; do
  IFS='|' read -r svc dir ns <<< "$entry"
  say ""
  say "── $svc  ${DIM}($dir → ns/${ns:-none})${RESET}"

  # 0a) k3s-native manifests (HelmChart/HelmChartConfig CRs the k3s supervisor
  #     reconciles itself — traefik on k3s). Apply the dir's yaml, don't helm-install.
  if [ "$svc" = "traefik-k3s" ]; then
    _any=0
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      _any=1
      if [ "${DRY_RUN}" = "1" ]; then ok "$(basename "$f") would be applied (k3s HelmChart)"; continue; fi
      if kubectl apply -f "$f" >/dev/null 2>&1; then ok "$(basename "$f") applied (k3s HelmChart)"
      else warn "$(basename "$f") apply failed"; SKIPPED+=("$svc:$(basename "$f")"); fi
    done
    [ "$_any" = "1" ] || warn "$svc: no manifests found"
    continue
  fi

  # 0b) helm-managed component? (argocd, cert-manager, longhorn, ...)
  HELM_SPEC="$(helm_spec_for "$svc" || true)"
  if [ -n "$HELM_SPEC" ]; then
    if helm_install_component "$HELM_SPEC"; then
      APPLIED+=("$svc")
      # ArgoCD's CRDs are served only once this release settles. Applications
      # applied before then fail with 'no matches for kind "Application"', so
      # wait HERE — immediately after the install that creates them. Waiting
      # before the loop could never succeed: the CRD does not exist yet.
      if [ "$svc" = "argocd" ] && [ "${DRY_RUN}" = "0" ] && command -v kubectl >/dev/null 2>&1; then
        say ""
        say "── Waiting for ArgoCD CRDs"
        for _i in $(seq 1 60); do
          if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
            ok "applications.argoproj.io is available"; break
          fi
          sleep 5
          if [ "$_i" = "60" ]; then warn "ArgoCD CRDs not ready after 5m — Applications may fail to apply"; fi
        done
      fi
    else SKIPPED+=("$svc (helm install failed)"); fi
    continue
  fi

  # 1) required secrets: inline refs + catalog refs, merged
  if [ -n "$ns" ]; then
    mapfile -t REQS < <( { inline_refs "$dir/values.yaml"; catalog_refs "$svc"; catalog_refs "${dir##*/}"; } | sort -u)
    if [ ${#REQS[@]} -gt 0 ] && [ -n "${REQS[0]}" ]; then
      declare -A SEEN=()
      for line in "${REQS[@]}"; do
        sname=${line%%$'\t'*}; key=${line##*$'\t'}
        [ -n "$sname" ] && [ -n "$key" ] || continue
        SEEN[$sname]="${SEEN[$sname]:-} $key"
      done
      for sname in "${!SEEN[@]}"; do
        if kubectl -n "$ns" get secret "$sname" >/dev/null 2>&1; then
          ok "secret $ns/$sname already exists — keeping"
          continue
        fi
        if [ "${DRY_RUN}" = "1" ]; then
          ok "secret $ns/$sname would be generated + sealed ($(echo ${SEEN[$sname]} | wc -w | tr -d ' ') key(s))"
          TODO_SECRETS+=("$ns/$sname:${SEEN[$sname]}")
          continue
        fi
        gen_placeholder_secret "$ns" "$sname" <<< "${SEEN[$sname]// /$'\n'}" > /tmp/msp-secret.yaml
        if kubeseal "${KUBESEAL_ARGS[@]}" --format yaml < /tmp/msp-secret.yaml \
          | kubectl apply -f - >/dev/null; then
          ok "secret $ns/$sname sealed + applied (placeholder values)"
          TODO_SECRETS+=("$ns/$sname:${SEEN[$sname]}")
        else
          warn "could not seal $sname — create manually: kubectl -n $ns create secret generic $sname ..."
        fi
        rm -f /tmp/msp-secret.yaml
      done
    fi
  else
    warn "$svc: no destination namespace in application.yaml — skipped"
    SKIPPED+=("$svc (no namespace)")
    continue
  fi

  # 2) apply the ArgoCD application (some dirs are helm/manifest installs with
  #    no Application — that is legitimate, not an error)
  if [ ! -f "$dir/application.yaml" ]; then
    warn "$svc: no application.yaml — not an ArgoCD app (install manually; see $dir)"
    SKIPPED+=("$svc (no application.yaml)")
    continue
  fi
  if [ "${DRY_RUN}" = "1" ]; then
    ok "application would be applied"
  elif apply_out=$(kubectl apply -f "$dir/application.yaml" 2>&1); then
    ok "application applied"
    APPLIED+=("$svc")
  else
    # The commonest cause by far on a new cluster is that ArgoCD isn't installed
    # yet — say so plainly instead of leaving a bare "apply failed".
    if printf '%s' "$apply_out" | grep -q 'no matches for kind "Application"'; then
      warn "$svc: ArgoCD is not installed yet (CRD applications.argoproj.io missing)"
      warn "         deploy the 'core' bundle first, then re-run this selection"
      SKIPPED+=("$svc (ArgoCD not installed)")
    else
      warn "$svc: application apply failed:"
      printf '%s
' "$apply_out" | tail -3 | sed 's/^/         /'
      SKIPPED+=("$svc (apply failed)")
    fi
  fi
done

# ---------- summary ----------
say ""
say "${BOLD}Done.${RESET}"

# Only claim ArgoCD is syncing when ArgoCD actually exists AND something was
# actually handed to it. Otherwise say what is true instead.
if [ "${DRY_RUN}" = "0" ]; then
  if kubectl get crd applications.argoproj.io >/dev/null 2>&1 && [ ${#APPLIED[@]} -gt 0 ]; then
    say "ArgoCD is now syncing your selection."
    say "Watch: ${DIM}kubectl -n argocd get applications -w${RESET}"
  elif ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    warn "ArgoCD is not installed on this cluster, so nothing will sync from it yet."
    say "  ${DIM}Deploy the 'core' bundle first (it installs ArgoCD), then re-run this selection.${RESET}"
  else
    say "Nothing was handed to ArgoCD — see the list below."
  fi
  if [ "$FORK_HTTPS" != "$SRC_REPO" ] && [ ${#APPLIED[@]} -gt 0 ]; then
    say ""
    warn "IMPORTANT — commit and push so ArgoCD sees the rewritten values:"
    say "    git add -A && git commit -m 'install: target my domain + fork' && git push"
    say "  ${DIM}ArgoCD reads values from $FORK_HTTPS — local-only commits are invisible to it.${RESET}"
  fi
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
  say ""
  warn "Not deployed (${#SKIPPED[@]}):"
  for t in "${SKIPPED[@]}"; do say "  • $t"; done
fi
if [ ${#TODO_SECRETS[@]} -gt 0 ]; then
  say ""
  warn "These secrets carry placeholder values — replace before real use:"
  for t in "${TODO_SECRETS[@]}"; do say "  • $t"; done
fi

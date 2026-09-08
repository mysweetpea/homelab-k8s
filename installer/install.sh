#!/usr/bin/env bash
# MySweetPea homelab — self-hosting installer.
#
# Deploys any subset of the services from this repo to YOUR cluster:
#   - derives each app's required secrets from its values.yaml (inline
#     secretKeyRef pairs, any indentation) plus installer/services.yaml
#     (chart-level/envFrom secrets the parser cannot see)
#   - generates placeholder secrets with random values, seals them with
#     kubeseal against YOUR cluster, applies them
#   - optionally rewires mysweetpea.cc -> your domain and strips hardcoded
#     MetalLB IPs
#   - applies only the selected ArgoCD applications
#
# Requirements: bash, kubectl (connected), kubeseal, sealed-secrets controller.

set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
say()  { printf "%s\n" "${BOLD}$*${RESET}"; }
ok()   { printf "%s✓%s %s\n" "${GREEN}" "${RESET}" "$*"; }
warn() { printf "%s!%s %s\n" "${YELLOW}" "${RESET}" "$*"; }
die()  { printf "%s✗%s %s\n" "${RED}" "${RESET}" "$*"; exit 1; }

# ---------- preflight ----------
command -v kubectl >/dev/null || die "kubectl not found in PATH"
command -v kubeseal >/dev/null || die "kubeseal not found (github.com/bitnami-labs/sealed-secrets)"
command -v openssl >/dev/null || die "openssl not found"
kubectl get --raw /readyz >/dev/null 2>&1 || die "kubectl cannot reach the cluster"

SS_NS=$(kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i sealed | head -1 | awk '{print $1}')
[ -n "$SS_NS" ] || die "sealed-secrets controller not found — install it first:
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
  helm install -n kube-system sealed-secrets sealed-secrets/sealed-secrets"
ok "sealed-secrets controller: $SS_NS"
SVC_NAME=$(kubectl -n "$SS_NS" get svc -o name | head -1 | cut -d/ -f2)
KUBESEAL_ARGS=(--controller-namespace "$SS_NS" --controller-name "$SVC_NAME")

# ---------- helpers ----------
app_dir() { find apps -maxdepth 3 -type d -name "$1" | head -1; }

app_ns() {  # namespace from application.yaml destination (fallback: env or values)
  local f; f="$(app_dir "$1")/application.yaml"
  awk '/destination:/{f=1} f&&/namespace:/{print $2; exit}' "$f"
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
    /^secrets:/ {ins=1; next}
    ins && /^  [a-z0-9-]+:/ {
      cur=$0; sub(/.*^  /,"",cur); sub(/:.*/,"",cur)
      ins=(cur==svc); next
    }
    ins && /^    [A-Za-z0-9_.-]+:/ {
      n=$0; sub(/^ +/,"",n); sub(/:.*/,"",n)
      k=$0; sub(/^[^:]*: *\[/,"",k); sub(/\].*/,"",k); gsub(/ /,"",k)
      gsub(/,/, "\n", k)
      print n "\t" k
    }
  ' installer/services.yaml | while IFS=$'\t' read -r n keys; do
    while IFS= read -r k; do [ -n "$k" ] && echo -e "$n\t$k"; done <<< "$keys"
  done
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
      echo "  $k: CHANGE_ME_$(openssl rand -hex 8)"
    done
  }
}

# ---------- domain + LB options ----------
DOMAIN="mysweetpea.cc"
say ""
say "This repo hardcodes the original domain (${DIM}mysweetpea.cc${RESET}) and"
say "MetalLB IPs (192.168.20.x)."
read -r -p "Your domain (enter = keep mysweetpea.cc): " ans
[ -n "$ans" ] && DOMAIN="$ans"
if [ "$DOMAIN" != "mysweetpea.cc" ]; then
  say "Rewiring domain to ${BOLD}$DOMAIN${RESET} in apps/ ..."
  grep -rl 'mysweetpea\.cc' apps | xargs sed -i "s/mysweetpea\.cc/$DOMAIN/g"
  ok "domain rewritten (your local clone only — do not push upstream)"
fi
if grep -rq 'loadBalancerIP: 192\.168\.20\.' apps; then
  read -r -p "Strip hardcoded loadBalancerIPs so MetalLB auto-assigns? [Y/n] " ans
  case "$ans" in
    n|N) warn "keeping 192.168.20.x IPs — edit values to match your LAN" ;;
    *)   grep -rl 'loadBalancerIP: 192\.168\.20\.' apps | xargs sed -i '/loadBalancerIP: 192\.168\.20\./d'
         ok "loadBalancerIP lines stripped" ;;
  esac
fi

# ---------- selection ----------
say ""
say "${BOLD}What do you want to deploy?${RESET}"
say "  1) core        — ArgoCD, Longhorn, MetalLB, Traefik, netpols, routes"
say "  2) monitoring  — Homepage, Uptime Kuma, Grafana+Loki, Netdata"
say "  3) media       — Jellyfin, Decypharr, arr stack, AIOStreams, Zilean"
say "  4) productivity — Vaultwarden, Nextcloud, Immich, AFFiNE, Postgres"
say "  5) comms       — Matrix (Synapse, MAS, Element, RTC)"
say "  6) identity    — Authentik + outposts + Cloudflare Tunnel"
say "  7) ai          — Ollama, Open WebUI, Hindsight, Docling, Firecrawl"
say "  8) everything"
say "  9) individual services"
read -r -p "Choice(s), comma-separated (deploy core first on a fresh cluster): " choices

expand() { awk -v b="  $1:" '$0==b{f=1;next} /^  [a-z]/&&!/^  - /{f=0} f&&/^- /{print $2}' installer/services.yaml; }

SELECTED=()
for c in ${choices//,/ }; do
  case "$c" in
    1) SELECTED+=( $(expand core) ) ;;
    2) SELECTED+=( $(expand monitoring) ) ;;
    3) SELECTED+=( $(expand media) ) ;;
    4) SELECTED+=( $(expand productivity) ) ;;
    5) SELECTED+=( $(expand comms) ) ;;
    6) SELECTED+=( $(expand identity) ) ;;
    7) SELECTED+=( $(expand ai) ) ;;
    8) SELECTED=( $(find apps -mindepth 2 -maxdepth 2 -type d ! -name ingress-routes -printf '%f\n' | sort -u) ) ;;
    9) read -r -p "Service names (space-separated, as under apps/<zone>/): " sel
       read -ra SELECTED <<< "$sel" ;;
    *) warn "unknown choice: $c (skipped)" ;;
  esac
done
[ ${#SELECTED[@]} -gt 0 ] || die "nothing selected"
mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | awk '!seen[$0]++')

say ""
say "Deploying ${#SELECTED[@]} app(s): ${SELECTED[*]}"

# ---------- per-app deploy ----------
TODO_SECRETS=()
for svc in "${SELECTED[@]}"; do
  dir=$(app_dir "$svc")
  [ -n "$dir" ] || { warn "$svc: no app directory found — skipped"; continue; }
  ns=$(app_ns "$svc")
  say ""
  say "── $svc  ${DIM}($dir → ns/$ns)${RESET}"

  # 1) required secrets: inline refs + catalog refs, merged
  mapfile -t REQS < <( { inline_refs "$dir/values.yaml"; catalog_refs "$svc"; } | sort -u)
  if [ ${#REQS[@]} -gt 0 ] && [ -n "${REQS[0]}" ]; then
    declare -A SEEN=()
    for line in "${REQS[@]}"; do
      sname=${line%%$'\t'*}; key=${line##*$'\t'}
      SEEN[$sname]="${SEEN[$sname]:-} $key"
    done
    for sname in "${!SEEN[@]}"; do
      if kubectl -n "$ns" get secret "$sname" >/dev/null 2>&1; then
        ok "secret $ns/$sname already exists — keeping"
        continue
      fi
      gen_placeholder_secret "$ns" "$sname" <<< "${SEEN[$sname]}" > /tmp/msp-secret.yaml
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

  # 2) apply the ArgoCD application
  if kubectl apply -f "$dir/application.yaml" >/dev/null 2>&1; then
    ok "application applied"
  else
    warn "application apply failed — check $dir/application.yaml"
  fi
done

say ""
say "${BOLD}Done. ArgoCD is now syncing your selection.${RESET}"
say "Watch: ${DIM}kubectl -n argocd get applications -w${RESET}"
if [ ${#TODO_SECRETS[@]} -gt 0 ]; then
  say ""
  warn "These secrets carry placeholder values — replace before real use:"
  for t in "${TODO_SECRETS[@]}"; do say "  • $t"; done
fi

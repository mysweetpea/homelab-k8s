#!/bin/bash
# appliance.sh — no-GitHub deployment engine (Phase 3).
#
# Renders each selected app's ArgoCD Application so it needs NO user repo:
#   - $values ref (second source) -> pointed at the UPSTREAM repo, so
#     valueFiles still resolve without a fork
#   - inline helm.valuesObject overrides layered on top (exposure/SSO/
#     domain choices) — top precedence in ArgoCD
#   - image-updater write-back flipped git -> argocd (in-cluster CR patch)
#   - sealed-secrets controller cert exported for disaster recovery
#
# Public API:
#   appliance_render <app_dir> <out_file>   renders one Application
#   appliance_backup_ss_cert <out_file>     export kubeseal cert
#
# Env: MSP_UPSTREAM_REPO (default https://github.com/mysweetpea/homelab-k8s.git)
#      MSP_DOMAIN_OVERRIDE, MSP_SSO (yes/no), MSP_EXPOSURE (lan|domain)
#
# bash 3.2-safe. No yaml libs: transforms are line-based, verified after.

APPLIANCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$APPLIANCE_DIR/common.sh"

APPLIANCE_UPSTREAM="${MSP_UPSTREAM_REPO:-https://github.com/mysweetpea/homelab-k8s.git}"
APPLIANCE_UPSTREAM_SSH="${MSP_UPSTREAM_REPO_SSH:-git@github.com:mysweetpea/homelab-k8s.git}"

# _app_values_path <app_dir> — apps/<ns>/<name>/values.yaml path as it appears
# in $values valueFiles entries
_app_values_path() {
  printf 'apps/%s\n' "${1#*apps/}"
}

# _flip_writeback <file> — rewrite image-updater annotations in-place:
#   write-back-method: git -> argocd, drop git.repository lines.
#   (write-back-target helmvalues:<path> stays — argocd method patches the
#    Application's helm parameters in-cluster; no git needed.)
_flip_writeback() {
  # shellcheck disable=SC2016
  sed -i \
    -e 's|argocd-image-updater.argoproj.io/write-back-method: git|argocd-image-updater.argoproj.io/write-back-method: argocd|' \
    -e '/argocd-image-updater.argoproj.io\/git.repository:/d' \
    -e '/argocd-image-updater.argoproj.io\/git.branch:/d' \
    "$1"
}

# _repoint_values_ref <file> — set the second source's repoURL (the $values
# ref) to the upstream repo and its SSH twin in image-updater annotations.
_repoint_values_ref() {
  local f="$1" ssh_from ssh_to
  ssh_from="${APPLIANCE_UPSTREAM_SSH%%:*}"
  # generic: any github.com git-ref second source -> upstream
  sed -i \
    -e "s|repoURL: https://github.com/[^/]*/homelab-k8s.git|repoURL: $APPLIANCE_UPSTREAM|" \
    "$f"
}

# _inject_overrides <file> <namespace> — append a valuesObject patch to the
# FIRST source's helm block. Implemented as an overlay document: ArgoCD
# multi-source helm parameters carry top precedence, so we add
# helm.parameters entries via a second `sources` entry is NOT possible —
# instead we insert `helm.valuesObject` inline into source[0].
_inject_overrides() {
  local f="$1"
  local domain="${MSP_DOMAIN_OVERRIDE:-}"
  local line=""
  [ -n "$domain" ] && line="global: {domain: $domain}"
  [ -n "$line" ] || return 0
  awk -v newline="$line" '
    /^    helm:/ && !done {
      print
      print "      valuesObject: |-"
      n = split(newline, L, "\n")
      for (i = 1; i <= n; i++) print "        " L[i]
      done = 1
      next
    }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

appliance_render() { # <app_dir> <out_file>
  local dir="$1" out="$2"
  local src="$dir/application.yaml"
  [ -f "$src" ] || { warn "appliance_render: no application.yaml in $dir"; return 1; }
  cp "$src" "$out"
  _repoint_values_ref "$out"
  _flip_writeback "$out"
  _inject_overrides "$out"
  return 0
}

appliance_backup_ss_cert() { # <out_file>
  local out="$1"
  # kubeseal fetches the cert from the controller; --cert re-uses it later
  # to seal secrets offline / after cluster rebuild.
  if command -v kubeseal >/dev/null 2>&1; then
    kubeseal --fetch-cert > "$out" 2>/dev/null && return 0
  fi
  kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o jsonpath='{range .items[*]}{.data.tls\.key}{"\n"}{.data.tls\.crt}{"\n"}{end}' \
    > "$out" 2>/dev/null && return 0
  return 1
}

#!/bin/bash
# wizard.sh — guided homelab installer wizard (Phase 1b).
#
# Walks a non-technical user through: machine check -> use-cases -> app
# review -> exposure -> SSO -> settings home -> review. Emits a source-able
# plan file consumed by later installer phases.
#
# Env:
#   MSP_MODE=guided|expert   (default guided)
#   MSP_PLAN_FILE=<path>     (default ./homelab-plan.env)
#   MSP_UI=plain|fzf|whiptail|ansi  (see lib/ui.sh)

WIZ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$WIZ_DIR/lib/common.sh"
. "$WIZ_DIR/lib/catalog.sh"
. "$WIZ_DIR/lib/ui.sh"

MSP_MODE="${MSP_MODE:-guided}"
MSP_PLAN_FILE="${MSP_PLAN_FILE:-./homelab-plan.env}"

# ---------------------------------------------------------------- helpers
_wiz_ram_total_mb() {
  local mb=""
  if have free; then
    mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
  fi
  if [ -z "$mb" ] || [ "$mb" = "0" ]; then
    mb=8192
  fi
  printf '%s' "$mb"
}

_wiz_tool_hint() {
  case "$1" in
    kubectl)  printf 'see https://kubernetes.io/docs/tasks/tools/#kubectl' ;;
    helm)     printf 'curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash' ;;
    kubeseal) printf 'https://github.com/bitnami-labs/sealed-secrets/releases' ;;
    git)      printf 'apt install git  /  brew install git' ;;
    gh)       printf 'winget install GitHub.cli  /  brew install gh  /  apt install gh' ;;
    *)        printf '' ;;
  esac
}

_wiz_machine_check() {
  log "Checking your machine (nothing is installed yet)"
  local t missing=0
  for t in kubectl helm kubeseal git gh; do
    if have "$t"; then
      printf '  [OK]      %s\n' "$t"
    else
      printf '  [missing] %s  (%s)\n' "$t" "$(_wiz_tool_hint "$t")"
      missing=$((missing+1))
    fi
  done
  local ram; ram=$(_wiz_ram_total_mb)
  printf '  System RAM: %d GB\n' $((ram/1024))
  info "Missing tools are fine for now — the installer will flag what it needs."
}

_wiz_index_of() {  # arr-name needle count -> echo index or -1
  local arr="$1" needle="$2" count="$3" i
  for ((i=0; i<count; i++)); do
    eval "local v=\${$arr[$i]}"
    [ "$v" = "$needle" ] && { printf '%s' "$i"; return 0; }
  done
  printf '%s' "-1"
}

_wiz_app_is_default_for() {  # app_index usecase_id -> rc 0/1
  local i="$1" uc="$2"
  local ucs="${APPS_USECASES[$i]}"
  local def="${APPS_DEFAULT[$i]}"
  [ "$def" = "true" ] || return 1
  printf '%s\n' "$ucs" | tr ',' '\n' | grep -qx "$uc"
}

# Build rowspecs for S3. $1.. = selected app names (space-separated string).
_wiz_s3_rows() {
  local selected_str="$1"
  local rows=() i sel app
  local selarr=()
  for sel in $selected_str; do selarr+=("$sel"); done

  # selected first
  for ((i=0; i<APPS_N; i++)); do
    for sel in "${selarr[@]}"; do
      if [ "${APPS_NAME[$i]}" = "$sel" ]; then
        rows+=("${APPS_NAME[$i]}|x|${APPS_NAME[$i]} - ${APPS_DESC[$i]}")
      fi
    done
  done
  # then the rest, grouped by category
  local last_cat=""
  for ((i=0; i<APPS_N; i++)); do
    app="${APPS_NAME[$i]}"
    local is_sel=0
    for sel in "${selarr[@]}"; do
      [ "$app" = "$sel" ] && { is_sel=1; break; }
    done
    [ "$is_sel" = 1 ] && continue
    if [ "${APPS_CATEGORY[$i]}" != "$last_cat" ]; then
      last_cat="${APPS_CATEGORY[$i]}"
      rows+=("# ${last_cat}|x|${last_cat^}")
    fi
    local st=" "
    rows+=("$app|$st|$app - ${APPS_DESC[$i]}")
  done
  printf '%s\n' "${rows[@]}"
}

# plan_order_apps chosen...  -> deps-first then chosen, deduped, catalog order
plan_order_apps() {
  local chosen=("$@") i app
  # authentik injection happens here so all callers share it
  if [ "${MSP_SSO:-no}" = "yes" ]; then
    local has=0
    for app in "${chosen[@]}"; do [ "$app" = "authentik" ] && has=1; done
    [ "$has" = 0 ] && chosen+=("authentik")
  fi
  local out="" dep
  # deps first: union of closures, but preserve catalog order
  local deps_all=()
  for app in "${chosen[@]}"; do
    while IFS= read -r dep; do
      [ -n "$dep" ] && deps_all+=("$dep")
    done <<EOF
$(catalog_dep_closure "$app" 2>/dev/null)
EOF
  done
  for ((i=0; i<APPS_N; i++)); do
    for dep in "${deps_all[@]}"; do
      if [ "${APPS_NAME[$i]}" = "$dep" ]; then
        case "|$out|" in *"|$dep|"*) ;; *) out="$out $dep" ;; esac
      fi
    done
  done
  # chosen after
  for ((i=0; i<APPS_N; i++)); do
    for app in "${chosen[@]}"; do
      if [ "${APPS_NAME[$i]}" = "$app" ]; then
        case "|$out|" in *"|$app|"*) ;; *) out="$out $app" ;; esac
      fi
    done
  done
  printf '%s' "${out# }"
}

_wiz_review() {  # $1=apps_string -> rc 0 = confirmed
  local apps_str="$1"
  local chosen=($apps_str)
  local n=${#chosen[@]}
  local ram_sum=0 i idx
  for app in "${chosen[@]}"; do
    idx=$(_wiz_index_of APPS_NAME "$app" "$APPS_N")
    if [ "$idx" -ge 0 ]; then
      ram_sum=$((ram_sum + ${APPS_RAM[$idx]}))
    fi
  done
  local ram_gb=$((ram_sum / 1024))
  local ram_frac=$(((ram_sum % 1024) * 10 / 1024))
  local sysram=$(_wiz_ram_total_mb)

  printf '\n'
  printf '+--------------------------------------------------------------\n'
  printf '|  Apps (%d):      %s\n' "$n" "$apps_str"
  printf '|  Estimated RAM:  ~%d.%d GB of your %d GB\n' "$ram_gb" "$ram_frac" $((sysram/1024))
  if [ "$MSP_EXPOSURE" = "domain" ]; then
    printf '|  Exposure:       https://%s\n' "$MSP_DOMAIN"
  else
    printf '|  Exposure:       LAN only\n'
  fi
  if [ "$MSP_SSO" = "yes" ]; then
    printf '|  Single sign-on: Yes (Authentik)\n'
  else
    printf '|  Single sign-on: No\n'
  fi
  if [ "$MSP_METHOD" = "github" ]; then
    printf '|  Settings home:  GitHub fork\n'
  else
    printf '|  Settings home:  This machine\n'
  fi
  printf '+--------------------------------------------------------------\n'
  if [ $((ram_sum * 10)) -gt $((sysram * 7)) ]; then
    warn "Selected apps may need more RAM than your machine comfortably has."
  fi
  confirm "Looks good?" && return 0 || return 1
}

_wiz_write_plan() {  # $1=apps_string
  local apps_str="$1"
  local chosen=($apps_str)
  local ram_sum=0 idx
  for app in "${chosen[@]}"; do
    idx=$(_wiz_index_of APPS_NAME "$app" "$APPS_N")
    [ "$idx" -ge 0 ] && ram_sum=$((ram_sum + ${APPS_RAM[$idx]}))
  done
  local secrets="guided"
  [ "$MSP_MODE" = "expert" ] && secrets="expert"
  {
    printf '# homelab installer plan (generated)\n'
    printf 'MSP_METHOD=%s\n' "$MSP_METHOD"
    printf 'MSP_EXPOSURE=%s\n' "$MSP_EXPOSURE"
    printf 'MSP_DOMAIN=%s\n' "${MSP_DOMAIN:-}"
    printf 'MSP_SSO=%s\n' "$MSP_SSO"
    printf 'MSP_SECRETS=%s\n' "$secrets"
    printf 'MSP_MODE=%s\n' "$MSP_MODE"
    printf 'MSP_APPS="%s"\n' "$apps_str"
    printf 'MSP_RAM_TOTAL_MB=%d\n' "$ram_sum"
  } > "$MSP_PLAN_FILE"
  log "Plan written to $MSP_PLAN_FILE"
  printf 'What next:\n'
  printf '  1. Review the list above.\n'
  printf '  2. Keep this file safe.\n'
  printf '  3. Run the installer next.\n'
}

# ---------------------------------------------------------------- steps
_s2_usecases() {  # -> echoes space-separated chosen use-cases; rc1 = cancel
  local rows=() i label
  for ((i=0; i<UC_N; i++)); do
    rows+=("${UC_ID[$i]}| |${UC_LABEL[$i]} - ${UC_DESC[$i]}")
  done
  while :; do
    local out
    out=$(ui_multi_select "What do you want to use your homelab for?" "${rows[@]}") || return 1
    if [ -z "$out" ]; then
      warn "Pick at least one use-case (or press q to quit)."
      continue
    fi
    printf '%s' "$out" | tr '\n' ' ' | sed 's/ *$//'
    printf 'DBG_S2_SENT=[%s]\n' "$out" >&2
    return 0
  done
}

_s3_apps() {  # $1=usecases_str -> echoes space-separated selected apps; rc1=cancel; rc2=empty-confirm
  local ucs="$1" sel="" uc
  # pre-selection: defaults for chosen use-cases
  local i
  for ((i=0; i<APPS_N; i++)); do
    for uc in $ucs; do
      if _wiz_app_is_default_for "$i" "$uc"; then
        sel="$sel ${APPS_NAME[$i]}"
        break
      fi
    done
  done
  sel="${sel# }"

  while :; do
    local rows=()
    while IFS= read -r line; do
      [ -n "$line" ] && rows+=("$line")
    done < <(_wiz_s3_rows "$sel")
    local out
    out=$(ui_multi_select "Here is what we picked for you - adjust if you like" "${rows[@]}") || return 1
    if [ -z "$out" ]; then
      warn "Nothing selected. Pick at least one app."
      if [ "$MSP_MODE" = "guided" ]; then
        return 2   # signal caller: back to S2
      else
        continue   # expert: re-render same grid
      fi
    fi
    printf '%s' "$out" | tr '\n' ' ' | sed 's/ *$//'
    return 0
  done
}

_s4_exposure() {  # rc1=cancel
  while :; do
    local out
    out=$(ui_single_select "How will you reach your services?" "|" \
      "lan|On my home network only - safest, no internet exposure" \
      "domain|My own domain - reachable from anywhere") || return 1
    MSP_EXPOSURE="$out"
    if [ "$out" = "domain" ]; then
      local d ok=0
      while [ "$ok" = 0 ]; do
        printf 'Type your domain (e.g. home.example.com): ' >&2
        IFS= read -r d || return 1
        case "$d" in
          *.*[a-zA-Z]) ok=1 ;;
          "") : ;;
          *) warn "That does not look like a domain. Try again." ;;
        esac
      done
      MSP_DOMAIN="$d"
    else
      MSP_DOMAIN=""
    fi
    return 0
  done
}

_s5_sso() {  # rc1=cancel
  if confirm "One login for everything (single sign-on)?" ; then
    MSP_SSO="yes"
  else
    MSP_SSO="no"
  fi
  return 0
}

_s6_method() {  # rc1=cancel
  while :; do
    local out
    out=$(ui_single_select "Where should your settings live?" "|" \
      "appliance|On this machine - no GitHub account needed" \
      "github|In my GitHub fork - free remote backup, needs a GitHub account") || return 1
    if [ "$out" = "github" ] && { ! have git || ! have gh; }; then
      warn "The GitHub option needs git and gh installed."
      warn "gh: $(_wiz_tool_hint gh)"
      continue
    fi
    MSP_METHOD="$out"
    return 0
  done
}

# ---------------------------------------------------------------- main
wizard_main() {
  ui_init
  catalog_load "$WIZ_DIR/services.yaml" || die "catalog failed to load"

  printf '============================================================\n'
  printf '   MySweetPea homelab installer — guided setup\n'
  printf '   Pick what you want; we build the plan and install it.\n'
  printf '============================================================\n'
  _wiz_machine_check

  while :; do
    local ucs="" apps_str rc
    if [ "$MSP_MODE" != "expert" ]; then
      # S2 (guided only; expert goes straight to the full grid)
      ucs=$(_s2_usecases) || { warn "Cancelled - nothing was installed."; return 1; }
      # S3
      apps_str=$(_s3_apps "$ucs"); rc=$?
      if [ "$rc" = 1 ]; then warn "Cancelled - nothing was installed."; return 1; fi
      if [ "$rc" = 2 ]; then continue; fi
    else
      # expert: full grid directly; empty confirm re-renders
      apps_str=$(_s3_apps ""); rc=$?
      if [ "$rc" = 1 ]; then warn "Cancelled - nothing was installed."; return 1; fi
      if [ "$rc" = 2 ]; then continue; fi
    fi

    # S4-S6
    _s4_exposure   || { warn "Cancelled - nothing was installed."; return 1; }
    _s5_sso
    _s6_method     || { warn "Cancelled - nothing was installed."; return 1; }

    # order + review
    local ordered
    ordered=$(plan_order_apps $apps_str)
    if _wiz_review "$ordered"; then
      _wiz_write_plan "$ordered"
      return 0
    fi
    warn "No problem - let's adjust."
  done
}

# allow `wizard.sh` direct exec AND sourcing for tests
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  wizard_main
  exit $?
fi

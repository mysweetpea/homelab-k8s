#!/bin/bash
# test-wizard.sh — assertions for installer/wizard.sh (MSP_UI=plain, piped stdin).
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$TEST_DIR/../lib/common.sh"
# shellcheck source=../lib/catalog.sh
. "$TEST_DIR/../lib/catalog.sh"
# shellcheck source=../wizard.sh
. "$TEST_DIR/../wizard.sh"
catalog_load "$TEST_DIR/../services.yaml"

TMP="$TEST_DIR/.oc-tmp"
mkdir -p "$TMP"

PASS=0; FAIL=0
check() {  # name got want
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s (got: %s want: %s)\n' "$1" "$2" "$3"; fi
}
check_contains() {  # name haystack needle
  case "$2" in *"$3"*) PASS=$((PASS+1)); printf 'PASS: %s\n' "$1";;
    *) FAIL=$((FAIL+1)); printf 'FAIL: %s (%s does not contain %s)\n' "$1" "$2" "$3";; esac
}
check_order() {  # name haystack before after
  local h="$2" b="$3" a="$4"
  local bi ai
  bi=$(printf '%s' "$h" | awk -v x="$b" '{for(i=1;i<=NF;i++) if($i==x){print i; exit}}')
  ai=$(printf '%s' "$h" | awk -v x="$a" '{for(i=1;i<=NF;i++) if($i==x){print i; exit}}')
  if [ -n "$bi" ] && [ -n "$ai" ] && [ "$bi" -lt "$ai" ]; then
    PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf 'FAIL: %s (in [%s], %s must come before %s)\n' "$1" "$h" "$b" "$a"
  fi
}
# dynamic menu position helper: find 1-based position of $2 in catalog_use_cases
uc_pos() {
  local n=1 id
  while IFS= read -r id; do
    [ "$id" = "$1" ] && { printf '%s' "$n"; return 0; }
    n=$((n+1))
  done < <(catalog_use_cases)
  printf '%s' "-1"
}

run_wizard() {  # stdin comes from caller; $1=plan path
  MSP_UI=plain MSP_PLAN_FILE="$1" bash -c '
    source "'"$TEST_DIR"'/../wizard.sh"
    wizard_main
  '
}

# ---------------------------------------------------------------- test 1
P="$TMP/plan1.env"; rm -f "$P"
UCN=$(uc_pos passwords)
# S2: toggle passwords, Enter | S3: Enter (accept) | S4: 1 lan | S5: n | S6: 1 appliance | S7: Enter
out=$(printf '%s\n\n\n1\nn\n1\ny\n' "$UCN" | run_wizard "$P" 2>/dev/null); rc=$?
check "t1 wizard exits 0" "$rc" "0"
[ -f "$P" ]; check "t1 plan file exists" "$([ -f "$P" ] && echo yes || echo no)" "yes"
. "$P"
check "t1 method" "$MSP_METHOD" "appliance"
check "t1 exposure" "$MSP_EXPOSURE" "lan"
check "t1 sso" "$MSP_SSO" "no"
check_contains "t1 has vaultwarden" "$MSP_APPS" "vaultwarden"
check_contains "t1 has postgresql dep" "$MSP_APPS" "postgresql"
check_order "t1 dep order" "$MSP_APPS" "postgresql" "vaultwarden"
T1_RAM="$MSP_RAM_TOTAL_MB"; T1_APPS="$MSP_APPS"

# ---------------------------------------------------------------- test 2
P="$TMP/plan2.env"; rm -f "$P"
out=$(printf '%s\n\n\n1\ny\n1\ny\n' "$UCN" | run_wizard "$P" 2>/dev/null); rc=$?
check "t2 wizard exits 0" "$rc" "0"
. "$P"
check "t2 sso yes" "$MSP_SSO" "yes"
check_contains "t2 authentik added" "$MSP_APPS" "authentik"

# ---------------------------------------------------------------- test 3
sum=0
for app in $T1_APPS; do
  i=$(catalog_index "$app")
  sum=$((sum + ${APPS_RAM[$i]}))
done
check "t3 ram math" "$T1_RAM" "$sum"

# ---------------------------------------------------------------- test 4
MSP_SSO=no
ordered=$(plan_order_apps immich affine)
check_contains "t4 has immich-postgresql" "$ordered" "immich-postgresql"
check_contains "t4 has redis-affine-master" "$ordered" "redis-affine-master"
check_order "t4 deps before immich" "$ordered" "immich-postgresql" "immich"
check_order "t4 redis before immich" "$ordered" "redis-affine-master" "immich"
dupes=$(printf '%s' "$ordered" | tr ' ' '\n' | sort | uniq -d | wc -l)
pg=$(printf '%s' "$ordered" | tr ' ' '\n' | grep -cx postgresql)
check "t4 no dupes" "$dupes" "0"
check "t4 postgresql once" "$pg" "1"
MSP_SSO=no

# ---------------------------------------------------------------- test 5
P="$TMP/plan5.env"; rm -f "$P"
FAKE="$TMP/fakebin"; rm -rf "$FAKE"; mkdir -p "$FAKE"
# t5: gh missing everywhere else; wizard must still complete (appliance mode needs no gh)
out=$(printf '%s\n\n\n1\nn\n2\n1\nexample.com\ny\n' "$UCN" | run_wizard "$P" 2>/dev/null); rc=$?
check "t5 completes after gh-missing re-ask" "$rc" "0"
. "$P"
check "t5 method appliance" "$MSP_METHOD" "appliance"

# ---------------------------------------------------------------- test 6
P="$TMP/plan6.env"; rm -f "$P"
# S2: toggle passwords, Enter | S3: n none, Enter(empty confirm) -> S2 again: q
out=$(printf '%s\nn\n\nq\n' "$UCN" | run_wizard "$P" 2>/dev/null); rc=$?
check "t6 cancel exit 1" "$rc" "1"
check "t6 no plan file" "$([ -f "$P" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------- test 7
P="$TMP/plan7.env"; rm -f "$P"
# expert: full grid; toggle two known apps by displayed number (compute),
# confirm, lan, n sso, appliance, Enter review.
# displayed rows: 1) # Category ... use jellyfin & vaultwarden (different cats)
grid_jf=$(printf 'MSP_UI=plain bash -c' "")  # compute numbers by simulating rows
# Recompute displayed numbering: headers count as rows. Build the same list the wizard shows:
rows=()
last_cat=""
for ((i=0; i<APPS_N; i++)); do
  if [ "${APPS_CATEGORY[$i]}" != "$last_cat" ]; then
    last_cat="${APPS_CATEGORY[$i]}"
    rows+=("#")
  fi
  rows+=("${APPS_NAME[$i]}")
done
n_jf=-1; n_vw=-1; nn=1
for r in "${rows[@]}"; do
  [ "$r" = "jellyfin" ] && n_jf=$nn
  [ "$r" = "vaultwarden" ] && n_vw=$nn
  nn=$((nn+1))
done
out=$(printf '%s %s\n\n\n1\nn\n1\ny\n' "$n_jf" "$n_vw" | MSP_MODE=expert run_wizard "$P" 2>/dev/null); rc=$?
check "t7 expert completes" "$rc" "0"
. "$P"
check_contains "t7 jellyfin selected" "$MSP_APPS" "jellyfin"
check_contains "t7 vaultwarden selected" "$MSP_APPS" "vaultwarden"
check "t7 secrets expert" "$MSP_SECRETS" "expert"

# ---------------------------------------------------------------- test 8
P="$TMP/plan8.env"; rm -f "$P"
out=$(printf '%s\n\n\n2\nexample.com\n1\nn\n1\ny\n' "$UCN" | run_wizard "$P" 2>/dev/null); rc=$?
check "t8 completes" "$rc" "0"
. "$P"
check "t8 exposure domain" "$MSP_EXPOSURE" "domain"
check "t8 domain" "$MSP_DOMAIN" "example.com"

# ---------------------------------------------------------------- test 9 hygiene
bash -n "$TEST_DIR/../wizard.sh" 2>/dev/null; check "t9 bash -n wizard" "$?" "0"
if grep -q $'\r' "$TEST_DIR/../wizard.sh"; then check "t9 LF wizard" "CR" "LF"; else check "t9 LF wizard" "LF" "LF"; fi
[ -x "$TEST_DIR/../wizard.sh" ]; check "t9 executable" "$?" "0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

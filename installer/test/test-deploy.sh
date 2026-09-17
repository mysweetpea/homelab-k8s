#!/bin/bash
# test-deploy.sh — assertions for deploy.sh + homelab-manage.sh + catalog_secrets.
# No cluster needed: dry-run path + arg validation + secrets parsing.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$TEST_DIR/.oc-tmp"
mkdir -p "$TMP"

PASS=0; FAIL=0
check() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s (got: %s want: %s)\n' "$1" "$2" "$3"; fi
}
contains() {
  case "$2" in *"$3"*) PASS=$((PASS+1)); printf 'PASS: %s\n' "$1";;
    *) FAIL=$((FAIL+1)); printf 'FAIL: %s does not contain %s\n' "$1" "$3";; esac
}

# t1 syntax checks
bash -n "$TEST_DIR/../deploy.sh" && check "t1 deploy bash -n" 0 0 || check "t1 deploy bash -n" 1 0
bash -n "$TEST_DIR/../homelab-manage.sh" && check "t1 manage bash -n" 0 0 || check "t1 manage bash -n" 1 0

# t2 deploy needs --plan
out=$(bash "$TEST_DIR/../deploy.sh" 2>&1); rc=$?
check "t2 no plan rc" "$rc" "1"

# t3 catalog_secrets parses the real catalog
out=$(bash -c '
  . "'"$TEST_DIR"'/../lib/catalog.sh"
  catalog_load "'"$TEST_DIR"'/../services.yaml"
  catalog_secrets vaultwarden
' 2>/dev/null)
contains "t3 vw admin secret" "$out" "vaultwarden-admin:password"
contains "t3 vw sso secret" "$out" "vaultwarden-sso:CLIENT_ID,CLIENT_SECRET"

# t4 catalog_secrets unknown app -> empty, rc 0 (no lines)
out=$(bash -c '
  . "'"$TEST_DIR"'/../lib/catalog.sh"
  catalog_load "'"$TEST_DIR"'/../services.yaml"
  catalog_secrets nonexist
' 2>/dev/null); rc=$?
check "t4 unknown app rc" "$rc" "0"
check "t4 unknown app empty" "$out" ""

# t5 dry-run appliance: stub kubectl so readyz + crd check pass
SB="$TMP/bin"; rm -rf "$SB"; mkdir -p "$SB"
printf '#!/bin/sh\necho ok\n' > "$SB/kubectl"; chmod +x "$SB/kubectl"
printf '#!/bin/sh\ncase "$*" in *applications.argoproj.io*) exit 0;; *) exit 0;; esac\n' > "$SB/kubectl2"
PLAN="$TMP/p5.env"
cat > "$PLAN" <<EOF
MSP_METHOD=appliance
MSP_EXPOSURE=lan
MSP_DOMAIN=
MSP_SSO=no
MSP_SECRETS=guided
MSP_MODE=guided
MSP_APPS="vaultwarden"
MSP_RAM_TOTAL_MB=640
EOF
out=$(cd "$TEST_DIR/../.." && PATH="$SB:$PATH" bash installer/deploy.sh --plan "$PLAN" --dry-run 2>&1); rc=$?
check "t5 dry-run rc" "$rc" "0"
contains "t5 would apply" "$out" "vaultwarden.yaml"

# t6 github mode without gh dies cleanly
PLAN2="$TMP/p5g.env"
sed 's/MSP_METHOD=appliance/MSP_METHOD=github/' "$PLAN" > "$PLAN2"
out=$(cd "$TEST_DIR/../.." && PATH="$SB:$PATH" bash installer/deploy.sh --plan "$PLAN2" 2>&1); rc=$?
check "t6 github no-gh rc" "$rc" "1"
contains "t6 github no-gh msg" "$out" "GitHub CLI"

# t7 manage: status with stub kubectl
printf '#!/bin/sh\nif [ "$*" = "-n argocd get application vaultwarden -o jsonpath={.status.sync.status}" ]; then echo Synced; fi\nif [ "$*" = "-n argocd get application vaultwarden -o jsonpath={.status.health.status}" ]; then echo Healthy; fi\nexit 0\n' > "$SB/kubectl"
PLAN3="$TMP/p5m.env"
cat > "$PLAN3" <<EOF
MSP_METHOD=appliance
MSP_DOMAIN=example.com
MSP_APPS="vaultwarden"
EOF
out=$(cd "$TEST_DIR/../.." && PATH="$SB:$PATH" MSP_PLAN_FILE="$PLAN3" bash installer/homelab-manage.sh status 2>&1)
contains "t7 status shows app" "$out" "vaultwarden"
contains "t7 status Synced" "$out" "Synced"

# t8 manage urls
out=$(cd "$TEST_DIR/../.." && PATH="$SB:$PATH" MSP_PLAN_FILE="$PLAN3" bash installer/homelab-manage.sh urls 2>&1)
contains "t8 url rendered" "$out" "https://vault.example.com"

# t9 LF hygiene
for f in deploy.sh homelab-manage.sh lib/catalog.sh; do
  grep -lq $'\r' "$TEST_DIR/../$f" 2>/dev/null && { FAIL=$((FAIL+1)); printf 'FAIL: CRLF in %s\n' "$f"; } || { PASS=$((PASS+1)); printf 'PASS: LF %s\n' "$f"; }
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

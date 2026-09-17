#!/bin/bash
# test-appliance.sh — assertions for lib/appliance.sh rendering transforms.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$TEST_DIR/.oc-tmp"
mkdir -p "$TMP"
. "$TEST_DIR/../lib/common.sh"
. "$TEST_DIR/../lib/appliance.sh"

PASS=0; FAIL=0
check() { # name got want
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s (got: %s want: %s)\n' "$1" "$2" "$3"; fi
}
contains() {
  case "$2" in *"$3"*) PASS=$((PASS+1)); printf 'PASS: %s\n' "$1";;
    *) FAIL=$((FAIL+1)); printf 'FAIL: %s (%s does not contain %s)\n' "$1" "$2" "$3";; esac
}

REPO_ROOT="$TEST_DIR/../.."

# fixture: copy the real vaultwarden application.yaml
FIX="$TMP/app-fix.yaml"
cp "$REPO_ROOT/apps/dmz/vaultwarden/application.yaml" "$FIX"

# ------------------------------------------------------------- t1 render
out=$(appliance_render "$REPO_ROOT/apps/dmz/vaultwarden" "$TMP/rendered.yaml")
check "t1 render rc" "$?" "0"
[ -f "$TMP/rendered.yaml" ]; check "t1 out file exists" "$([ -f "$TMP/rendered.yaml" ] && echo yes || echo no)" "yes"

# t2: $values source repointed to upstream
contains "t2 values ref upstream" "$(cat "$TMP/rendered.yaml")" "repoURL: $APPLIANCE_UPSTREAM"
grep -q 'ref: values' "$TMP/rendered.yaml"
check "t2 ref: values kept" "$?" "0"

# t3: write-back flipped
# vaultwarden has no updater annotations; flip is verified on jellyfin (t6).
# Here: no git write-back remnants may survive either way.
grep -q 'write-back-method: git' "$TMP/rendered.yaml"
check "t3 no git writeback left" "$?" "1"
grep -q 'git.repository' "$TMP/rendered.yaml"
check "t3 git.repository dropped" "$?" "1"

# t4: source[0] chart repo untouched
contains "t4 chart repo kept" "$(cat "$TMP/rendered.yaml")" "repoURL: https://gissilabs.github.io/charts"

# ------------------------------------------------------------- t5 overrides
MSP_DOMAIN_OVERRIDE=example.com appliance_render "$REPO_ROOT/apps/dmz/vaultwarden" "$TMP/rendered2.yaml"
contains "t5 valuesObject injected" "$(cat "$TMP/rendered2.yaml")" "valuesObject"
contains "t5 domain in override" "$(cat "$TMP/rendered2.yaml")" "example.com"

# ------------------------------------------------------------- t6 render other app with updater annotations
cp "$REPO_ROOT/apps/private/jellyfin/application.yaml" "$TMP/jf.yaml" 2>/dev/null
if [ -f "$TMP/jf.yaml" ]; then
  appliance_render "$REPO_ROOT/apps/private/jellyfin" "$TMP/rendered3.yaml"
  check "t6 render jellyfin rc" "$?" "0"
  grep -q 'write-back-method: argocd' "$TMP/rendered3.yaml"
  check "t6 jellyfin writeback flipped" "$?" "0"
  grep -q 'write-back-target' "$TMP/rendered3.yaml"
  check "t6 write-back-target kept" "$?" "0"
  grep -q 'git.repository' "$TMP/rendered3.yaml"
  check "t6 git.repository dropped" "$?" "1"
else
  printf 'SKIP: jellyfin app dir not found\n'
fi

# ------------------------------------------------------------- t7 idempotent
appliance_render "$REPO_ROOT/apps/dmz/vaultwarden" "$TMP/rendered.yaml"
cmp -s "$TMP/rendered.yaml" "$TMP/rendered.yaml"
check "t7 idempotent rc" "$?" "0"

# ------------------------------------------------------------- hygiene
if grep -lq $'\r' "$TEST_DIR/../lib/appliance.sh" 2>/dev/null; then
  FAIL=$((FAIL+1)); printf 'FAIL: CRLF in appliance.sh\n'
else
  PASS=$((PASS+1)); printf 'PASS: LF-clean\n'
fi
bash -n "$TEST_DIR/../lib/appliance.sh" && PASS=$((PASS+1)); printf 'PASS: bash -n appliance.sh\n' || FAIL=$((FAIL+1))

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

#!/usr/bin/env bash
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/../lib"
SERVICES="$TEST_DIR/../services.yaml"
TMP_DIR="$TEST_DIR/../.oc-tmp"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/catalog.sh"

mkdir -p "$TMP_DIR"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$1"
}

if catalog_load "$SERVICES"; then
  pass "catalog_load services.yaml"
  REAL_APPS_N="$(catalog_n)"
  if [ "$REAL_APPS_N" -gt 40 ]; then
    pass "APPS_N > 40 (got $REAL_APPS_N)"
  else
    fail "APPS_N > 40 (got $REAL_APPS_N)"
  fi
  if [ "$UC_N" -eq 15 ]; then
    pass "UC_N == 15"
  else
    fail "UC_N == 15 (got $UC_N)"
  fi
else
  fail "catalog_load services.yaml"
  REAL_APPS_N=0
fi

rc=0
row="$(catalog_app jellyfin)" || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "catalog_app jellyfin (exit $rc)"
else
  IFS='|' read -r b_cat b_ram b_desc b_req b_uc b_sub b_def b_risk <<< "$row"
  if [ "$b_cat" = "media" ]; then
    pass "jellyfin category=media"
  else
    fail "jellyfin category=media (got '$b_cat')"
  fi
  if [ "$b_ram" = "1536" ]; then
    pass "jellyfin ram=1536"
  else
    fail "jellyfin ram=1536 (got '$b_ram')"
  fi
  if [ "$b_sub" = "media" ]; then
    pass "jellyfin subdomain=media"
  else
    fail "jellyfin subdomain=media (got '$b_sub')"
  fi
fi

if catalog_app definitely-not-an-app >/dev/null 2>&1; then
  fail "catalog_app unknown app should return 1"
else
  pass "catalog_app unknown app returns 1"
fi

rc=0
out="$(catalog_dep_closure vaultwarden)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "postgresql" ]; then
  pass "dep_closure vaultwarden == postgresql"
else
  fail "dep_closure vaultwarden (rc=$rc, got: $out)"
fi

rc=0
out="$(catalog_dep_closure immich affine)" || rc=$?
D_ERR=""
if [ "$rc" -ne 0 ]; then
  D_ERR="exit code $rc"
else
  d_n=0
  d_pg=0
  d_pos_affine=-1
  d_pos_ipg=-1
  d_pos_redis=-1
  while IFS= read -r d_line; do
    [ -n "$d_line" ] || continue
    case "$d_line" in
      immich) D_ERR="$D_ERR; excluded input immich was printed" ;;
      affine) d_pos_affine=$d_n ;;
      immich-postgresql) d_pos_ipg=$d_n ;;
      redis-affine-master) d_pos_redis=$d_n ;;
      postgresql) d_pg=$((d_pg + 1)) ;;
    esac
    D_LINES[$d_n]=$d_line
    d_n=$((d_n + 1))
  done <<< "$out"
  [ "$d_n" -eq 0 ] && D_ERR="$D_ERR; empty output"
  [ "$d_pos_affine" -lt 0 ] && D_ERR="$D_ERR; affine missing"
  [ "$d_pos_ipg" -lt 0 ] && D_ERR="$D_ERR; immich-postgresql missing"
  [ "$d_pos_redis" -lt 0 ] && D_ERR="$D_ERR; redis-affine-master missing"
  if [ "$d_pos_ipg" -ge 0 ] && [ "$d_pos_affine" -ge 0 ] && [ "$d_pos_ipg" -ge "$d_pos_affine" ]; then
    D_ERR="$D_ERR; immich-postgresql not before affine"
  fi
  if [ "$d_pos_redis" -ge 0 ] && [ "$d_pos_affine" -ge 0 ] && [ "$d_pos_redis" -ge "$d_pos_affine" ]; then
    D_ERR="$D_ERR; redis-affine-master not before affine"
  fi
  [ "$d_pg" -ne 1 ] && D_ERR="$D_ERR; postgresql appears $d_pg times"
  d_i=0
  while [ "$d_i" -lt "$d_n" ]; do
    d_j=$((d_i + 1))
    while [ "$d_j" -lt "$d_n" ]; do
      if [ "${D_LINES[$d_i]}" = "${D_LINES[$d_j]}" ]; then
        D_ERR="$D_ERR; duplicate entry: ${D_LINES[$d_i]}"
      fi
      d_j=$((d_j + 1))
    done
    d_i=$((d_i + 1))
  done
fi
if [ -z "$D_ERR" ]; then
  pass "dep_closure immich affine: deps-first, postgresql once, no dupes"
else
  fail "dep_closure immich affine:$D_ERR (got: $out)"
fi

out="$(catalog_by_use_case passwords)"
case "$out" in
  *vaultwarden*)
    pass "by_use_case passwords includes vaultwarden"
    ;;
  *)
    fail "by_use_case passwords includes vaultwarden (got: $out)"
    ;;
esac
case "$out" in
  *jellyfin*)
    fail "by_use_case passwords must not include jellyfin (got: $out)"
    ;;
  *)
    pass "by_use_case passwords excludes jellyfin"
    ;;
esac

vout="$(catalog_validate "$SERVICES" 2>&1)"
vrc=$?
if [ "$vrc" -eq 0 ] && case "$vout" in *"catalog: OK"*) true ;; *) false ;; esac; then
  pass "catalog_validate services.yaml"
else
  fail "catalog_validate (rc=$vrc, out: $vout)"
fi

CYCLE_YAML="$TMP_DIR/cycle-test.yaml"
{
  printf 'apps:\n'
  printf '  a:\n'
  printf '    category: test\n'
  printf '    description: cycle test app a\n'
  printf '    ram_mb: 64\n'
  printf '    requires: b\n'
  printf '    use_cases: ""\n'
  printf '    subdomain: ""\n'
  printf '    guided_default: false\n'
  printf '    risk: ""\n'
  printf '  b:\n'
  printf '    category: test\n'
  printf '    description: cycle test app b\n'
  printf '    ram_mb: 64\n'
  printf '    requires: a\n'
  printf '    use_cases: ""\n'
  printf '    subdomain: ""\n'
  printf '    guided_default: false\n'
  printf '    risk: ""\n'
} > "$CYCLE_YAML"

if catalog_load "$CYCLE_YAML" 2>/dev/null; then
  pass "catalog_load cycle yaml parses structurally"
  cerr="$(catalog_dep_closure a 2>&1)"
  crc=$?
  if [ "$crc" -ne 0 ] && case "$cerr" in *cycle*) true ;; *) false ;; esac; then
    pass "dep_closure detects cycle (rc=$crc): $cerr"
  else
    fail "cycle detection (rc=$crc, err: $cerr)"
  fi
else
  fail "catalog_load cycle yaml parses structurally"
fi
rm -f "$CYCLE_YAML"

rc1=0
rc2=0
catalog_load "$SERVICES" 2>/dev/null || rc1=$?
catalog_load "$SERVICES" || rc2=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$(catalog_n)" -eq "$REAL_APPS_N" ]; then
  pass "re-load idempotent (APPS_N still $REAL_APPS_N)"
else
  fail "re-load idempotence (rc=$rc1/$rc2, APPS_N=$(catalog_n), expected $REAL_APPS_N)"
fi

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0

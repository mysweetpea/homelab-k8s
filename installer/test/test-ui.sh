#!/bin/bash
# test-ui.sh — assertions for installer/lib/ui.sh (plain + ansi backends).
# stdout of the functions under test = results only (menus go to stderr),
# so tests capture stdout and let stderr flow to the console.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$TEST_DIR/../lib/common.sh"
# shellcheck source=../lib/ui.sh
. "$TEST_DIR/../lib/ui.sh"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP: %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got: $2 want: $3)"; fi; }
checkrc() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got rc: $2 want: $3)"; fi; }

# ---------------------------------------------------------------- test 1
MSP_UI=plain ui_init
check "ui_init MSP_UI=plain -> plain" "$UI_BACKEND" "plain"

UI_BACKEND=""
MSP_UI= ui_init < /dev/null
check "ui_init non-TTY no MSP_UI -> plain" "$UI_BACKEND" "plain"

# ---------------------------------------------------------------- test 2/3
out=$(printf '2\n' | MSP_UI=plain ui_single_select "T" "|" \
  "alpha|First choice" "beta|Second choice" "gamma|Third" 2>/dev/null)
rc=$?
checkrc "single plain: number select rc" "$rc" "0"
check "single plain: number select id" "$out" "beta"

out=$(printf 'q\n' | MSP_UI=plain ui_single_select "T" "|" \
  "alpha|First" "beta|Second" 2>/dev/null)
rc=$?
checkrc "single plain: q cancels (rc)" "$rc" "1"
check "single plain: q cancels (empty out)" "$out" ""

# ---------------------------------------------------------------- test 4/5
# displayed rows (header included in numbering):
#   1) header   2) jellyfin   3) immich   4) paperless
out=$(printf '2 4\n\n' | MSP_UI=plain ui_multi_select "T" \
  "# Media|Group header" "jellyfin| |Jellyfin" "immich| |Immich" "paperless| |Paperless" 2>/dev/null)
rc=$?
checkrc "multi plain: toggle 2,4 confirm (rc)" "$rc" "0"
check "multi plain: toggle 2,4 result" "$out" "$(printf 'jellyfin\npaperless')"
case "$out" in
  *"# "*) fail "multi plain: header text leaked into results" ;;
  *) pass "multi plain: header row never in results" ;;
esac

# displayed: 1) header 2) aa 3) bb 4) cc ; a all -> n none -> toggle 3 (bb) -> confirm
out=$(printf 'a\nn\n3\n\n' | MSP_UI=plain ui_multi_select "T" \
  "# H|hdr" "aa| |One" "bb| |Two" "cc| |Three" 2>/dev/null)
check "multi plain: all-then-none-then-3" "$out" "bb"

# ---------------------------------------------------------------- ansi 6-8
# keys: space(toggle r1) down(r2) space(toggle r2) Enter -> rows 1 and 2
out=$(printf ' \033[B \r' | MSP_UI=ansi MSP_UI_ANSI_FORCE=1 ui_multi_select "T" \
  "r1| |One" "r2| |Two" "r3| |Three" 2>/dev/null)
rc=$?
checkrc "multi ansi: space down space enter (rc)" "$rc" "0"
check "multi ansi: picks rows 1 and 2" "$out" "$(printf 'r1\nr2')"

out=$(printf '\033' | MSP_UI=ansi MSP_UI_ANSI_FORCE=1 ui_multi_select "T" \
  "r1| |One" "r2| |Two" 2>/dev/null)
rc=$?
checkrc "multi ansi: lone Esc cancels (rc)" "$rc" "1"

out=$(printf 'a\r' | MSP_UI=ansi MSP_UI_ANSI_FORCE=1 ui_multi_select "T" \
  "r1| |One" "r2| |Two" "r3| |Three" 2>/dev/null)
rc=$?
checkrc "multi ansi: a then Enter (rc)" "$rc" "0"
check "multi ansi: a selects all" "$out" "$(printf 'r1\nr2\nr3')"

# ---------------------------------------------------------------- test 9 parity
# plain `1 3` toggles rows 1 and 3 (no headers here). ansi equivalent:
# space(toggle r1) down down (r3) space (toggle r3) Enter
p_out=$(printf '1 3\n\n' | MSP_UI=plain ui_multi_select "T" \
  "r1| |One" "r2| |Two" "r3| |Three" 2>/dev/null)
a_out=$(printf ' \033[B\033[B \r' | MSP_UI=ansi MSP_UI_ANSI_FORCE=1 ui_multi_select "T" \
  "r1| |One" "r2| |Two" "r3| |Three" 2>/dev/null)
check "parity: plain vs ansi same result" "$p_out" "$a_out"

# ---------------------------------------------------------------- fzf/whiptail
if have fzf; then
  out=$(printf '\n' | MSP_UI=fzf ui_single_select "T" "|" \
    "alpha|First" "beta|Second" 2>/dev/null)
  rc=$?
  if [ "$rc" = "0" ] && [ -n "$out" ]; then
    pass "single fzf: selectable (picked '$out')"
  else
    skip "single fzf: non-interactive stdin (rc=$rc) — verify manually"
  fi
else
  skip "fzf not installed"
fi

if have whiptail; then
  skip "whiptail: needs a real TTY; verify manually"
else
  skip "whiptail not installed"
fi

# ---------------------------------------------------------------- hygiene
if grep -lq $'\r' "$TEST_DIR/../lib/ui.sh" 2>/dev/null; then
  fail "ui.sh contains CRLF"
else
  pass "ui.sh is LF-clean"
fi

bash -n "$TEST_DIR/../lib/ui.sh" && pass "bash -n ui.sh" || fail "bash -n ui.sh"

# ---------------------------------------------------------------- summary
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]

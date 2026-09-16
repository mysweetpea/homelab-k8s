#!/bin/bash
# test-github.sh — network-independent assertions for lib/github.sh.
# Uses a stub `gh` on PATH; NO real network calls.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$TEST_DIR/.oc-tmp"
# Windows-git accepts d:/... form for URL-ish args; MSYS /d/... form breaks.
msp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
mkdir -p "$TMP"
# shellcheck source=../lib/common.sh
. "$TEST_DIR/../lib/common.sh"
# shellcheck source=../lib/catalog.sh
. "$TEST_DIR/../lib/catalog.sh"
catalog_load "$TEST_DIR/../services.yaml"
# shellcheck source=../lib/github.sh
. "$TEST_DIR/../lib/github.sh"

PASS=0; FAIL=0
check() { # name got want
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s (got: %s want: %s)\n' "$1" "$2" "$3"; fi
}
contains() {
  case "$2" in *"$3"*) PASS=$((PASS+1)); printf 'PASS: %s\n' "$1";;
    *) FAIL=$((FAIL+1)); printf 'FAIL: %s (%s does not contain %s)\n' "$1" "$2" "$3";; esac
}

# ---------- stub gh factory ----------
make_stub_gh() { # $1=dir ; gh responds: auth ok, api user JSON, setup-git ok
  mkdir -p "$1"
  cat > "$1/gh" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "auth token") exit 0 ;;
  "auth setup-git") exit 0 ;;
  "api user")
    case "$3" in
      "--jq") shift 3; case "$1" in ".login") echo tester ;; ".id") echo 42 ;; *) echo "" ;; esac ;;
      *) echo '{"login":"tester","id":"42","email":null}' ;;
    esac ;;
  *) exit 0 ;;
  "repo fork") echo "Created fork tester/homelab-k8s" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$1/gh"
}

make_no_gh_dir() { # $1=dir ; PATH dir WITHOUT gh, with bash+git essentials symlinked? No: build minimal PATH listing
  mkdir -p "$1"
}

# ---------------------------------------------------------------- t1 sandbox
SANDBOX="$TMP/nogh-path"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
# lightweight no-gh sandbox: system dirs only (bash/git/awk exist there; gh does not)
for d in /usr/bin /bin /mingw64/bin /c/Windows/System32; do
  [ -d "$d" ] && echo "$d"
done > "$TMP/nogh-list.txt"
SANDBOX="$(tr '\n' ':' < "$TMP/nogh-list.txt" | sed 's/:$//')"

out=$(GH_TOKEN= GH_TOKEN_X= PATH="$SANDBOX" TEST_DIR="$TEST_DIR" bash -c '
  source "$TEST_DIR/../lib/github.sh"
  gh_have
' 2>/dev/null); rc=$?
check "t1 gh_have rc!=0 without gh" "$([ "$rc" != 0 ] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------- t2 hint
err=$(PATH="$SANDBOX" TEST_DIR="$TEST_DIR" bash -c '
  source "$TEST_DIR/../lib/github.sh"
  gh_ensure_fork mysweetpea/homelab-k8s
' 2>&1 >/dev/null); rc=$?
check "t2 gh_ensure_fork rc=127 without gh" "$rc" "127"
contains "t2 hint mentions GitHub CLI" "$err" "GitHub CLI"

# ---------------------------------------------------------------- t3 push bad dir
out=$(PATH="$SANDBOX:$PATH" TEST_DIR="$TEST_DIR" bash -c '
  source "$TEST_DIR/../lib/github.sh"
  gh_push_dir "'"$TMP"'/not-a-repo" tester/homelab-k8s "msg"
' 2>&1 >/dev/null); rc=$?
check "t3 bad dir rc=1" "$rc" "1"
contains "t3 gh-missing message" "$err" "GitHub CLI"

# ---------------------------------------------------------------- t4 idempotence
WORK="$TMP/pushwork-$$"; BARE="$TMP/pushbare-$$.git"
rm -rf "$WORK" "$BARE"
mkdir -p "$WORK"
git init -q --bare "$(msp "$BARE")"
(cd "$WORK" && git init -q)
(cd "$WORK" && git remote add origin "$(msp "$BARE")")
printf "seed\n" > "$WORK/values.yaml"
STUB="$TMP/stubgh"; rm -rf "$STUB"; make_stub_gh "$STUB"
export PATH="$STUB:$PATH"

out=$(MSP_ORIGIN_OVERRIDE="$(msp "$BARE")" gh_push_dir "$WORK" "tester/homelab-k8s" "install: configure homelab" 2>/dev/null); rc=$?
check "t4 first push rc=0" "$rc" "0"
contains "t4 first push says pushed" "$out" "pushed"
head1=$(cd "$WORK" && git ls-remote origin HEAD 2>/dev/null | awk '{print $1}')
[ -n "$head1" ]; check "t4 bare repo has commit" "$([ -n "$head1" ] && echo yes || echo no)" "yes"

out=$(MSP_ORIGIN_OVERRIDE="$(msp "$BARE")" gh_push_dir "$WORK" "tester/homelab-k8s" "install: configure homelab" 2>/dev/null); rc=$?
check "t4 second run rc=0" "$rc" "0"
contains "t4 second run already-clean" "$out" "already-clean"

# identity went to noreply
em=$(cd "$WORK" && git config user.email)
contains "t4 noreply email used" "$em" "42+tester@users.noreply.github.com"

# ---------------------------------------------------------------- t5 sync upstream (local remotes only)
UP="$TMP/up-$$.git"; CL="$TMP/clone-$$"
rm -rf "$UP" "$CL"
git init -q --bare "$(msp "$UP")"
mkdir -p "$CL"
(cd "$CL" && git init -q)
(cd "$CL" && git remote add upstream "$(msp "$UP")")
# put a commit on upstream/main
C2="$TMP/upseed-$$"; rm -rf "$C2"; mkdir -p "$C2"
(cd "$C2" && git init -q)
(cd "$C2" && git remote add origin "$(msp "$UP")")
echo seed > "$C2/seed.txt"
(cd "$C2" && git add -A && git -c user.name=t -c user.email=t@e.c commit -qm seed)
(cd "$C2" && git push -q origin "HEAD:refs/heads/main") 2>/dev/null
out=$(MSP_UPSTREAM_OVERRIDE="$(msp "$UP")" gh_sync_upstream "$CL" "someone/upstream" 2>/dev/null); rc=$?
check "t5 sync rc=0" "$rc" "0"
case "$out" in *up-to-date*|*rebased*) PASS=$((PASS+1)); printf 'PASS: t5 sync result\n' ;; *) FAIL=$((FAIL+1)); printf 'FAIL: t5 sync result (%s)\n' "$out" ;; esac
# upstream moved; clone has no local change -> rebase fast-forward
echo more > "$C2/more.txt"
(cd "$C2" && git add -A && git -c user.name=t -c user.email=t@e.c commit -qm more)
(cd "$C2" && git push -q origin "HEAD:refs/heads/main") 2>/dev/null
out=$(MSP_UPSTREAM_OVERRIDE="$(msp "$UP")" gh_sync_upstream "$CL" "someone/upstream" 2>/dev/null); rc=$?
check "t5 rebase rc=0" "$rc" "0"

# ---------------------------------------------------------------- hygiene
if grep -lq $'\r' "$TEST_DIR/../lib/github.sh" "$TEST_DIR/test-github.sh" 2>/dev/null; then
  FAIL=$((FAIL+1)); printf 'FAIL: CRLF found\n'
else
  PASS=$((PASS+1)); printf 'PASS: LF-clean\n'
fi
bash -n "$TEST_DIR/../lib/github.sh" && PASS=$((PASS+1)); printf 'PASS: bash -n github.sh\n' || { FAIL=$((FAIL+1)); printf 'FAIL: bash -n github.sh\n'; }

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# test-provision.sh — assertions for provision-k3s.sh.
# Cannot provision for real in CI: test the sanity layer, arg parsing,
# idempotence branches, and generated MetalLB manifest shape via stubs.
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
S="$TEST_DIR/../provision-k3s.sh"

# t1 syntax
bash -n "$S" && check "t1 bash -n" 0 0 || check "t1 bash -n" 1 0

# t2 non-Linux rejection (uname stub): run with PATH shadowing uname to say Darwin
SB="$TMP/nonlinux"; rm -rf "$SB"; mkdir -p "$SB"
printf '#!/bin/sh\necho Darwin\n' > "$SB/uname"; chmod +x "$SB/uname"
out=$(PATH="$SB:$PATH" bash "$S" 2>&1); rc=$?
check "t2 non-linux rc" "$rc" "1"
contains "t2 non-linux msg" "$out" "targets Linux"

# t3 non-root without sudo dies
# t3 no early success: must NEVER reach a real install or "cluster ready".
# Deterministic on any machine (GitHub runners run as root WITH sudo+systemctl — the
# old assumption "no sudo" fails there and t3 attempted a REAL k3s install):
# sandbox PATH without systemctl => script dies at the systemd check.
SBS="$TMP/sandbox"; rm -rf "$SBS"; mkdir -p "$SBS"
for tool in uname id awk grep sed cat sh bash seq sleep curl; do
  p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$SBS/$tool"
done
out=$(PATH="$SBS" bash "$S" 2>&1 </dev/null); rc=$?
case "$out" in
  *"cluster ready"*) check "t3 no early success" 1 0;;
  *) check "t3 no early success" 0 0;;
esac

# t4 idempotent branch: fake k3s present -> message, no install
SB2="$TMP/withk3s"; rm -rf "$SB2"; mkdir -p "$SB2"
printf '#!/bin/sh\necho "k3s version v1.36.1+k3s1"\n' > "$SB2/k3s"; chmod +x "$SB2/k3s"
printf '#!/bin/sh\necho Linux\n' > "$SB2/uname"; chmod +x "$SB2/uname"
printf '#!/bin/sh\necho 0\n' > "$SB2/id"; chmod +x "$SB2/id"      # pretend root
printf '#!/bin/sh\nexit 0\n' > "$SB2/systemctl"; chmod +x "$SB2/systemctl"
printf '#!/bin/sh\ngrep_mem() { :; }\necho 8000000\n' > "$SB2/grep"; chmod +x "$SB2/grep"
printf '#!/bin/sh\necho "1.2.3.4"\n' > "$SB2/hostname"; chmod +x "$SB2/hostname"
# kubectl stub: node already Ready on first poll
printf '#!/bin/sh\necho "node1   Ready"\n' > "$SB2/kubectl"; chmod +x "$SB2/kubectl"
out=$(PATH="$SB2:/usr/bin:/bin" bash "$S" 2>&1); rc=$?
contains "t4 skips install" "$out" "already installed"
contains "t4 prints next step" "$out" "Next steps"
check "t4 completes" "$rc" "0"

# t5 low RAM rejection
SB3="$TMP/lowram"; cp -r "$SB2/." "$SB3/" 2>/dev/null || { mkdir -p "$SB3"; cp "$SB2"/* "$SB3/"; }
printf '#!/bin/sh\necho 1000000\n' > "$SB3/grep"; chmod +x "$SB3/grep"
out=$(PATH="$SB3:/usr/bin:/bin" bash "$S" 2>&1); rc=$?
check "t5 lowram rc" "$rc" "1"
contains "t5 lowram msg" "$out" "4GB RAM"

# t6 metallb range plumbing: with kubectl stub capturing applied manifest
SB4="$TMP/mlb"; cp -r "$SB2/." "$SB4/"
printf '#!/bin/sh\nif [ "$1 $2" = "get ns" ]; then exit 1; fi\nif [ "$1" = "apply" ]; then [ "$3" = "-" ] && cat > /tmp/mlb-manifest.txt; exit 0; fi\nif [ "$1 $2 $3" = "-n metallb-system wait" ]; then exit 0; fi\necho "node1   Ready"\n' > "$SB4/kubectl"
chmod +x "$SB4/kubectl"
out=$(PATH="$SB4:/usr/bin:/bin" bash "$S" --with-metallb-range "192.168.1.100-192.168.1.150" 2>&1)
contains "t6 metallb applied" "$out" "MetalLB pool created"
contains "t6 range in manifest" "$(cat /tmp/mlb-manifest.txt 2>/dev/null)" "192.168.1.100-192.168.1.150"

# t7 LF clean
if grep -lq $'\r' "$S" 2>/dev/null; then
  FAIL=$((FAIL+1)); printf 'FAIL: CRLF in provision-k3s.sh\n'
else
  PASS=$((PASS+1)); printf 'PASS: LF-clean\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

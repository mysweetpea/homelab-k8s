#!/bin/bash
# Weekly containerd/disk hygiene on k3s-master (added 2026-08-28 after ephemeral-storage
# evictions hit ollama/hindsight at <2.5Gi free; images had accreted to 46G).
# Safe while pods run: only touches EXITED containers + UNUSED images + archives.
LOGTAG="[containerd-hygiene $(date +%Y%m%d-%H%M)]"
echo "$LOGTAG start df=$(df -h / | awk "NR==2{print \$5}")"
crictl ps -a -q --state Exited 2>/dev/null | xargs -r crictl rm >/dev/null 2>&1
crictl rmi --prune >/dev/null 2>&1
journalctl --vacuum-size=200M >/dev/null 2>&1
find /tmp -mindepth 1 -maxdepth 1 -mtime +3 -delete 2>/dev/null
echo "$LOGTAG done df=$(df -h / | awk "NR==2{print \$5}")"

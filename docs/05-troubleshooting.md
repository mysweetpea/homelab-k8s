# 05 — Troubleshooting

Symptoms first, causes second, fixes as commands. Read top to bottom.

## Wizard / deploy

**`deploy.sh` says "prerequisite missing: ArgoCD CRDs"**
You're in appliance mode on a fresh cluster — install the core bundle first:
```bash
./installer/install.sh BUNDLES=core
```

**`deploy.sh` hangs at "waiting for ArgoCD"**
The CRD appears when the argocd helm release finishes; on slow disks this takes a few minutes.
If >10 min: `kubectl -n argocd get pods` — a crash-looping repo-server is the usual culprit;
`kubectl -n argocd logs deploy/argocd-repo-server | tail -50`.

**The wizard's menus look garbled**
Your terminal lacks ANSI support. Force the plain UI: `MSP_UI=plain ./installer/wizard.sh`.

**A secrets file with CHANGE_ME values was printed**
You're in expert mode — fill them in, then re-run deploy. Guided mode generates them for you.

## Apps

**App shows `Progressing` forever**
`kubectl -n argocd get applications` → find it → `kubectl -n argocd describe application <name>`.
The events line names the resource that won't become ready; `kubectl -n <ns> logs <pod>` finishes
the story. Image pull errors = wrong tag; CrashLoopBackOff = config it dislikes.

**App is `Synced` but unhealthy**
Check the app's own health: `kubectl -n <ns> get pods`. A `Pending` pod that never schedules is
usually resource pressure (see next).

**"Insufficient memory" / pod Pending with FailedScheduling**
You picked more than the machine can hold. Remove an app (wizard), or add RAM, or add a node.

## Network / access

**Can't reach `https://<app>.<domain>` from outside**
LAN-only mode is the default — outside access needs the exposure question set to "my own domain"
and a Cloudflare tunnel token. Re-run the wizard to change it.

**Everything is down after a reboot**
`sudo systemctl status k3s` — if stopped, `sudo systemctl start k3s` and wait two minutes.
Longhorn volumes re-attach automatically; `./homelab status` until green.

## Storage

**Disk filling up**
`kubectl -n longhorn-system get volumes` sorts by size; the usual hogs are media and photo
libraries, which is expected. Longhorn "actual size" can exceed file size until snapshots are
trimmed (weekly trim job handles it).

## Still stuck

Open an issue with: the exact command, the full output, and `./homelab status`. The test suites
in `installer/test/` also double as executable documentation of what *should* happen.

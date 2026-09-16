# 04 — Day-2 operations

The install is the beginning. Here's how to live with it.

## Daily

```bash
./homelab status        # everything Synced/Healthy? you're done.
```

That's it. Updates roll out automatically (image-updater + ArgoCD) at safe cadences.

## Adding / removing apps

```bash
./installer/wizard.sh          # adjust your selections, confirm the summary
./installer/deploy.sh --plan homelab-plan.env
```

Removing = uncheck it in the wizard; deploy prunes it. Data volumes are kept (delete explicitly
if you truly want the space back — see troubleshooting).

## Backups — where they are and how to test them

| What | Where | Cadence |
|---|---|---|
| App volumes (Longhorn) | local snapshots + offsite backup target | snapshots nightly, backups nightly |
| Databases (PostgreSQL dumps) | backup target | nightly |
| Installer configs (restic) | offsite | nightly, alerting on failure |

**Restore drill (do one every few months):**
1. `./homelab status` → note the app.
2. Longhorn UI → Backup → pick the volume → Restore (new PVC).
3. Point the app at the restored PVC, verify data, delete the test copy.

Offsite target setup (NFS/S3 + credentials) is prompted during provisioning of backups; the
sealed-secret backup of the sealed-secrets controller key is the one restore you must not skip.

## Monitoring and alerts

- **Uptime Kuma** pings every service; failures push to your phone (Gotify on Android,
  iGotify relay on iPhone).
- **Grafana** for dashboards and logs (Loki); **Netdata** for node-level detail.
- Alert fatigue is real: alerting is wired to *failures*, not noise.

## Upgrades

- **Apps:** automatic (semver, healthy-rollout only). Pin or delay any app by editing its
  `targetRevision` in GitOps mode, or the Application CR in appliance mode.
- **k3s itself:** infrequent, manual, and worth reading release notes for:
  `sudo k3s upgrade` style steps are in the k3s docs; snapshot before.
- **The installer:** `git pull` — the test suite is your safety net.

## Disaster recovery (cluster lost)

1. Provision a new node (same one-liner from getting-started).
2. Restore the **sealed-secrets controller key** first (documented location from install).
3. Re-run `deploy.sh` with your plan file — in GitOps mode, your fork already holds everything;
   in appliance mode, the exported Application YAMLs in your backup hold everything.
4. Restore data volumes from Longhorn backups.
5. `./homelab status` until green.

RTO on a warm spare: under an hour. From nothing: an evening.

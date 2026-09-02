# Longhorn backup infrastructure (VPS offsite target) — deployed Sep 2 2026

## Architecture

```
Longhorn volumes (39, 2-replica on workers)
  ├─ daily-snapshot  03:00 keep-5   (local, on-cluster)
  ├─ daily-backup    04:00 keep-7   (block-level → VPS NFS over NetBird)
  └─ weekly-trim     Sun 05:00      (filesystem-trim, reclaims deleted-block space)
```

- **Target**: `nfs://100.82.13.16:/export/longhorn-backups/cluster` (NetBird IP of the
  Oracle VPS relay). BackupTarget CR `default` in longhorn-system.
- **Transport**: NetBird mesh (workers enrolled Sep 2: worker-a `100.82.213.0`,
  worker-b `100.82.92.245`; VPS `100.82.13.16`; master `100.82.169.28`).
  No public ports — VPS iptables REJECTs everything except 22/443/80 + wt0 interface.
- **VPS side**: dedicated 150G OCI block volume (`/dev/sdb1`, ext4, LABEL=longhorn-bkp)
  mounted at `/export/longhorn-backups`, iSCSI login persisted
  (`node.startup=automatic` for IQN `iqn.2015-12.com.oracleiaas:08cf44ec-…`).
  NFS export `/export/longhorn-backups/cluster` → the 3 node NetBird IPs only
  (rw,sync,no_subtree_check,no_root_squash). NFSv4.2, Oracle free-tier safe
  (47G boot + 150G block = 197G ≤ 200G).
- **NOT encrypted at rest** on the VPS (Longhorn NFS targets don't support encryption).
  Accepted tradeoff — transport is WireGuard-encrypted, NFS is IP-restricted.

## Restores (the part that matters at 2am)

UI: longhorn-ui (.221) → Backup → restore, or:
```bash
kubectl -n longhorn-system get backups.longhorn.io            # list
# restore = create PVC from backup via UI, or Volume CR with
# fromBackup: nfs://100.82.13.16:/export/longhorn-backups/cluster?backup=<name>&volume=<vol>
```

## Ops notes

- **Recurring jobs are applied manually** (Longhorn is helm-installed, not
  ArgoCD-managed): `kubectl apply -f apps/infra/longhorn/recurring-jobs.yaml`.
  CRD-based jobs survive helm upgrades (verified pattern from Aug 28 audit).
- **BackupTarget is a CR, not a Setting, in LH 1.12** — the `backup-target` Setting
  does not exist on this version. Set via:
  `kubectl -n longhorn-system patch backuptargets.longhorn.io default --type merge
  -p '{"spec":{"backupTargetURL":"nfs://..."}}'`
- The longhorn-backend ClusterIP is flaky from the master host (inconsistent 000s);
  imperative API calls work reliably **direct to a longhorn-manager pod IP on :9500**
  (get pod IPs: `kubectl -n longhorn-system get pod -l app=longhorn-manager -o wide`).
- Manual one-off backup recipe (recurring jobs only fire on schedule):
  1. `action=snapshotCRCreate` `{"name":"<snap>","labels":{...}}` on the volume
  2. `action=snapshotBackup` `{"name":"<snap>"}` on the volume
  3. watch `kubectl -n longhorn-system get backups.longhorn.io`
- NetBird enrollment is durable (systemd service); if a worker is rebuilt,
  re-enroll: `netbird up --setup-key <key>` (create key in app.netbird.io).
- NFS exports live in `/etc/exports` on the VPS; NetBird worker IPs are DHCP-stable
  within the mesh (100.82.x.x assigned at enrollment).

## Storage optimization (Sep 2)

`filesystem-trim` weekly job added — churn-heavy volumes (netdata dbengine,
jellyfin transcodes) grow phantom space from deleted files; TRIM returns it.
One-time manual fstrim on workers reclaimed 26.3G+ (mostly released on next
snapshot purge cycle; recurring job keeps it reclaimed).
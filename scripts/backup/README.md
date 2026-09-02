# Backup scripts (sanitized copies)

These are the backup/ops scripts that run on **k3s-master** under
`/root/backup-scripts/` (root crontab). This directory is the durable,
sanitized copy — the live copies on the master remain the source of truth
for execution, but if the master is lost, this directory is enough to
rebuild the chain on any replacement node.

| Script | Cron | Purpose |
|---|---|---|
| `restic-backup.sh` | 02:30 daily | Stage app data (tar from live pods) → restic push to **both** offsite repos (VPS + PC), retain 7d/4w/6m + prune |
| `restic-pc-retry.sh` | 08:00 | Retry the PC push if the 02:30 run lacked today's `PC backup OK` |
| `pg-backup.sh` | 02:00 | pg_dump ALL non-template DBs on shared postgresql-0 (keep 7 dumps) |
| `config-backup.sh` | 03:00 | kubectl-dump of all namespace configs (deployments/secrets/CMs) |
| `restic-check.sh` | 1st monthly 05:00 | `restic check` integrity test on both repos |
| `containerd-hygiene.sh` | Sun 04:00 | Prune exited containers + unused images on the master |
| `setup-cron.sh` | (manual) | Installs the crontab entries above |

## Sanitization

Repo copies have the SFTP repo URLs replaced with `${VPS_REPO}` / `${PC_REPO}`
placeholders (public repo, no IPs/usernames). Real values live only in
`/root/backup-scripts/restic-backup.sh` on the master. To restore from this
copy: fill the two `VPS_REPO=`/`PC_REPO=` lines with your real repo URLs.

Secrets are **never** in these scripts at rest: restic passphrase is read from
`/root/.restic-passphrase`; pg creds come from k8s secrets at runtime; the
sealed-secrets key is captured from the live cluster into each backup.

## Related

- Longhorn block-level offsite backups: `apps/infra/longhorn/BACKUP-TARGET.md`
  (VPS NFS target over NetBird, daily-backup/weekly-trim recurring jobs)
- Restic repos live at: VPS `/home/ubuntu/restic-repo` and PC
  `D:\home lab\restic-repo` (paths documented locally, not in this repo)
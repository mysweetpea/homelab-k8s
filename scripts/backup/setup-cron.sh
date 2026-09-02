#!/bin/bash
# Setup cron jobs for backups

# Daily at 2am: PostgreSQL backup
(crontab -l 2>/dev/null | grep -v "pg-backup.sh"; echo "0 2 * * * /root/backup-scripts/pg-backup.sh >> /var/log/pg-backup.log 2>&1") | crontab -

# Daily at 3am: Config backup
(crontab -l 2>/dev/null | grep -v "config-backup.sh"; echo "0 3 * * * /root/backup-scripts/config-backup.sh >> /var/log/config-backup.log 2>&1") | crontab -

# Weekly on Sunday at 4am: Sync to PC
(crontab -l 2>/dev/null | grep -v "rsync-to-pc.sh"; echo "0 4 * * 0 /root/backup-scripts/rsync-to-pc.sh >> /var/log/rsync-backup.log 2>&1") | crontab -

echo "Cron jobs installed:"
crontab -l

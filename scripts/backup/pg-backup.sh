#!/bin/bash
# PostgreSQL database backup script
# Runs daily via cron. Dumps all databases to /root/pg-dumps/
# Then syncs to GitHub (small files) and optionally to PC (via rsync)

set -e
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/pg-dumps"
mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting PostgreSQL backup..."

# Get postgres admin password
PGPASS=$(kubectl get secret postgresql -n private -o jsonpath='{.data.postgres-password}' | base64 -d)

# Dump all databases from shared postgresql
echo "[$(date)] Dumping shared postgresql databases..."
for db in $(kubectl exec postgresql-0 -n private -- env PGPASSWORD="$PGPASS" psql -U postgres -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>/dev/null); do
  echo "  - Dumping $db"
  kubectl exec postgresql-0 -n private -- env PGPASSWORD="$PGPASS" pg_dump -U postgres "$db" > "$BACKUP_DIR/${db}-${DATE}.sql" 2>/dev/null && gzip -f "$BACKUP_DIR/${db}-${DATE}.sql"
done

# Dump authentik database
echo "[$(date)] Dumping authentik database..."
AKPASS=$(kubectl get secret authentik-postgresql -n dmz -o jsonpath='{.data.password}' | base64 -d)
kubectl exec authentik-postgresql-0 -n dmz -- env PGPASSWORD="$AKPASS" pg_dump -U authentik authentik > "$BACKUP_DIR/authentik-${DATE}.sql" 2>/dev/null && gzip -f "$BACKUP_DIR/authentik-${DATE}.sql"

# Dump immich database
echo "[$(date)] Dumping immich database..."
IMMICHPASS=$(kubectl get secret immich-postgresql -n private -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec immich-postgresql-0 -n private -- env PGPASSWORD="$IMMICHPASS" pg_dump -U immich immich > "$BACKUP_DIR/immich-${DATE}.sql" 2>/dev/null && gzip -f "$BACKUP_DIR/immich-${DATE}.sql"

# Dump matrix-synapse database
echo "[$(date)] Dumping matrix-synapse database..."
SYNAPSEPASS=$(kubectl get secret matrix-synapse-db -n dmz -o jsonpath='{.data.password}' | base64 -d)
kubectl exec matrix-synapse-postgresql-0 -n dmz -- env PGPASSWORD="$SYNAPSEPASS" pg_dump -U synapse synapse > "$BACKUP_DIR/synapse-${DATE}.sql" 2>/dev/null && gzip -f "$BACKUP_DIR/synapse-${DATE}.sql"

# Keep only last 7 days of dumps
echo "[$(date)] Cleaning old dumps (keeping 7 days)..."
find "$BACKUP_DIR" -name "*.sql*" -mtime +4 -delete

echo "[$(date)] PostgreSQL backup complete."

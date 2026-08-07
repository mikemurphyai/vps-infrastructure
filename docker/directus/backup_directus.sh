#!/usr/bin/env bash
set -euo pipefail

# ==== Settings ====
DB_CONTAINER="directus-db"
DB_USER="directus"
DB_NAME="directus"
UPLOADS_VOLUME="directus_uploads"
BACKUP_DIR="/var/backups/directus"
LOG="/var/backups/directus/backup.log"
TIMESTAMP="$(date -u +"%Y%m%d_%H%M%S")"
DB_DUMP="directus_db_${TIMESTAMP}.sql.gz"
UPLOADS_ARCHIVE="directus_uploads_${TIMESTAMP}.tar.gz"
RETENTION_LOCAL_DAYS=14
RETENTION_REMOTE_DAYS=30               # used only if rclone is installed
LOCKFILE="/var/backups/directus/.backup.lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUMA_PUSH_URL="$(grep -m1 '^KUMA_PUSH_URL=' "${SCRIPT_DIR}/.env" | cut -d= -f2-)"    # from gitignored .env, not committed

# ==== Logging ====
log() { echo "[$(date -u +"%F %T") UTC] $*" | tee -a "$LOG" ; }

# ==== Ensure backup dir exists ====
mkdir -p "$BACKUP_DIR"

# ==== Prevent overlapping runs ====
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log "Another backup is already running; exiting."
  exit 0
fi

log "Starting backup for Directus (db: $DB_NAME, uploads volume: $UPLOADS_VOLUME)"

# Postgres dump via pg_dump for a consistent snapshot (not a raw volume tar,
# since that can capture a live DB mid-write).
docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "${BACKUP_DIR}/${DB_DUMP}"
sha256sum "${BACKUP_DIR}/${DB_DUMP}" >> "${BACKUP_DIR}/sha256sums.txt" || true
log "Database dump created: ${BACKUP_DIR}/${DB_DUMP}"

# Uploads volume archive
docker pull alpine:3.20 >/dev/null 2>&1 || true
docker run --rm \
  -v "${UPLOADS_VOLUME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine:3.20 sh -c "tar czf /backup/${UPLOADS_ARCHIVE} -C /data ."
sha256sum "${BACKUP_DIR}/${UPLOADS_ARCHIVE}" >> "${BACKUP_DIR}/sha256sums.txt" || true
log "Uploads archive created: ${BACKUP_DIR}/${UPLOADS_ARCHIVE}"

# Prune old local archives
find "$BACKUP_DIR" -type f -name "directus_db_*.sql.gz" -mtime +"${RETENTION_LOCAL_DAYS}" -print -delete | tee -a "$LOG" || true
find "$BACKUP_DIR" -type f -name "directus_uploads_*.tar.gz" -mtime +"${RETENTION_LOCAL_DAYS}" -print -delete | tee -a "$LOG" || true
log "Local retention applied: > ${RETENTION_LOCAL_DAYS} days deleted (if any)."

# Offsite (only if rclone is installed & remote configured)
if command -v rclone >/dev/null 2>&1; then
  rclone copy "$BACKUP_DIR" "vault-nas:/Vault/Backups/Hostinger VPS/directus" \
    --transfers=2 --checkers=4 \
    --create-empty-src-dirs \
    --log-file=/root/rclone_backup.log || true

  rclone delete "vault-nas:/Vault/Backups/Hostinger VPS/directus" \
    --min-age "${RETENTION_REMOTE_DAYS}d" \
    --log-file=/root/rclone_backup.log || true

  log "Offsite sync complete (remote retention applied)."
else
  log "rclone not installed; skipping offsite sync."
fi

log "Backup completed successfully."

# Ping Uptime Kuma (dead-man's-switch monitor for this cron job)
curl -fsS -m 10 "$KUMA_PUSH_URL" >/dev/null 2>&1 || log "Warning: failed to ping Uptime Kuma push monitor."
